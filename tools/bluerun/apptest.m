/*
 * apptest - install an app bundle through installd (miinstall), launch it by bundle ID and
 * check that it ran (Hello.app writes Documents/hello.txt in its data container).
 *
 *   apptest /private/var/tmp/Hello.app [BUNDLE_ID] [DOMAIN]
 *
 * Defaults: dev.blueline.hello, domain 1 (system). Prints "APPTEST: PASS" or the step that failed.
 * Built by tools/bluerun/build.sh-style flags, signed with apptest.ent.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Foundation/Foundation.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (NSArray *)allInstalledApplications;
@end
@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)bundleID;
@property (readonly) NSURL *dataContainerURL;
@property (readonly) NSURL *bundleURL;
@property (readonly, getter=isInstalled) BOOL installed;
@end

static int
run(const char *path, char *const argv[])
{
	pid_t pid;
	int st, e = posix_spawn(&pid, path, NULL, NULL, argv, environ);
	if (e != 0) {
		printf("APPTEST: spawn %s: %s\n", path, strerror(e));
		return -1;
	}
	waitpid(pid, &st, 0);
	return WIFEXITED(st) ? WEXITSTATUS(st) : 128;
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fprintf(stderr, "usage: apptest BUNDLE.app [BUNDLE_ID] [DOMAIN]\n");
			return 2;
		}
		NSString *bid = argc > 2 ? @(argv[2]) : @"dev.blueline.hello";
		char *domain = argc > 3 ? argv[3] : "1";
		setvbuf(stdout, NULL, _IOLBF, 0);

		char *mi[] = { "/usr/local/bin/miinstall", domain, argv[1], NULL };
		int rc = run(mi[0], mi);
		printf("APPTEST: miinstall exit %d\n", rc);

		LSApplicationProxy *p = [LSApplicationProxy applicationProxyForIdentifier:bid];
		printf("APPTEST: LaunchServices: installed %d, bundle %s, data %s\n", p.installed,
		    p.bundleURL.path.UTF8String ?: "-", p.dataContainerURL.path.UTF8String ?: "-");
		if (!p.installed) {
			printf("APPTEST: FAIL (not registered)\n");
			return 1;
		}
		NSString *txt = [p.dataContainerURL.path stringByAppendingPathComponent:@"Documents/hello.txt"];
		[[NSFileManager defaultManager] removeItemAtPath:txt error:nil];
		BOOL opened = [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:bid];
		printf("APPTEST: openApplicationWithBundleID %d\n", opened);
		for (int i = 0; i < 30; i++) {
			NSString *s = [NSString stringWithContentsOfFile:txt encoding:NSUTF8StringEncoding error:nil];
			if (s) {
				printf("APPTEST: hello.txt after %d s: %s", i, s.UTF8String);
				printf("APPTEST: PASS\n");
				return 0;
			}
			sleep(1);
		}
		printf("APPTEST: FAIL (no %s after 30 s)\n", txt.UTF8String);
		return 1;
	}
}
