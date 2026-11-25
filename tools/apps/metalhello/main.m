/*
 * MetalHello.app - an app that draws with Metal in its own process: MTLCreateSystemDefaultDevice, a
 * CAMetalLayer, a spinning triangle each display frame (CADisplayLink), drawables presented to backboardd.
 * At frame 300 (at once if there is no device) it writes Documents/hello.txt, which tools/bluerun apptest
 * waits for: the device's name, the time to 60 frames and a readback of frame 60's drawable (rows cleared,
 * rows left untouched, the first row runs), and where frames
 * 61-300 spent their time: the callback's lateness after its vsync, the nextDrawable wait, encoding and
 * commit, encode start to completion (medians and 90th percentiles, ms) and the vsyncs between callbacks.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>

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
	CFTimeInterval _start, _lastVsync;
	NSString *_first;
	float _late[240], _wait[240], _encode[240], _done[240], _shown[240], _back[240];
	void *_slotTex[4];
	CFTimeInterval _slotAt[4];
	unsigned _gap[6];
	CFTimeInterval _ts0, _cb0;
}

static NSString *
stat_ms(float *v, unsigned n)
{
	float s[240];
	memcpy(s, v, n * sizeof *s);
	for (unsigned i = 1; i < n; i++)
		for (unsigned j = i; j > 0 && s[j - 1] > s[j]; j--) {
			float t = s[j];
			s[j] = s[j - 1];
			s[j - 1] = t;
		}
	return [NSString stringWithFormat:@"%.1f/%.1f", s[n / 2], s[n * 9 / 10]];
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
	CFTimeInterval t0 = CACurrentMediaTime();
	id<CAMetalDrawable> drawable = [_layer nextDrawable];
	CFTimeInterval t1 = CACurrentMediaTime();
	if (drawable == nil)
		return;
	/* how long since this drawable's texture was last presented (its trip through backboardd) */
	void *tex = (__bridge void *)drawable.texture;
	float back = 0;
	int slot = -1;
	for (int i = 0; i < 4; i++)
		if (_slotTex[i] == tex || (slot < 0 && _slotTex[i] == NULL))
			slot = i;
	if (slot >= 0 && _slotTex[slot] == tex)
		back = (t1 - _slotAt[slot]) * 1000;
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
	if (slot >= 0) {
		_slotTex[slot] = tex;
		_slotAt[slot] = CACurrentMediaTime();
	}
	unsigned k = _presented >= 60 && _presented < 300 ? _presented - 60 : 240;
	if (k < 240) {
		_late[k] = (t0 - link.timestamp) * 1000;
		_wait[k] = (t1 - t0) * 1000;
		long g = lround((link.timestamp - _lastVsync) / link.duration);
		_gap[g < 1 ? 0 : g > 5 ? 5 : g]++;
		_back[k] = back;
		_shown[k] = -1;
		__block float *shown = &_shown[k];
		CFTimeInterval at = CACurrentMediaTime();
		[drawable addPresentedHandler:^(id<MTLDrawable> d) {
			*shown = d.presentedTime > 0 ? (d.presentedTime - at) * 1000 : -1;
		}];
		__block float *done = &_done[k];
		[cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
			*done = (CACurrentMediaTime() - t1) * 1000;
		}];
	}
	_lastVsync = link.timestamp;
	if (_presented == 60) {
		_ts0 = link.timestamp;
		_cb0 = t0;
	}
	if (_presented == 299) {
		CFTimeInterval ts = link.timestamp, cbt = t0;
		[cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
			dispatch_async(dispatch_get_main_queue(), ^{
				note([NSString stringWithFormat:@"%@metalhello: frames 61-300 (ms, median/p90): late %@, nextDrawable %@, "
				    "encode+commit %@, encode start to completion %@, present to on screen %@, present to drawable back %@ (%u drawables); "
				    "vsyncs between callbacks 1:%u 2:%u 3:%u 4+:%u; link duration %.3f ms, timestamps %.3f ms apart, %u callbacks in %.1f ms; continuous - absolute %lld ticks\n", self->_first,
				    stat_ms(self->_late, 240), stat_ms(self->_wait, 240), stat_ms(self->_encode, 240), stat_ms(self->_done, 240),
				    stat_ms(self->_shown, 240), stat_ms(self->_back, 240), (unsigned)self->_layer.maximumDrawableCount,
				    self->_gap[1], self->_gap[2], self->_gap[3], self->_gap[4] + self->_gap[5], link.duration * 1000,
				    (ts - self->_ts0) * 1000 / (self->_gap[1] + 2 * self->_gap[2] + 3 * self->_gap[3] + 4 * self->_gap[4] + 5 * self->_gap[5]),
				    240u, (cbt - self->_cb0) * 1000, (long long)(mach_continuous_time() - mach_absolute_time())]);
			});
		}];
	}
	if (++_presented == 60 && !_written) {
		_written = YES;
		id<MTLTexture> tex = drawable.texture;
		id<MTLDevice> dev = _device;
		CFTimeInterval start = _start;
		[cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
			NSString *line = [NSString stringWithFormat:@"metalhello: device %@, 60 frames presented in %.2f s, %u completed; %@\n",
			    dev.name, CACurrentMediaTime() - start, me_completed(self), readback(tex)];
			dispatch_async(dispatch_get_main_queue(), ^{ self->_first = line; });  /* written with frame 300's timings */
		}];
	}
	[cb commit];
	if (k < 240)
		_encode[k] = (CACurrentMediaTime() - t1) * 1000;
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([MetalHelloDelegate class]));
	}
}
