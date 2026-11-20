/*
 * bluectl: the kernel's live controls, for tools/bluesh.py (patch 0177).
 *
 *   bluectl snap           the screen now (sysctl kern.bluesnap) to stdout:
 *                          a bluesnap header, then the pixels
 *   bluectl touch SCRIPT   run touch steps now (sysctl kern.bluetouch),
 *                          bluetouchscript= syntax with times 0, e.g.
 *                          "0:tap,540,1200;0:wait,500;0:snap"
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "snap") == 0) {
		size_t n = 0;
		if (sysctlbyname("kern.bluesnap", NULL, &n, NULL, 0) != 0) {
			fprintf(stderr, "bluectl: kern.bluesnap: %s\n", strerror(errno));
			return 1;
		}
		char *b = malloc(n);
		if (b == NULL || sysctlbyname("kern.bluesnap", b, &n, NULL, 0) != 0) {
			fprintf(stderr, "bluectl: kern.bluesnap: %s\n", strerror(errno));
			return 1;
		}
		for (size_t off = 0; off < n;) {
			ssize_t w = write(1, b + off, n - off);
			if (w <= 0) {
				return 1;
			}
			off += (size_t)w;
		}
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "touch") == 0) {
		if (sysctlbyname("kern.bluetouch", NULL, NULL, argv[2], strlen(argv[2])) != 0) {
			fprintf(stderr, "bluectl: kern.bluetouch: %s\n", strerror(errno));
			return 1;
		}
		return 0;
	}
	fprintf(stderr, "usage: bluectl snap | bluectl touch SCRIPT\n");
	return 2;
}
