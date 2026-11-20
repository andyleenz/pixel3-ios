/*
 * bluerun: run one test program per boot and copy its output into the
 * kernel's persistent log, for tools/phonetest.sh --run.
 *
 * Started once per boot by the launchd job com.blueline.bluerun
 * (tools/iosroot-tweaks.py --only bluerun), as root. Reads its settings
 * from the kernel boot-args (sysctl kern.bootargs), so changing the test is
 * only a boot-arg change:
 *
 *   bluerun=PATH[,ARG,...]     the program and its arguments (no spaces;
 *                              commas separate the arguments)
 *   bluerun_after=springboard  start once a process named SpringBoard
 *                              exists (default), =launchd right away, or
 *                              =N seconds after bluerun started
 *   bluerun_delay=S            S more seconds after that (default 0)
 *   bluerun_timeout=S          kill the program's process group after S s
 *                              (default 60)
 *   bluerun_env=K=V;K=V        extra environment variables
 *   bluerun_wait=S             give up waiting for SpringBoard after S s
 *                              (default 300)
 *   bluerun_end=reboot         once the program has ended, reboot at once
 *                              as bluereboot= says (sysctl kern.bluedone,
 *                              patch 0175), instead of waiting out
 *                              bluereboot_after/bluereboot_delay
 *
 * Without bluerun= it prints one line and exits. Every line the program
 * writes to stdout or stderr goes to /dev/console as "BLUERUN: text" (the
 * console reaches the persistent log, sweet 0047, which tools/phone.sh log
 * pulls in recovery), then "BLUERUN: exit N" / "killed by signal N" /
 * "timeout" and "BLUERUN: done".
 *
 * Build: tools/bluerun/build.sh (iphoneos arm64, ad-hoc signed).
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int con = -1;

static void
say(const char *fmt, ...)
{
	char buf[1100];
	va_list ap;
	int n = snprintf(buf, sizeof(buf), "BLUERUN: ");
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof(buf) - (size_t)n - 1, fmt, ap);
	va_end(ap);
	if (n > (int)sizeof(buf) - 2) {
		n = (int)sizeof(buf) - 2;
	}
	buf[n++] = '\n';
	if (con >= 0) {
		(void)write(con, buf, (size_t)n);
	}
}

static double
now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Value of boot-arg NAME= (copied into out), or NULL. */
static char *
bootarg(const char *args, const char *name, char *out, size_t outlen)
{
	size_t nl = strlen(name);
	for (const char *p = args; *p;) {
		while (*p == ' ') {
			p++;
		}
		const char *e = strchr(p, ' ');
		size_t len = e ? (size_t)(e - p) : strlen(p);
		if (len > nl && strncmp(p, name, nl) == 0 && p[nl] == '=') {
			size_t vl = len - nl - 1;
			if (vl >= outlen) {
				vl = outlen - 1;
			}
			memcpy(out, p + nl + 1, vl);
			out[vl] = '\0';
			return out;
		}
		p += len;
	}
	return NULL;
}

static long
bootarg_num(const char *args, const char *name, long def)
{
	char v[32];
	return bootarg(args, name, v, sizeof(v)) ? strtol(v, NULL, 10) : def;
}

static int
springboard_running(void)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
	size_t len = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) {
		return 0;
	}
	len += 64 * sizeof(struct kinfo_proc);
	struct kinfo_proc *kp = malloc(len);
	if (kp == NULL) {
		return 0;
	}
	int found = 0;
	if (sysctl(mib, 3, kp, &len, NULL, 0) == 0) {
		for (size_t i = 0; i < len / sizeof(*kp); i++) {
			if (strcmp(kp[i].kp_proc.p_comm, "SpringBoard") == 0) {
				found = 1;
				break;
			}
		}
	}
	free(kp);
	return found;
}

/* Lines of buf[0..*n) out; keeps an unfinished line. flush: everything. */
static void
emit_lines(char *buf, size_t *n, int flush)
{
	size_t start = 0;
	for (size_t i = 0; i < *n; i++) {
		if (buf[i] == '\n' || i - start >= 900) {
			say("%.*s", (int)(i - start), buf + start);
			start = buf[i] == '\n' ? i + 1 : i;
		}
	}
	if (flush && start < *n) {
		say("%.*s", (int)(*n - start), buf + start);
		start = *n;
	}
	memmove(buf, buf + start, *n - start);
	*n -= start;
}

