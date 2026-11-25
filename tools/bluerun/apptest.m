/*
 * apptest - install an app bundle through installd (miinstall), launch it by bundle ID and
 * check that it ran (Hello.app writes Documents/hello.txt in its data container).
 *
 *   apptest /private/var/tmp/Hello.app [BUNDLE_ID] [DOMAIN] [SETTLE_S]
 *
 * SETTLE_S: seconds between install and launch (default 15; more lets the boot-time CPU load pass
 * before an app measures frame times). Defaults: dev.blueline.hello, domain 2 (user; 1 = system needs a system-app entitlement). Prints "APPTEST: PASS" or the step that failed.
 * Built by tools/bluerun/build.sh-style flags, signed with apptest.ent.
 *
 * The launch is ios-flame's phone/tools/openapp.m (FBSOpenApplicationService, MIT),
 * with LaunchServices as the fallback.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

extern char **environ;

@interface FBSOpenApplicationOptions : NSObject
+ (instancetype)optionsWithDictionary:(NSDictionary *)dict;
@end
@interface FBSOpenApplicationService : NSObject
+ (instancetype)serviceWithDefaultShellEndpoint;
- (void)openApplication:(NSString *)bundleID withOptions:(FBSOpenApplicationOptions *)options
	     completion:(void (^)(id process, NSError *error))completion;
@end

/* pid of a running process named NAME (p_comm, 16 chars), or 0 */
static pid_t
pid_of(const char *name)
{
	int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
	size_t len = 0;
	pid_t pid = 0;
	if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0)
		return 0;
	len += 16 * sizeof(struct kinfo_proc);
	struct kinfo_proc *kp = malloc(len);
	if (kp && sysctl(mib, 3, kp, &len, NULL, 0) == 0)
		for (size_t i = 0; i < len / sizeof(*kp); i++)
			if (strncmp(kp[i].kp_proc.p_comm, name, MAXCOMLEN) == 0)
				pid = kp[i].kp_proc.p_pid;
	free(kp);
	return pid;
}

/* ios-flame openapp.m (MIT): FrontBoard asks SpringBoard to launch it */
static BOOL
open_app(NSString *bid)
{
	dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
	Class svc = NSClassFromString(@"FBSOpenApplicationService");
	Class optc = NSClassFromString(@"FBSOpenApplicationOptions");
	if (!svc || !optc)
		return NO;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	__block BOOL ok = NO;
	[[svc serviceWithDefaultShellEndpoint] openApplication:bid
	    withOptions:[optc optionsWithDictionary:@{ @"__UnlockDevice": @YES, @"__ActivateSuspended": @NO }]
	    completion:^(id process, NSError *error) {
		printf("APPTEST: FrontBoard open: %s\n", error ? error.description.UTF8String : [[process description] UTF8String]);
		ok = error == nil;
		dispatch_semaphore_signal(done);
	    }];
	if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)))
		printf("APPTEST: FrontBoard open: no answer in 30 s\n");
	return ok;
}

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
		char *domain = argc > 3 ? argv[3] : "2";
		int settle = argc > 4 ? atoi(argv[4]) : 15;
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
		/* right after boot SpringBoard answered the open with an XPC error (app11):
		 * let it settle, then try up to three times, 10 s apart */
		NSString *exe = [NSDictionary dictionaryWithContentsOfURL:
		    [p.bundleURL URLByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"] ?: @"Hello";
		sleep(settle > 0 ? settle : 15);
		for (int attempt = 1; attempt <= 3; attempt++) {
			if (!open_app(bid)) {
				BOOL opened = [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:bid];
				printf("APPTEST: LaunchServices openApplicationWithBundleID %d\n", opened);
			}
			for (int i = 0; i < 10; i++) {
				NSString *s = [NSString stringWithContentsOfFile:txt encoding:NSUTF8StringEncoding error:nil];
				if (s) {
					printf("APPTEST: hello.txt (attempt %d, %d s): %s", attempt, i, s.UTF8String);
					printf("APPTEST: PASS\n");
					return 0;
				}
				sleep(1);
			}
			printf("APPTEST: attempt %d: no hello.txt; %s pid %d\n", attempt, exe.UTF8String, pid_of(exe.UTF8String));
		}
		printf("APPTEST: FAIL (no %s)\n", txt.UTF8String);
		return 1;
	}
}
