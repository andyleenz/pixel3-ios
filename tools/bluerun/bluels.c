/*
 * bluels: list directories on the phone (iOS has no ls): mode, size, mtime
 * (UTC), name. tools/bluesh.py run /usr/local/bin/bluels DIR...
 */
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

int
main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		DIR *d = opendir(argv[i]);
		if (d == NULL) {
			perror(argv[i]);
			continue;
		}
		printf("%s:\n", argv[i]);
		struct dirent *e;
		while ((e = readdir(d)) != NULL) {
			char p[2048], t[32];
			struct stat sb;
			snprintf(p, sizeof(p), "%s/%s", argv[i], e->d_name);
			if (lstat(p, &sb) != 0) {
				continue;
			}
			strftime(t, sizeof(t), "%Y-%m-%d %H:%M:%S", gmtime(&sb.st_mtime));
			printf("  %06o %10lld  %s  %s\n", sb.st_mode, (long long)sb.st_size, t, e->d_name);
		}
		closedir(d);
	}
	return 0;
}
