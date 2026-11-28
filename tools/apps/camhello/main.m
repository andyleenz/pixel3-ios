/*
 * CamHello - the camera through plain AVFoundation, for tools/bluerun apptest.
 *
 * Asks for camera access, lists the capture devices (discovery session and the default video device), runs an
 * AVCaptureSession with a BGRA video data output and a preview layer for 8 s, and writes one line to
 * Documents/hello.txt: devices, access, frames and fps, frame size, mean and spread of a centre row, and
 * any session error. Every outcome writes the line (no device, no access, no frames, 15 s timeout).
 * Each BGRA frame's centre row is hashed: "N distinct of M hashed" tells frames handed out again (the viewfinder
 * loop, cam51-54: the preview cycled through 8 images).
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <sys/sysctl.h>
#include <dlfcn.h>

@interface CamDelegate : UIResponder <UIApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation CamDelegate {
	AVCaptureSession *_session;
	NSMutableString *_line;
	unsigned _frames, _dropped;
	CFTimeInterval _first, _last;
	size_t _w, _h;
	OSType _fmt;
	double _mean, _spread;
	uint64_t _hash[512];
	unsigned _hashed, _distinct;
	BOOL _done;
	const char *volatile _step;	/* the AVFoundation call in progress, named by the timeout */
}

static void
note(NSString *line)
{
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
	[line writeToFile:[docs stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	const char *c = line.UTF8String;
	sysctlbyname("kern.bluesay", NULL, NULL, (void *)c, strlen(c));	/* console line (kernel patch 0231) */
}

- (void)finish:(NSString *)why
{
	@synchronized(self) {
		if (_done)
			return;
		_done = YES;
		double secs = _frames > 1 ? _last - _first : 0;
		[_line appendFormat:@"; %@ (step: %s): %u frames", why, _step, _frames];
		if (_frames > 1)
			[_line appendFormat:@" (%.1f fps), %zux%zu fmt %.4s, centre row mean %.0f spread %.0f, %u dropped",
			    (_frames - 1) / secs, _w, _h, (char *)&(OSType){ CFSwapInt32HostToBig(_fmt) }, _mean, _spread, _dropped];
		[_line appendFormat:@", %u distinct of %u hashed", _distinct, _hashed];
		[_line appendString:@"\n"];
		note(_line);
	}
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UIViewController *vc = [UIViewController new];
	vc.view.backgroundColor = UIColor.darkGrayColor;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	_line = [NSMutableString stringWithString:@"camhello:"];

	_step = "start";
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
	    ^{ [self finish:@"timeout"]; });	/* off the main queue: it fires even when the main thread is stuck */
	_step = "authorization status";
	/* tccd's own answer (0 granted, 1 denied, 2 unknown) next to AVFoundation's (0 not determined, 2 denied, 3 ok) */
	void *tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW);
	int (*preflight)(CFStringRef, CFDictionaryRef) = tcc ? dlsym(tcc, "TCCAccessPreflight") : NULL;
	if (preflight)
		[_line appendFormat:@" tcc %d", preflight(CFSTR("kTCCServiceCamera"), NULL)];
	[_line appendFormat:@" access %ld", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]];
	_step = "request access";
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self->_line appendFormat:@", granted %d;", granted];
			[self devices];	/* the device list does not need access; the session start is refused without it */
		});
	}];
	return YES;
}

- (void)devices
{
	_step = "discovery session";
	NSArray *types = @[ AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInDualCamera,
			    AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInTrueDepthCamera ];
	AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
	    discoverySessionWithDeviceTypes:types mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
	_step = "discovery devices";
	NSUInteger ndev = ds.devices.count;
	[_line appendFormat:@" %lu devices", (unsigned long)ndev];
	for (AVCaptureDevice *d in ds.devices)
		[_line appendFormat:@" [%@ pos %ld, %lu formats]", d.localizedName, (long)d.position, (unsigned long)d.formats.count];
	_step = "default device";
	AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	[_line appendFormat:@"; default %@", dev ? dev.localizedName : @"none"];
	if (dev == nil) {
		[self finish:@"no device"];
		return;
	}
	[self startWith:dev];
}

- (void)startWith:(AVCaptureDevice *)dev
{
	NSError *err = nil;
	_step = "device input";
	AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
	if (in == nil) {
		[_line appendFormat:@", input error %@", err.localizedDescription];
		[self finish:@"no input"];
		return;
	}
	_step = "session";
	_session = [AVCaptureSession new];
	[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:_session
	    queue:nil usingBlock:^(NSNotification *n) {
		NSError *e = n.userInfo[AVCaptureSessionErrorKey];
		@synchronized(self) { [self->_line appendFormat:@", runtime error %ld %@", (long)e.code, e.localizedDescription]; }
	}];
	AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
	out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
	[out setSampleBufferDelegate:self queue:dispatch_queue_create("camhello", DISPATCH_QUEUE_SERIAL)];
	if ([_session canAddInput:in])
		[_session addInput:in];
	else
		[_line appendString:@", cannot add input"];
	if ([_session canAddOutput:out])
		[_session addOutput:out];
	else
		[_line appendString:@", cannot add output"];
	AVCaptureVideoPreviewLayer *pl = [AVCaptureVideoPreviewLayer layerWithSession:_session];
	pl.frame = self.window.bounds;
	pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
	[self.window.rootViewController.view.layer addSublayer:pl];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		self->_step = "startRunning";
		[self->_session startRunning];
		self->_step = "running";
		dispatch_async(dispatch_get_main_queue(), ^{
			[self->_line appendFormat:@", running %d", self->_session.running];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
				[self finish:@"8 s"];
			});
		});
	});
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)connection
{
	CFTimeInterval t = CACurrentMediaTime();
	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
	@synchronized(self) {
		if (_frames++ == 0)
			_first = t;
		_last = t;
		if (pb != NULL && CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA && _hashed < 512) {
			CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
			size_t bpr = CVPixelBufferGetBytesPerRow(pb), hh = CVPixelBufferGetHeight(pb);
			const uint8_t *r = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
			uint64_t hv = 1469598103934665603ull;
			for (size_t yy = 0; yy < hh; yy += 37)
				for (size_t k = 0; k < bpr; k += 3)
					hv = (hv ^ r[yy * bpr + k]) * 1099511628211ull;
			CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
			unsigned j = 0;
			while (j < _hashed && _hash[j] != hv)
				j++;
			_distinct += j == _hashed;
			_hash[_hashed++] = hv;
		}
		if (pb == NULL || (_frames % 30) != 1)
			return;
		_w = CVPixelBufferGetWidth(pb), _h = CVPixelBufferGetHeight(pb), _fmt = CVPixelBufferGetPixelFormatType(pb);
		if (_fmt != kCVPixelFormatType_32BGRA)
			return;
		CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		const uint8_t *row = (const uint8_t *)CVPixelBufferGetBaseAddress(pb) + (_h / 2) * CVPixelBufferGetBytesPerRow(pb);
		double s = 0, s2 = 0;
		for (size_t x = 0; x < _w; x++) {
			double v = (row[4 * x] + row[4 * x + 1] + row[4 * x + 2]) / 3.0;
			s += v, s2 += v * v;
		}
		CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
		_mean = s / _w, _spread = sqrt(fmax(0, s2 / _w - _mean * _mean));
	}
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)connection
{
	@synchronized(self) { _dropped++; }
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([CamDelegate class]));
	}
}
