/*
 * bluesh: run programs and move files on the running phone over the USB
 * network link (sweetusb=2: the phone is 192.168.7.2, the Mac 192.168.7.1),
 * so a userland test needs no reboot. tools/bluesh.py is the Mac side.
 *
 * Listens on 192.168.7.2:2222 only (the USB cable), one request per TCP
 * connection, as root. A request is one line:
 *
 *   run SECONDS PATH [ARG...]      run it (args split on spaces), stdout and
 *                                  stderr streamed back, then "\n#exit N\n"
 *   put PATH MODE SIZE             then SIZE bytes: written to PATH.tmp and
 *                                  renamed (MODE octal); answers "#ok" or
 *                                  "#error ..."
 *   get PATH                       answers "#size N\n" then N bytes
 *   kill NAME                      SIGKILL every process named NAME (launchd
 *                                  starts a daemon again): "#killed N"
 *   done                           the session is over: reboot as bluereboot=
 *                                  says (sysctl kern.bluedone, patch 0175)
 *   watch SECONDS                  link watchdog: with no request for SECONDS
 *                                  (one still running counts as contact), end
 *                                  the session as "done" does. 0 disarms. For a
 *                                  USB link that stalls while iOS runs on: the
 *                                  phone gets itself to recovery. "#watch N"
 *   ping                           "#pong" (contact only)
 *
 * Started by bluerun (bluerun=/usr/local/bin/bluesh, bluerun_after=launchd,
 * bluerun_timeout=36000) or by hand. Build: tools/bluerun/build.sh bluesh.c.
 */
#include <arpa/inet.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
/* libproc.h is not in the iOS SDK; libsystem has these */
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void
sayf(int fd, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void
sayf(int fd, const char *fmt, ...)
{
	char buf[512];
	va_list ap;

	va_start(ap, fmt);
	int n = vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (n > 0) {
		(void)write(fd, buf, (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1);
	}
}

static bool
readall(int fd, void *p, size_t n)
{
	while (n > 0) {
		ssize_t r = read(fd, p, n);
		if (r <= 0) {
			return false;
		}
		p = (char *)p + r;
		n -= (size_t)r;
	}
	return true;
}

static void
do_run(int c, char *rest)
{
	char *argv[64];
	int argc = 0;
	long secs = strtol(rest, &rest, 10);

	for (char *t = strtok(rest, " "); t != NULL && argc < 63; t = strtok(NULL, " ")) {
		argv[argc++] = t;
	}
	argv[argc] = NULL;
	if (argc == 0) {
		sayf(c, "#error no program\n");
		return;
	}
	posix_spawn_file_actions_t fa;
	posix_spawnattr_t at;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, c, 1);
	posix_spawn_file_actions_adddup2(&fa, c, 2);
	posix_spawnattr_init(&at);
	posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP);
	posix_spawnattr_setpgroup(&at, 0);
	pid_t pid;
	int e = posix_spawn(&pid, argv[0], &fa, &at, argv, environ);
	posix_spawn_file_actions_destroy(&fa);
	posix_spawnattr_destroy(&at);
	if (e != 0) {
		sayf(c, "#error spawn %s: %s\n", argv[0], strerror(e));
		return;
	}
	int st = 0;
	time_t end = time(NULL) + (secs > 0 ? secs : 60);
	for (;;) {
		pid_t r = waitpid(pid, &st, WNOHANG);
		if (r == pid) {
			break;
		}
		if (time(NULL) >= end) {
			kill(-pid, SIGKILL);
			waitpid(pid, &st, 0);
			sayf(c, "\n#timeout\n");
			break;
		}
		usleep(50 * 1000);
	}
	if (WIFEXITED(st)) {
		sayf(c, "\n#exit %d\n", WEXITSTATUS(st));
	} else if (WIFSIGNALED(st)) {
		sayf(c, "\n#signal %d\n", WTERMSIG(st));
	}
}

static void
do_put(int c, char *rest)
{
	char path[1024], tmp[1040];
	unsigned mode = 0644;
	long long size = -1;

	if (sscanf(rest, "%1023s %o %lld", path, &mode, &size) != 3 || size < 0 || size > (1LL << 30)) {
		sayf(c, "#error usage: put PATH MODE SIZE\n");
		return;
	}
	snprintf(tmp, sizeof(tmp), "%s.bluesh", path);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, mode);
	if (fd < 0) {
		sayf(c, "#error open %s: %s\n", tmp, strerror(errno));
		return;
	}
	char buf[65536];
	bool ok = true;
	while (size > 0 && ok) {
		size_t n = size < (long long)sizeof(buf) ? (size_t)size : sizeof(buf);
		ok = readall(c, buf, n) && write(fd, buf, n) == (ssize_t)n;
		size -= (long long)n;
	}
	fchmod(fd, (mode_t)mode);
	close(fd);
	if (!ok || rename(tmp, path) != 0) {
		unlink(tmp);
		sayf(c, "#error write %s: %s\n", path, strerror(errno));
		return;
	}
	sayf(c, "#ok\n");
}

