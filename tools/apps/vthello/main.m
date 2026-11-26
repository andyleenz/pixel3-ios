/*
 * VTHello - video encode through VideoToolbox, for tools/bluerun apptest.
 *
 * Encodes 60 synthetic 1280x720 NV12 frames (a moving gradient) with H.264 and with HEVC, then decodes the
 * H.264 stream again, and writes one line to Documents/hello.txt and the console (kern.bluesay, kernel patch
 * 0231): per codec the session status, whether the encoder is hardware, frames out, bytes and time.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>
#include <dlfcn.h>

enum { W = 1280, H = 720, N = 60 };

@interface VTDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

static void
note(NSString *line)
{
	NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
	[line writeToFile:[docs stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	const char *c = line.UTF8String;
	sysctlbyname("kern.bluesay", NULL, NULL, (void *)c, strlen(c));
}

typedef struct {
	unsigned frames;
	size_t bytes;
	OSStatus err;
	int callerr;	/* err came from VTCompressionSessionEncodeFrame (1), not the output callback (0) */
	CMFormatDescriptionRef fmt;
	CMSampleBufferRef first;
} Out;

static void
encoded(void *ref, void *src, OSStatus st, VTEncodeInfoFlags flags, CMSampleBufferRef sb)
{
	Out *o = ref;
	if (st != noErr) {
		o->err = st;
		return;
	}
	if (sb == NULL)
		return;
	o->frames++;
	o->bytes += CMSampleBufferGetTotalSampleSize(sb);
	if (o->fmt == NULL) {
		o->fmt = (CMFormatDescriptionRef)CFRetain(CMSampleBufferGetFormatDescription(sb));
		o->first = (CMSampleBufferRef)CFRetain(sb);
	}
}

static void
decoded(void *ref, void *src, OSStatus st, VTDecodeInfoFlags flags, CVImageBufferRef img, CMTime pts, CMTime dur)
{
	int *ok = ref;
	if (st == noErr && img != NULL)
		*ok = (int)CVPixelBufferGetWidth(img);
	else
		*ok = -(int)st;
}

static CVReturn cv_surface, cv_plain;	/* CVPixelBufferCreate status with and without an IOSurface */

static CVPixelBufferRef
frame(int i)
{
	CVPixelBufferRef pb = NULL;
	NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
	cv_surface = CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pb);
	if (cv_surface != kCVReturnSuccess)
		cv_plain = CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pb);
	if (pb == NULL)
		return NULL;
	CVPixelBufferLockBaseAddress(pb, 0);
	uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
	size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
	for (int r = 0; r < H; r++)
		for (int c = 0; c < W; c++)
			y[r * ys + c] = (uint8_t)(16 + ((c + r + 8 * i) & 0xff) * 219 / 255);
	uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
	size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
	for (int r = 0; r < H / 2; r++)
		memset(uv + r * uvs, 128, W);
	CVPixelBufferUnlockBaseAddress(pb, 0);
	return pb;
}

static NSString *
encode(CMVideoCodecType codec, const char *name, Out *o)
{
	VTCompressionSessionRef s = NULL;
	CFTimeInterval t0 = CACurrentMediaTime();
	OSStatus st = VTCompressionSessionCreate(NULL, W, H, codec, NULL, NULL, NULL, encoded, o, &s);
	if (st != noErr)
		return [NSString stringWithFormat:@" %s create %d;", name, (int)st];
	CFBooleanRef hw = NULL;
	VTSessionCopyProperty(s, CFSTR("UsingHardwareAcceleratedVideoEncoder"),	/* the public constant is iOS 17.4+ */ NULL, &hw);
	VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
	VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(4000000));
	for (int i = 0; i < N && o->err == noErr; i++) {
		CVPixelBufferRef pb = frame(i);
		st = VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
		CVPixelBufferRelease(pb);
		if (st != noErr) {
			o->err = st;
			o->callerr = 1;
			break;
		}
	}
	VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
	double secs = CACurrentMediaTime() - t0;
	VTCompressionSessionInvalidate(s);
	CFRelease(s);
	NSString *r = [NSString stringWithFormat:@" %s (cv %d/%d) hw %s, %u/%d frames, %zu bytes, %.2f s (%.0f fps), err %d%s;", name, cv_surface, cv_plain,
	    hw == NULL ? "?" : (CFBooleanGetValue(hw) ? "yes" : "no"), o->frames, N, o->bytes, secs, o->frames / secs, (int)o->err, o->callerr ? " (encode call)" : ""];
	if (hw)
		CFRelease(hw);
	return r;
}

static NSString *
decode(Out *o)
{
	if (o->fmt == NULL)
		return @" decode: no stream;";
	VTDecompressionSessionRef d = NULL;
	int ok = 0;
	VTDecompressionOutputCallbackRecord cb = { decoded, &ok };
	OSStatus st = VTDecompressionSessionCreate(NULL, o->fmt, NULL, NULL, &cb, &d);
	if (st != noErr)
		return [NSString stringWithFormat:@" decode create %d;", (int)st];
	st = VTDecompressionSessionDecodeFrame(d, o->first, 0, NULL, NULL);
	VTDecompressionSessionWaitForAsynchronousFrames(d);
	VTDecompressionSessionInvalidate(d);
	CFRelease(d);
	return [NSString stringWithFormat:@" decode %d, first frame %d;", (int)st, ok];
}

@implementation VTDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options
{
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UIViewController *vc = [UIViewController new];
	vc.view.backgroundColor = UIColor.darkGrayColor;
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableString *line = [NSMutableString stringWithString:@"vthello:"];
		/* mediaserverd's FigStartCaptureServers finds CMCapture by bundle ID, unloaded (nothing links it) */
		BOOL loaded = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOLOAD | RTLD_LAZY) != NULL;
		CFBundleRef cm = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.CMCapture"));
		[line appendFormat:@" CMCapture loaded %d, by bundle ID %d;", loaded, cm != NULL];
		note([line stringByAppendingString:@" started"]);	/* a hang still leaves a line */
		Out h264 = { 0 }, hevc = { 0 };
		[line appendString:encode(kCMVideoCodecType_H264, "h264", &h264)];
		note(line);
		[line appendString:decode(&h264)];
		note(line);
		[line appendString:encode(kCMVideoCodecType_HEVC, "hevc", &hevc)];
		[line appendString:@"\n"];
		note(line);
	});
	return YES;
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([VTDelegate class]));
	}
}
