/*
 * envrun: run a program with VAR=VALUE settings first, as env(1) does (iOS has no env):
 *   envrun OS_ACTIVITY_DT_MODE=1 /usr/libexec/thermalmonitord
 * OS_ACTIVITY_DT_MODE=1 sends the program's os_log lines to stderr, which bluesh streams back.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	int i = 1;
	for (; i < argc && strchr(argv[i], '=') && argv[i][0] != '/'; i++)
		putenv(argv[i]);
	if (i >= argc) {
		fprintf(stderr, "usage: envrun [VAR=VALUE ...] PATH [ARG ...]\n");
		return 2;
	}
	execv(argv[i], argv + i);
	perror(argv[i]);
	return 127;
}
