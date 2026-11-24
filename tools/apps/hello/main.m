/*
 * Hello.app - the first third-party app for the Pixel 3 iOS port (app install, stage S0/S1).
 * A full-screen coloured view with a label; on launch it NSLogs and writes
 * Documents/hello.txt in its data container, so a test can tell it ran.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <UIKit/UIKit.h>

@interface HelloDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation HelloDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	NSString *line = [NSString stringWithFormat:@"hello from %@, pid %d, %@\n",
	    NSBundle.mainBundle.bundleIdentifier, getpid(), NSDate.date];
	NSError *err = nil;
	[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
	BOOL ok = [line writeToFile:[docs stringByAppendingPathComponent:@"hello.txt"] atomically:YES
	                   encoding:NSUTF8StringEncoding error:&err];
	NSLog(@"BLUELINE HELLO: launched, home %@, hello.txt %@%@", NSHomeDirectory(), ok ? @"written" : @"FAILED ",
	    ok ? @"" : err.localizedDescription);

	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UIViewController *vc = [UIViewController new];
	vc.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.45 blue:0.95 alpha:1];
	UILabel *label = [UILabel new];
	label.text = @"Hello, Pixel 3";
	label.textColor = UIColor.whiteColor;
	label.font = [UIFont boldSystemFontOfSize:34];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[vc.view addSubview:label];
	[label.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor].active = YES;
	[label.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor].active = YES;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([HelloDelegate class]));
	}
}
