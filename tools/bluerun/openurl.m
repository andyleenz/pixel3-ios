/*
 * openurl - open a URL as SpringBoard would (LSApplicationWorkspace openSensitiveURL), e.g. a Settings pane:
 *
 *   openurl prefs:root=PASSCODE
 *
 * Prints "OPENURL: ok URL" or "OPENURL: failed URL". Signed with apptest.ent (launch-applications entitlements).
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options;
@end

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: openurl URL\n");
		return 2;
	}
	@autoreleasepool {
		NSURL *u = [NSURL URLWithString:@(argv[1])];
		Class ws = NSClassFromString(@"LSApplicationWorkspace");
		BOOL ok = u && ws && [[ws defaultWorkspace] openSensitiveURL:u withOptions:nil];
		printf("OPENURL: %s %s\n", ok ? "ok" : "failed", argv[1]);
		return ok ? 0 : 1;
	}
}