int
main(void)
{
	static char args[4096], spec[1024], after[32], envspec[1024];
	size_t alen = sizeof(args) - 1;

	con = open("/dev/console", O_WRONLY | O_NOCTTY);
	if (sysctlbyname("kern.bootargs", args, &alen, NULL, 0) != 0) {
		say("cannot read kern.bootargs (%s)", strerror(errno));
		return 1;
	}
	args[alen < sizeof(args) ? alen : sizeof(args) - 1] = '\0';
	if (!bootarg(args, "bluerun", spec, sizeof(spec)) || !spec[0]) {
		say("no bluerun= boot-arg; nothing to run");
		return 0;
	}
	if (!bootarg(args, "bluerun_after", after, sizeof(after))) {
		strcpy(after, "springboard");
	}
	long delay = bootarg_num(args, "bluerun_delay", 0);
	long timeout = bootarg_num(args, "bluerun_timeout", 60);
	long sbwait = bootarg_num(args, "bluerun_wait", 300);

	/* argv from PATH,ARG,... */
	char *argv[64];
	int argc = 0;
	for (char *s = spec, *tok; argc < 63 && (tok = strsep(&s, ",")) != NULL;) {
		argv[argc++] = tok;
	}
	argv[argc] = NULL;

	/* environment: ours plus bluerun_env */
	char *envp[256];
	int envc = 0;
	for (char **e = environ; *e && envc < 200; e++) {
		envp[envc++] = *e;
	}
	if (bootarg(args, "bluerun_env", envspec, sizeof(envspec))) {
		for (char *s = envspec, *tok; envc < 255 && (tok = strsep(&s, ";")) != NULL;) {
			if (strchr(tok, '=')) {
				envp[envc++] = tok;
			}
		}
	}
	envp[envc] = NULL;

	double t0 = now();
	if (strcasecmp(after, "springboard") == 0) {
		say("waiting for SpringBoard (up to %ld s) to run %s", sbwait, argv[0]);
		while (!springboard_running()) {
			if (now() - t0 > sbwait) {
				say("no SpringBoard after %ld s; running anyway", sbwait);
				break;
			}
			sleep(1);
		}
	} else if (strcasecmp(after, "launchd") != 0) {
		long s = strtol(after, NULL, 10);
		if (s > 0) {
			sleep((unsigned)s);
		}
	}
	if (delay > 0) {
		sleep((unsigned)delay);
	}

	int pfd[2];
	if (pipe(pfd) != 0) {
		say("pipe: %s", strerror(errno));
		return 1;
	}
	posix_spawn_file_actions_t fa;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
	posix_spawn_file_actions_adddup2(&fa, pfd[1], 1);
	posix_spawn_file_actions_adddup2(&fa, pfd[1], 2);
	posix_spawn_file_actions_addclose(&fa, pfd[0]);
	posix_spawn_file_actions_addclose(&fa, pfd[1]);
	posix_spawnattr_t at;
	posix_spawnattr_init(&at);
	posix_spawnattr_setflags(&at, POSIX_SPAWN_SETPGROUP);
	posix_spawnattr_setpgroup(&at, 0);

	pid_t pid;
	double ts = now();
	int err = posix_spawn(&pid, argv[0], &fa, &at, argv, envp);
	close(pfd[1]);
	if (err != 0) {
		say("cannot start %s: %s (%d)", argv[0], strerror(err), err);
		say("done");
		return 1;
	}
	say("started %s (pid %d, %d args, timeout %ld s, %.1f s after bluerun started)",
	    argv[0], pid, argc - 1, timeout, ts - t0);

	static char buf[8192];
	size_t n = 0;
	int timed_out = 0;
	for (;;) {
		double left = ts + (double)timeout - now();
		if (left <= 0) {
			timed_out = 1;
			break;
		}
		struct pollfd p = { .fd = pfd[0], .events = POLLIN };
		int r = poll(&p, 1, (int)(left * 1000) + 1);
		if (r < 0 && errno == EINTR) {
			continue;
		}
		if (r <= 0) {
			continue;               /* timeout is checked above */
		}
		ssize_t got = read(pfd[0], buf + n, sizeof(buf) - n - 1);
		if (got <= 0) {
			break;                  /* EOF: every writer closed */
		}
		n += (size_t)got;
		emit_lines(buf, &n, n >= sizeof(buf) - 1);
	}
	emit_lines(buf, &n, 1);
	if (timed_out) {
		say("timeout after %ld s: killing process group %d", timeout, pid);
		kill(-pid, SIGKILL);
	}
	int st = 0;
	while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {
	}
	double secs = now() - ts;
	if (WIFEXITED(st)) {
		say("exit %d after %.2f s", WEXITSTATUS(st), secs);
	} else if (WIFSIGNALED(st)) {
		say("killed by signal %d after %.2f s%s", WTERMSIG(st), secs,
		    WTERMSIG(st) == SIGKILL && !timed_out ? " (SIGKILL: code signing? see SWEET/cs_ lines)" : "");
	}
	say("done");
	char end[16];
	if (bootarg(args, "bluerun_end", end, sizeof(end)) && strcmp(end, "reboot") == 0) {
		int one = 1;
		sleep(1);       /* the console lines above into the log first */
		if (sysctlbyname("kern.bluedone", NULL, NULL, &one, sizeof(one)) != 0) {
			say("kern.bluedone: %s", strerror(errno));
		}
	}
	return 0;
}
