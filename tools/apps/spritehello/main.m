/*
 * SpriteHello.app - a SpriteKit scene (Metal underneath): 300 coloured sprites moved and spun by actions, 30
 * physics boxes bouncing, a label drawn by CoreText. After 180 frames it writes Documents/hello.txt with the
 * Metal device, frames per second over those frames, the time physics took and the node count, which
 * tools/bluerun apptest waits for.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Metal/Metal.h>
#import <SpriteKit/SpriteKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>

@interface Scene : SKScene
@end

static double
now_ms(void)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	return mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

@implementation Scene {
	unsigned _frames;
	CFTimeInterval _start, _first180, _steady;   /* frame 1, frame 181, frame 121 */
	double _updateAt, _physicsMs, _physics180;
	BOOL _written;
	CFTimeInterval _prev;
	unsigned _gaps[5];      /* frames 121-300: vsyncs between updates, 1 2 3 4 5+ */
}

- (void)didSimulatePhysics
{
	_physicsMs += now_ms() - _updateAt;
}

- (void)didMoveToView:(SKView *)view
{
	self.backgroundColor = [UIColor colorWithRed:0.05 green:0.07 blue:0.12 alpha:1];
	self.physicsWorld.gravity = CGVectorMake(0, 0);
	self.physicsBody = [SKPhysicsBody bodyWithEdgeLoopFromRect:self.frame];
	CGFloat w = self.size.width, h = self.size.height;
	for (int i = 0; i < 330; i++) {
		UIColor *c = [UIColor colorWithHue:(i % 30) / 30.0 saturation:0.8 brightness:1 alpha:1];
		CGFloat side = 14 + i % 5 * 4;
		SKSpriteNode *s = [SKSpriteNode spriteNodeWithColor:c size:CGSizeMake(side, side)];
		s.position = CGPointMake(arc4random_uniform((uint32_t)w), arc4random_uniform((uint32_t)h));
		if (i < 30) {
			// physics: a few boxes bouncing off the edges, not a pile
			s.physicsBody = [SKPhysicsBody bodyWithRectangleOfSize:s.size];
			s.physicsBody.restitution = 1;
			s.physicsBody.linearDamping = 0;
			s.physicsBody.velocity = CGVectorMake((CGFloat)arc4random_uniform(400) - 200, (CGFloat)arc4random_uniform(400) - 200);
		} else {
			SKAction *there = [SKAction moveTo:CGPointMake(arc4random_uniform((uint32_t)w), arc4random_uniform((uint32_t)h))
			                          duration:1.5 + i % 4 * 0.5];
			SKAction *back = [SKAction moveTo:s.position duration:there.duration];
			[s runAction:[SKAction repeatActionForever:[SKAction sequence:@[ there, back ]]]];
			[s runAction:[SKAction repeatActionForever:[SKAction rotateByAngle:M_PI duration:1 + i % 3]]];
		}
		[self addChild:s];
	}
	SKLabelNode *label = [SKLabelNode labelNodeWithText:@"SpriteKit on Pixel 3"];
	label.fontName = @"Helvetica-Bold";
	label.fontSize = 30;
	label.position = CGPointMake(self.size.width / 2, self.size.height * 0.85);
	[self addChild:label];
}

- (void)update:(NSTimeInterval)now
{
	_updateAt = now_ms();
	if (_frames++ == 0)
		_start = now;
	if (_frames == 121)
		_steady = now;
	if (_frames > 121 && _frames <= 301) {
		long g = lround((now - _prev) * 60.0);
		_gaps[g < 1 ? 0 : (g > 5 ? 4 : g - 1)]++;
	}
	_prev = now;
	if (_frames == 181) {
		_first180 = now - _start;
		_physics180 = _physicsMs / 181;
	}
	/* frames 121-300 too: the first 120 include the launch */
	if (_frames == 301 && !_written) {
		_written = YES;
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		CALayer *layer = self.view.layer;
		NSString *drawables = [layer isKindOfClass:[CAMetalLayer class]] ?
		    [NSString stringWithFormat:@"CAMetalLayer, %lu drawables, presentsWithTransaction %d, %.0fx%.0f",
		    (unsigned long)((CAMetalLayer *)layer).maximumDrawableCount, ((CAMetalLayer *)layer).presentsWithTransaction,
		    ((CAMetalLayer *)layer).drawableSize.width, ((CAMetalLayer *)layer).drawableSize.height] :
		    NSStringFromClass(layer.class);
		drawables = [drawables stringByAppendingFormat:@"; vsyncs between updates 1:%u 2:%u 3:%u 4:%u 5+:%u",
		    _gaps[0], _gaps[1], _gaps[2], _gaps[3], _gaps[4]];
		NSString *line = [NSString stringWithFormat:@"spritehello: device %@, 180 frames in %.2f s (%.1f fps), physics %.1f ms a frame, %lu nodes; "
		    "frames 121-300 %.1f fps; layer %@\n",
		    dev ? dev.name : @"none", _first180, 180 / _first180, _physics180, (unsigned long)self.children.count,
		    180 / (now - _steady), drawables];
		NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
		[line writeToFile:[docs stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
		NSLog(@"BLUELINE SPRITEHELLO: %@", line);
	}
}
@end

@interface SpriteDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation SpriteDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UIViewController *vc = [UIViewController new];
	SKView *view = [[SKView alloc] initWithFrame:self.window.bounds];
	view.showsFPS = YES;
	view.showsNodeCount = YES;
	vc.view = view;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	[view presentScene:[Scene sceneWithSize:view.bounds.size]];
	return YES;
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([SpriteDelegate class]));
	}
}
