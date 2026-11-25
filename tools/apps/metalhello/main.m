/*
 * MetalHello.app - an app that draws with Metal in its own process: MTLCreateSystemDefaultDevice, a
 * CAMetalLayer, a spinning triangle each display frame (CADisplayLink), drawables presented to backboardd.
 * After 60 presented frames (or at once if there is no device) it writes Documents/hello.txt with the
 * device's name, the frame count and a readback of frame 60's drawable (rows cleared, rows left
 * untouched, the first row runs), which tools/bluerun apptest waits for.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

@interface SpinView : UIView
@end
@implementation SpinView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

@interface MetalHelloDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation MetalHelloDelegate {
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	id<MTLRenderPipelineState> _pipeline;
	CAMetalLayer *_layer;
	unsigned _presented, _completed;
	BOOL _written;
	CFTimeInterval _start;
}

static void
note(NSString *line)
{
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
	[line writeToFile:[docs stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	NSLog(@"BLUELINE METALHELLO: %@", line);
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UIViewController *vc = [UIViewController new];
	SpinView *view = [[SpinView alloc] initWithFrame:self.window.bounds];
	vc.view = view;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];

	NSError *err = nil;
	_device = MTLCreateSystemDefaultDevice();
	if (_device == nil) {
		note(@"metalhello: no Metal device\n");
		return YES;
	}
	id<MTLLibrary> lib = [_device newDefaultLibrary];
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"spin_v"];
	pd.fragmentFunction = [lib newFunctionWithName:@"spin_f"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	_pipeline = lib ? [_device newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
	if (_pipeline == nil) {
		note([NSString stringWithFormat:@"metalhello: device %@, no pipeline (library %@): %@\n", _device.name,
		    lib ? @"ok" : @"missing", err.localizedDescription]);
		return YES;
	}
	_queue = [_device newCommandQueue];
	_layer = (CAMetalLayer *)view.layer;
	_layer.device = _device;
	_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	_layer.framebufferOnly = NO;
	_layer.contentsScale = UIScreen.mainScreen.scale;
	_layer.drawableSize = CGSizeMake(view.bounds.size.width * _layer.contentsScale,
	                                 view.bounds.size.height * _layer.contentsScale);
	_start = CACurrentMediaTime();
	[[CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)] addToRunLoop:NSRunLoop.mainRunLoop
	                                                                           forMode:NSRunLoopCommonModes];
	return YES;
}

static unsigned
me_completed(MetalHelloDelegate *d)
{
	return __atomic_load_n(&d->_completed, __ATOMIC_RELAXED);
}

// The same count over the drawable's IOSurface as the CPU sees it (what backboardd composites).
static NSString *
surface_rows(id<MTLTexture> tex)
{
	IOSurfaceRef surf = tex.iosurface;
	if (surf == NULL)
		return @"no iosurface";
	IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
	const uint8_t *base = IOSurfaceGetBaseAddress(surf);
	size_t pitch = IOSurfaceGetBytesPerRow(surf), w = IOSurfaceGetWidth(surf), h = IOSurfaceGetHeight(surf);
	unsigned clear = 0, zero = 0, runs = 0, count = 0;
	char last = 0;
	NSMutableString *r = [NSMutableString string];
	for (size_t y = 0; y < h; y++) {
		const uint8_t *p = base + y * pitch + (w / 4) * 4;
		char k = p[0] == 31 && p[1] == 20 && p[2] == 20 ? 'c' : !p[0] && !p[1] && !p[2] && !p[3] ? 'z' : 'o';
		clear += k == 'c', zero += k == 'z';
		if (k != last && last) {
			if (runs++ < 24)
				[r appendFormat:@" %c%u", last, count];
			count = 0;
		}
		last = k, count++;
	}
	if (runs < 24)
		[r appendFormat:@" %c%u", last, count];
	IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
	return [NSString stringWithFormat:@"iosurface %zux%zu pitch %zu: %u clear rows, %u zero rows, runs%@", w, h, pitch,
	    clear, zero, r];
}

// Rows of the drawable whose first, middle and last pixels are all the clear colour, rows all zero there,
// and the first row runs as kind:count (c clear, z zero, o other).
static NSString *
readback(id<MTLTexture> tex)
{
	NSUInteger w = tex.width, h = tex.height, pitch = w * 4;
	uint8_t *px = malloc(pitch * h);
	[tex getBytes:px bytesPerRow:pitch fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
	unsigned clear = 0, zero = 0, runs = 0;
	char last = 0;
	unsigned count = 0;
	NSMutableString *r = [NSMutableString string];
	for (NSUInteger y = 0; y < h; y++) {
		const uint8_t *row = px + y * pitch;
		int c = 1, z = 1;
		for (NSUInteger x = 0; x < w; x += w / 2 - 1) {
			const uint8_t *p = row + x * 4; // BGRA; clear (0.08, 0.08, 0.12)
			c &= p[0] == 31 && p[1] == 20 && p[2] == 20;
			z &= !p[0] && !p[1] && !p[2] && !p[3];
		}
		char k = c ? 'c' : z ? 'z' : 'o';
		clear += c, zero += z;
		if (k != last && last) {
			if (runs++ < 24)
				[r appendFormat:@" %c%u", last, count];
			count = 0;
		}
		last = k, count++;
	}
	if (runs < 24)
		[r appendFormat:@" %c%u", last, count];
	free(px);
	return [NSString stringWithFormat:@"readback %lux%lu: %u clear rows, %u zero rows, runs%@; %@", (unsigned long)w,
	    (unsigned long)h, clear, zero, r, surface_rows(tex)];
}

- (void)frame:(CADisplayLink *)link
{
	id<CAMetalDrawable> drawable = [_layer nextDrawable];
	if (drawable == nil)
		return;
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = drawable.texture;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0.08, 0.08, 0.12, 1);
	id<MTLCommandBuffer> cb = [_queue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	float angle = (float)(CACurrentMediaTime() - _start) * 2.0f;
	[enc setRenderPipelineState:_pipeline];
	[enc setVertexBytes:&angle length:sizeof angle atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[enc endEncoding];
	__weak typeof(self) weak = self;
	[cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
		typeof(self) me = weak;
		if (me && b.status == MTLCommandBufferStatusCompleted)
			__atomic_add_fetch(&me->_completed, 1, __ATOMIC_RELAXED);
	}];
	[cb presentDrawable:drawable];
	if (++_presented == 60 && !_written) {
		_written = YES;
		id<MTLTexture> tex = drawable.texture;
		id<MTLDevice> dev = _device;
		CFTimeInterval start = _start;
		[cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
			note([NSString stringWithFormat:@"metalhello: device %@, 60 frames presented in %.2f s, %u completed; %@\n",
			    dev.name, CACurrentMediaTime() - start, me_completed(self), readback(tex)]);
		}];
	}
	[cb commit];
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([MetalHelloDelegate class]));
	}
}