static void
do_get(int c, char *rest)
{
	char path[1024];
	struct stat sb;

	if (sscanf(rest, "%1023s", path) != 1) {
		sayf(c, "#error usage: get PATH\n");
		return;
	}
	int fd = open(path, O_RDONLY);
	if (fd < 0 || fstat(fd, &sb) != 0) {
		sayf(c, "#error %s: %s\n", path, strerror(errno));
		if (fd >= 0) {
			close(fd);
		}
		return;
	}
	sayf(c, "#size %lld\n", (long long)sb.st_size);
	char buf[65536];
	ssize_t n;
	while ((n = read(fd, buf, sizeof(buf))) > 0) {
		if (write(c, buf, (size_t)n) != n) {
			break;
		}
	}
	close(fd);
}

static void
do_kill(int c, char *rest)
{
	char name[256];
	pid_t pids[4096];
	int killed = 0;

	if (sscanf(rest, "%255s", name) != 1) {
		sayf(c, "#error usage: kill NAME\n");
		return;
	}
	int n = proc_listallpids(pids, sizeof(pids));
	for (int i = 0; i < n; i++) {
		char pn[256];
		if (pids[i] > 1 && proc_name(pids[i], pn, sizeof(pn)) > 0 && strcmp(pn, name) == 0 &&
		    kill(pids[i], SIGKILL) == 0) {
			killed++;
		}
	}
	sayf(c, "#killed %d\n", killed);
}

/* the link watchdog ("watch SECONDS") */
static volatile time_t last_contact;
static volatile int watch_secs, busy;

static void
end_session(const char *why)
{
	int v = 1;
	printf("bluesh: %s: ending the session\n", why);
	fflush(stdout);
	if (sysctlbyname("kern.bluedone", NULL, NULL, &v, sizeof(v)) != 0) {
		printf("bluesh: kern.bluedone: %s\n", strerror(errno));
	}
}

static void *
watchdog(void *arg)
{
	(void)arg;
	for (;;) {
		sleep(5);
		if (busy) {
			last_contact = time(NULL);
		} else if (watch_secs > 0 && time(NULL) - last_contact > watch_secs) {
			char why[80];
			snprintf(why, sizeof(why), "no request for %d s (link watchdog)", watch_secs);
			watch_secs = 0;
			end_session(why);
		}
	}
	return NULL;
}

int
main(void)
{
	signal(SIGPIPE, SIG_IGN);
	signal(SIGCHLD, SIG_DFL);
	int s = socket(AF_INET, SOCK_STREAM, 0);
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in a = { .sin_len = sizeof(a), .sin_family = AF_INET, .sin_port = htons(2222) };
	inet_pton(AF_INET, "192.168.7.2", &a.sin_addr);
	for (int tries = 0; bind(s, (struct sockaddr *)&a, sizeof(a)) != 0; tries++) {
		if (tries == 0) {
			printf("bluesh: waiting for 192.168.7.2 (sweetusb=2): %s\n", strerror(errno));
		}
		sleep(1);
	}
	listen(s, 4);
	last_contact = time(NULL);
	pthread_t wt;
	pthread_create(&wt, NULL, watchdog, NULL);
	printf("bluesh: listening on 192.168.7.2:2222\n");
	fflush(stdout);
	for (;;) {
		int c = accept(s, NULL, NULL);
		if (c < 0) {
			continue;
		}
		char line[4096];
		size_t n = 0;
		while (n < sizeof(line) - 1 && read(c, &line[n], 1) == 1 && line[n] != '\n') {
			n++;
		}
		line[n] = 0;
		busy = 1;
		last_contact = time(NULL);
		if (strcmp(line, "ping") != 0) {
			printf("bluesh: %.200s\n", line);
		}
		fflush(stdout);
		if (strncmp(line, "run ", 4) == 0) {
			do_run(c, line + 4);
		} else if (strncmp(line, "put ", 4) == 0) {
			do_put(c, line + 4);
		} else if (strncmp(line, "get ", 4) == 0) {
			do_get(c, line + 4);
		} else if (strncmp(line, "kill ", 5) == 0) {
			do_kill(c, line + 5);
		} else if (strcmp(line, "ping") == 0) {
			sayf(c, "#pong\n");
		} else if (strncmp(line, "watch ", 6) == 0) {
			watch_secs = atoi(line + 6);
			sayf(c, "#watch %d\n", watch_secs);
		} else if (strcmp(line, "done") == 0) {
			sayf(c, "#rebooting\n");
			close(c);
			busy = 0;
			sleep(1);
			end_session("done");
			continue;
		} else {
			sayf(c, "#error unknown request\n");
		}
		close(c);
		last_contact = time(NULL);
		busy = 0;
	}
}
