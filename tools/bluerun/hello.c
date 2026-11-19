/*
 * First test for tools/phonetest.sh --push/--run: proves that a binary
 * built and ad-hoc signed on the Mac lands in the root, starts, links the
 * shared cache, and that its stdout and stderr reach the kernel log.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);   /* libsystem_kernel */
#define CS_OPS_STATUS           0
#define CS_VALID                0x00000001
#define CS_ADHOC                0x00000002
#define CS_PLATFORM_BINARY      0x04000000
#define CS_SIGNED               0x20000000

int
main(int argc, char **argv)
{
	struct utsname u;
	char model[64] = "?";
	size_t len = sizeof(model);
	uint32_t cs = 0;

	uname(&u);
	sysctlbyname("hw.machine", model, &len, NULL, 0);
	int r = csops(getpid(), CS_OPS_STATUS, &cs, sizeof(cs));

	printf("hello from %s (%s), %s %s, pid %d uid %d\n", model, u.machine, u.sysname, u.release,
	    getpid(), getuid());
	printf("code signing: 0x%08x (csops %d):%s%s%s%s\n", cs, r,
	    cs & CS_VALID ? " valid" : "", cs & CS_ADHOC ? " ad-hoc" : "",
	    cs & CS_SIGNED ? " signed" : "", cs & CS_PLATFORM_BINARY ? " platform" : "");
	for (int i = 1; i < argc; i++) {
		printf("arg %d: %s\n", i, argv[i]);
	}
	const char *e = getenv("BLUE_HELLO");
	if (e) {
		printf("BLUE_HELLO=%s\n", e);
	}
	fflush(stdout);
	fprintf(stderr, "hello on stderr\n");
	return 7;               /* a recognisable exit status */
}
