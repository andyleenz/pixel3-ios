/*
 * bluectl: the kernel's live controls, for tools/bluesh.py (patch 0177).
 *
 *   bluectl snap           the screen now (sysctl kern.bluesnap) to stdout:
 *                          a bluesnap header, then the pixels
 *   bluectl touch SCRIPT   run touch steps now (sysctl kern.bluetouch),
 *                          bluetouchscript= syntax with times 0, e.g.
 *                          "0:tap,540,1200;0:wait,500;0:snap"
 *   bluectl mkdir PATH...  each directory and its parents (mode 755); the phone has no mkdir
 *   bluectl sysctl NAME... each integer sysctl's value (4 or 8 bytes), or its
 *                          string
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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
	if (argc >= 3 && strcmp(argv[1], "mkdir") == 0) {
		int bad = 0;
		for (int i = 2; i < argc; i++) {
			char p[1024];
			snprintf(p, sizeof(p), "%s", argv[i]);
			for (char *c = p + 1; ; c++) {
				if (*c == '/' || *c == 0) {
					char was = *c;
					*c = 0;
					if (mkdir(p, 0755) != 0 && errno != EEXIST) {
						printf("mkdir %s: %s\n", p, strerror(errno));
						bad = 1;
					}
					*c = was;
					if (was == 0)
						break;
				}
			}
		}
		return bad;
	}
	if (argc >= 3 && strcmp(argv[1], "sysctl") == 0) {
		int rc = 0;
		for (int i = 2; i < argc; i++) {
			char b[512];
			size_t n = sizeof(b) - 1;
			if (sysctlbyname(argv[i], b, &n, NULL, 0) != 0) {
				printf("%s: %s\n", argv[i], strerror(errno));
				rc = 1;
			} else if (n == 4) {
				printf("%s: %d\n", argv[i], *(int *)b);
			} else if (n == 8) {
				printf("%s: %lld\n", argv[i], *(long long *)b);
			} else {
				b[n] = 0;
				printf("%s: %s\n", argv[i], b);
			}
		}
		return rc;
	}
	fprintf(stderr, "usage: bluectl snap | bluectl touch SCRIPT | bluectl mkdir PATH... | bluectl sysctl NAME...\n");
	return 2;
}
