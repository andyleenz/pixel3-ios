/*
 * Install app bundles through installd the way the first-boot migration does
 * (system app, for the migrator), without a migration: a minute-long test of
 * whether the removable system apps install.
 *
 *   miinstall DOMAIN /private/var/tmp/Calculator.app ...
 *
 * DOMAIN is installd's installation domain (1 = system; otherwise a user app, as Xcode, e.g. 3). Prints installd's
 * result or error for each bundle. Needs the entitlement in miinstall.ent:
 *
 *   xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall \
 *       -fobjc-arc -framework Foundation -o out/miinstall miinstall.m
 *   codesign -s - -f --entitlements miinstall.ent out/miinstall
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

@interface MIInstallerClient : NSObject
+ (instancetype)installerWithProgressBlock:(void (^)(id))block;
- (void)installURL:(NSURL *)url identity:(id)identity targetingDomain:(unsigned long)domain
    withOptions:(id)options returningResultInfo:(BOOL)info
    completion:(void (^)(BOOL, id, id, NSError *))completion;
@end

@interface MIAppIdentity : NSObject
- (instancetype)initWithBundleID:(NSString *)bundleID;
@end

@interface MIInstallOptions : NSObject
- (void)setSystemAppInstall:(BOOL)v;
- (void)setInstallForMigrator:(BOOL)v;
- (instancetype)initWithLegacyOptionsDictionary:(NSDictionary *)d;
- (void)setBundleIdentifier:(NSString *)v;
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 3) {
			fprintf(stderr, "usage: miinstall DOMAIN BUNDLE...\n");
			return 2;
		}
		if (!dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
		    RTLD_NOW)) {
			printf("miinstall: %s\n", dlerror());
			return 1;
		}
		unsigned long domain = strtoul(argv[1], NULL, 0);
		__block int failed = 0;
		for (int i = 2; i < argc; i++) {
			NSURL *url = [NSURL fileURLWithPath:@(argv[i])];
			NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
			    [url URLByAppendingPathComponent:@"Info.plist"]];
			NSString *bid = info[@"CFBundleIdentifier"];
			id identity = [[NSClassFromString(@"MIAppIdentity") alloc] initWithBundleID:bid];
			/* Domain 1: a system app (PackageType System sets the install target
			 * type, which installd needs to accept a bundle id for a directory
			 * install). Otherwise a user app, as Xcode installs one: PackageType
			 * Developer, no system flags (installd refuses a system install
			 * without the system-app entitlement). */
			const BOOL sys = domain == 1;
			MIInstallOptions *o = [[NSClassFromString(@"MIInstallOptions") alloc]
			    initWithLegacyOptionsDictionary:@{ @"PackageType" : sys ? @"System" : @"Developer",
				@"CFBundleIdentifier" : bid }];
			[o setBundleIdentifier:bid];
			if (sys) {
				[o setSystemAppInstall:YES];
				[o setInstallForMigrator:YES];
			}
			NSDate *t0 = [NSDate date];
			dispatch_semaphore_t done = dispatch_semaphore_create(0);
			MIInstallerClient *c = [NSClassFromString(@"MIInstallerClient")
			    installerWithProgressBlock:^(id p) {}];
			[c installURL:url identity:identity targetingDomain:domain withOptions:o
			    returningResultInfo:YES completion:^(BOOL ok, id a, id b, NSError *e) {
				printf("%s (%s): %s after %.1f s\n", argv[i], bid.UTF8String,
				    ok ? "installed" : "FAILED", -t0.timeIntervalSinceNow);
				if (e) {
					printf("  %s\n", e.description.UTF8String);
					failed++;
				}
				dispatch_semaphore_signal(done);
			}];
			dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
		}
		return failed ? 1 : 0;
	}
}
