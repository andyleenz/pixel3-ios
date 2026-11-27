/*
 * blf.dylib - a process's os_log on the kernel console, for daemons whose stderr launchd sends to /dev/null.
 *
 *   sweetenv=NAME:DYLD_INSERT_LIBRARIES=/usr/lib/blf.dylib,OS_ACTIVITY_DT_MODE=1
 *
 * OS_ACTIVITY_DT_MODE=1 makes libtrace write every os_log line to stderr as well. At load, stderr becomes a pipe;
 * a thread reads it and sends each line to kern.bluesay ("SAY NAME[pid]: blf: ..." in the live log), at most 4000
 * lines a process. Lines are only read and dropped past that, so logging never blocks. Every line also goes to
 * /private/var/tmp/blf-PID.log, opened before main: a sandboxed daemon (assetsd) may not write the sysctl once its
 * sandbox is on, but it can still write a file it opened earlier. Without OS_ACTIVITY_DT_MODE it does nothing. The name is short because boot-args are limited to 607 bytes.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int logfd = -1;

static void *
forward(void *arg)
{
	FILE *in = fdopen((int)(intptr_t)arg, "r");
	char line[1024], buf[480];
	unsigned sent = 0;

	while (in != NULL && fgets(line, sizeof line, in) != NULL) {
		if (logfd >= 0)
			write(logfd, line, strlen(line));
		if (sent >= 4000)
			continue;
		snprintf(buf, sizeof buf, "blf: %s", line);
		buf[strcspn(buf, "\n")] = 0;
		sysctlbyname("kern.bluesay", NULL, NULL, buf, strlen(buf));
		sent++;
	}
	return NULL;
}

__attribute__((constructor)) static void
start(void)
{
	int fds[2];
	pthread_t t;

	sysctlbyname("kern.bluesay", NULL, NULL, "blf: loaded", 11);
	if (getenv("OS_ACTIVITY_DT_MODE") == NULL || pipe(fds) != 0)
		return;
	char path[64];
	snprintf(path, sizeof path, "/private/var/tmp/blf-%d.log", getpid());
	logfd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (dup2(fds[1], 2) < 0) {
		close(fds[0]);
		close(fds[1]);
		return;
	}
	close(fds[1]);
	setvbuf(stderr, NULL, _IOLBF, 0);
	if (pthread_create(&t, NULL, forward, (void *)(intptr_t)fds[0]) == 0)
		pthread_detach(t);
}
