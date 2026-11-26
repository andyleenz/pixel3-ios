/*
 * bluecam - a CMCapture capture-device plug-in for the Pixel 3 cameras.
 *
 * CMCapture (mediaserverd) loads the first plug-in whose IOKit class exists:
 * FigCaptureGetCaptureDeviceCreateFunction() walks {AppleH13CamIn, /System/Library/MediaCapture/H13ISP.mediacapture,
 * H13ISPCaptureDeviceCreate}, then H10, H9, H6. Kernel patch 0232 publishes an AppleH13CamIn stub, and this
 * library is installed at that path, so every capture client (AVFoundation apps, Camera.app) goes through it.
 *
 * Stage 2 (this file): a device with one back-camera stream that answers its port type and the stream formats
 * named in CMCapture's AVCaptureSession.plist; AVFoundation lists "Back Camera".
 * Stage 3: the stream's outputs, Clock and Start; frames from the kernel's /dev/blueline-camera (0233), synthetic without it.
 * Every CopyProperty / SetProperty key and every class call is printed on the console (kern.bluesay, kernel patch
 * 0231), so the property set CMCapture needs can be filled in from what it asks for. BWFigCaptureDevice reads SupportedPropertiesDictionary first and then asks the
 * device only for keys in it (an error for it, or a key missing, drops the device), so for now that dictionary
 * claims every key (AnyKey below).
 *
 * Interface (read from H10ISP.mediacapture, iOS 16.7): CMDerivedObjectCreate objects, WebKit's CMBaseClass layout.
 *   OSStatus H13ISPCaptureDeviceCreate(CFAllocatorRef, void *unknown, FigCaptureDeviceRef *out)
 *   device base: storage 256; Invalidate, Finalize, CopyProperty, SetProperty
 *   device class v3: CreateProcessingSession, RequestStreams, RelinquishStreams, PerformPearlCalibration
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include "../blueline_camera.h"
#include <mach-o/dyld.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

typedef struct OpaqueCMBaseObject *CMBaseObjectRef;
typedef const void *CMBaseClassID;

typedef struct {
	CFIndex version;
	size_t derivedStorageSize;
	Boolean (*equal)(CMBaseObjectRef, CMBaseObjectRef);
	OSStatus (*invalidate)(CMBaseObjectRef);
	void (*finalize)(CMBaseObjectRef);
	CFStringRef (*copyDebugDescription)(CMBaseObjectRef);
	OSStatus (*copyProperty)(CMBaseObjectRef, CFStringRef, CFAllocatorRef, void *);
	OSStatus (*setProperty)(CMBaseObjectRef, CFStringRef, CFTypeRef);
	OSStatus (*notificationBarrier)(CMBaseObjectRef);
	const void *protocolVTable;
	void *reserved;
} CMBaseClass;

typedef struct {
	CFIndex version;	/* 3 */
	OSStatus (*createProcessingSession)(CMBaseObjectRef, CFAllocatorRef, CFDictionaryRef, const void **);
	OSStatus (*requestStreams)(CMBaseObjectRef, CFArrayRef, CFDictionaryRef);
	OSStatus (*relinquishStreams)(CMBaseObjectRef, CFArrayRef, CFDictionaryRef);
	OSStatus (*performPearlCalibration)(CMBaseObjectRef, void *, CFDictionaryRef);
	void *reserved;
} DeviceClass;

typedef struct {
	const void *reserved;
	const CMBaseClass *baseClass;
	const void *derivedClass;
} CMBaseVTable;

typedef struct {
	CFIndex version;	/* 2 */
	OSStatus (*start)(CMBaseObjectRef);
	OSStatus (*stop)(CMBaseObjectRef);
	OSStatus (*addAttachmentsToSampleBuffer)(CMBaseObjectRef, void *, CFDictionaryRef);
	void *reserved;
} StreamClass;

enum { kValueNotAvailable = -12783, kUnsupported = -12782 };	/* kCMBaseObjectError_* */

static OSStatus (*pCMDerivedObjectCreate)(CFAllocatorRef, const CMBaseVTable *, CMBaseClassID, CMBaseObjectRef *);
static CMBaseClassID (*pFigCaptureDeviceGetClassID)(void);
static CMBaseClassID (*pFigCaptureStreamGetClassID)(void);
static CMBaseObjectRef backStream;	/* stage 2: one stream, the back camera, answering little */

static void
say(const char *fmt, ...)
{
	static int lines;
	if (++lines > 400)	/* a polling loop must not flood the console */
		return;
	char buf[480];
	va_list ap;
	va_start(ap, fmt);
	int n = snprintf(buf, sizeof buf, "bluecam: ");
	vsnprintf(buf + n, sizeof buf - n, fmt, ap);
	va_end(ap);
	sysctlbyname("kern.bluesay", NULL, NULL, buf, strlen(buf));
}

static const char *
str(CFStringRef s, char *buf, size_t len)
{
	if (s == NULL || !CFStringGetCString(s, buf, len, kCFStringEncodingUTF8))
		snprintf(buf, len, "%s", s ? "?" : "(null)");
	return buf;
}

static const char *
desc(CFTypeRef v, char *buf, size_t len)
{
	if (v == NULL)
		return "(null)";
	CFStringRef d = CFCopyDescription(v);
	str(d, buf, len);
	CFRelease(d);
	for (char *p = buf; *p; p++)
		if (*p == '\n')
			*p = ' ';
	return buf;
}

/* SupportedPropertiesDictionary for discovery: every key is "supported" (an empty dictionary as its value), so
 * each key CMCapture wants reaches devCopyProperty and the log. */
@interface BCAnyKey : NSDictionary
@end
@implementation BCAnyKey
- (NSUInteger)count { return 0; }
- (id)objectForKey:(id)key { return key ? @{} : nil; }
- (NSEnumerator *)keyEnumerator { return [@[] objectEnumerator]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

/*
 * The stream's SupportedFormatsArray. CMCapture names its formats in the platform's AVCaptureSession.plist
 * (MultiStream FigCaptureStreamFormats: SensorWidth/Height, MaxFrameRate, Binned, FES and FES size) and matches
 * each name to an entry here by those values (csu_resolveFormatIndexForNamedStreamFormat). So the entries are
 * made from that plist on the phone, one per named format of the back camera, and the output is that size
 * (the front-end scaler's when it has one) in 420f. The key strings are CMCapture's own (dlsym).
 */
static CFStringRef
key(const char *name)
{
	CFStringRef *k = dlsym(RTLD_DEFAULT, name);
	if (k == NULL || *k == NULL)
		say("no key %s", name);
	return k ? *k : NULL;
}

static void
put(NSMutableDictionary *d, const char *name, id value)
{
	CFStringRef k = key(name);
	if (k && value)
		d[(__bridge NSString *)k] = value;
}

/* A scaler output of a format (SupportedOutputs; redfin's camera_device.c output_info(), whose preview runs in Camera.app). */
static NSDictionary *
scalerInfo(int w, int h)
{
	return @{ @"SupportedPixelFormats": @[ @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange), @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
			@(kCVPixelFormatType_32BGRA) ],
		  @"NativeWidth": @(w), @"NativeHeight": @(h), @"MaxDownscaleFactor": @32.0, @"MaxScaleFactor": @1.0,
		  @"MinScaleFactor": @(1.0 / 32), @"OutputWidthAlignmentRequirement": @16 };
}

static NSArray *
backFormats(void)
{
	static NSArray *made;
	if (made)
		return made;
	NSDictionary *plist = nil;
	for (NSString *dir in @[ @"D22", @"D221" ]) {
		NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/CMCapture.framework/%@/AVCaptureSession.plist", dir];
		if ((plist = [NSDictionary dictionaryWithContentsOfFile:path]))
			break;
	}
	NSDictionary *named = nil;
	for (NSDictionary *dev in plist[@"AVCaptureDevices"])
		if ([dev[@"position"] intValue] == 1 && dev[@"deviceType"] == nil)	/* the back wide camera */
			named = dev[@"MultiStream"][@"FigCaptureStreamFormats"];
	NSMutableArray *formats = [NSMutableArray array];
	for (NSString *name in [named.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
		NSDictionary *f = named[name];
		BOOL fes = [f[@"FES"] boolValue];
		int sw = [f[@"SensorWidth"] intValue], sh = [f[@"SensorHeight"] intValue];
		int w = fes ? [f[@"FESWidth"] intValue] : sw, h = fes ? [f[@"FESHeight"] intValue] : sh;
		float maxRate = f[@"MaxFrameRate"] ? [f[@"MaxFrameRate"] floatValue] : 30;
		CMVideoFormatDescriptionRef fd = NULL;
		CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, w, h, NULL, &fd);
		NSMutableDictionary *d = [NSMutableDictionary dictionary];
		d[(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
		put(d, "kFigSupportedFormat_FormatDescription", (__bridge_transfer id)fd);
		put(d, "kFigSupportedFormat_VideoMaxWidth", @(w));
		put(d, "kFigSupportedFormat_VideoMaxHeight", @(h));
		put(d, "kFigSupportedFormat_VideoMinFrameRate", @(3.0f));
		put(d, "kFigSupportedFormat_VideoMaxFrameRate", @(maxRate));
		put(d, "kFigSupportedFormat_VideoIsBinned", @([f[@"Binned"] boolValue]));
		put(d, "kFigSupportedFormat_VideoFieldOfView", @(65.0f));	/* Pixel 3 main camera, horizontal */
		put(d, "kFigSupportedFormat_Experimental", @NO);
		put(d, "kFigCaptureStreamVideoFormatKey_SensorWidth", @(sw));
		put(d, "kFigCaptureStreamVideoFormatKey_SensorHeight", @(sh));
		put(d, "kFigCaptureStreamVideoFormatKey_SensorHDRMode", @0);
		/*
		 * What the graph builder reads next (redfin, by hooks): the crop and distortion-corrected sizes (all the
		 * sensor: no crop, no GDC), the scalers' outputs, exposure and gain limits.
		 */
		BOOL binned = [f[@"Binned"] boolValue];
		d[@"VideoBinningFactorHorizontal"] = @(binned ? 2 : 1);
		d[@"VideoBinningFactorVertical"] = @(binned ? 2 : 1);
		d[@"VideoMinIntegrationTime"] = @100;
		d[@"VideoMaxIntegrationTime"] = @(1000000 / 15);
		d[@"VideoRawBitDepth"] = @10;
		d[@"ISOBase"] = @32.0;
		d[@"DefaultAEMaxGain"] = @64.0;
		d[@"PixelSize"] = @1.4;		/* IMX363, um */
		for (NSString *k in @[ @"SensorCrop", @"PreGDCSensorCrop", @"PostGDCCrop", @"GeometricDistortionCorrectedNative" ]) {
			d[[k stringByAppendingString:@"Width"]] = @(sw);
			d[[k stringByAppendingString:@"Height"]] = @(sh);
		}
		d[@"SupportedOutputs"] = @{ @"PrimaryScaler": scalerInfo(w, h), @"SecondaryScaler": scalerInfo(w, h), @"StillImage": scalerInfo(sw, sh) };
		if (fes) {
			put(d, "kFigCaptureStreamVideoFormatKey_FrontEndScalerOutputWidth", @(w));
			put(d, "kFigCaptureStreamVideoFormatKey_FrontEndScalerOutputHeight", @(h));
		}
		[formats addObject:d];
		say("format %lu %s: sensor %dx%d, out %dx%d, %.0f fps", (unsigned long)formats.count - 1, name.UTF8String, sw, sh, w, h,
		    maxRate);
	}
	if (formats.count == 0)
		say("no back-camera formats in AVCaptureSession.plist");
	return made = formats;
}

/* --- stream (H10ISP: base v1, storage 0xc08; stream class v2: Start, Stop, AddAttachmentsToSampleBuffer) --- */

/*
 * Stage 3, after ios-redfin's phone/audio/camera_device.c (MIT): the properties the capture graph reads and sets
 * (SupportedPropertiesDictionary lists them, as redfin's), the host clock, and the outputs. The graph hands each
 * output a configuration with its own CVPixelBufferPool ("BufferPool"), switches outputs on in VideoOutputsEnabled
 * and gives a PixelBufferHandler block per output in VideoOutputHandlers; Start runs a thread that fills one pool
 * buffer per enabled output and frame and calls the handler. Frames are synthetic for now (moving bars), until
 * the kernel's frame device exists.
 */
typedef void (^PixelBufferHandler)(CVPixelBufferRef, CMTime);

enum { OUTPUTS = 3, HELD = 3 };
static NSString *const outputNames[OUTPUTS] = { @"PrimaryScaler", @"SecondaryScaler", @"StillImage" };

static struct {
	pthread_mutex_t lock;
	NSDictionary *config[OUTPUTS];
	BOOL enabled[OUTPUTS];
	PixelBufferHandler handler[OUTPUTS];
	CVPixelBufferRef held[OUTPUTS][HELD];	/* given last: kept so the pool hands out others (redfin: tearing) */
	unsigned heldNext[OUTPUTS];
	uint64_t delivered[OUTPUTS], refused[OUTPUTS];
	NSDictionary *colourInfo;
	int formatIndex;
	double minFps, maxFps;
	BOOL running;
	unsigned generation;
	NSDictionary *metadata;			/* the last frame's, for AddAttachmentsToSampleBuffer */
} st = { .lock = PTHREAD_MUTEX_INITIALIZER, .maxFps = 30 };

static NSDictionary *
props(const char *const (*p)[3], size_t n)
{
	NSMutableDictionary *d = [NSMutableDictionary dictionary];
	for (size_t i = 0; i < n; i++)
		d[@(p[i][0])] = @{ @"PropertyType": @(p[i][1]), @"ReadWriteStatus": @(p[i][2]) };
	return d;
}

/* redfin's lists (camera_device.c stream_props / device_props), less the flash, focus and manual-exposure keys */
static const char *const streamProps[][3] = {
	{ "PortType", "String", "ReadOnly" }, { "UniqueID", "String", "ReadOnly" }, { "NonLocalizedName", "String", "ReadOnly" },
	{ "SupportedFormatsArray", "Collection", "ReadOnly" }, { "FocalLength", "Number", "ReadOnly" },
	{ "LensFNumber", "Number", "ReadOnly" }, { "PixelSize", "Number", "ReadOnly" },
	{ "MaxZoomFactor", "Number", "ReadOnly" }, { "SupportedColorSpaces", "Collection", "ReadOnly" },
	{ "HasAutoFocusPositionSensor", "Boolean", "ReadOnly" }, { "Clock", "Clock", "ReadOnly" },
	{ "FormatIndex", "Number", "ReadWrite" }, { "MinimumFrameRate", "Number", "ReadWrite" }, { "MaximumFrameRate", "Number", "ReadWrite" },
	{ "MaximumAllowedFrameRate", "Number", "ReadWrite" }, { "VideoOutputConfigurations", "Collection", "ReadWrite" },
	{ "VideoOutputsEnabled", "Collection", "ReadWrite" }, { "VideoOutputHandlers", "Collection", "WriteOnly" },
	{ "DeferAdditionOfAttachments", "Boolean", "ReadWrite" }, { "ColorSpace", "Number", "ReadWrite" },
	{ "ZoomFactor", "Number", "ReadWrite" }, { "ExposureBias", "Number", "ReadWrite" }, { "DeviceOrientation", "Number", "ReadWrite" },
	{ "StillImageCaptureNow", "Collection", "WriteOnly" }, { "LockAENow", "Boolean", "WriteOnly" }, { "UnlockAENow", "Boolean", "WriteOnly" },
	{ "LockAWBNow", "Boolean", "WriteOnly" }, { "UnlockAWBNow", "Boolean", "WriteOnly" }, { "MaxIntegrationTime", "Number", "ReadWrite" },
	{ "AEMaxGain", "Number", "ReadWrite" }, { "AEMinGain", "Number", "ReadWrite" }, { "FaceDetectionEnabled", "Boolean", "ReadWrite" },
	{ "VideoRecordingInProgress", "Boolean", "ReadWrite" }, { "MemoryPoolID", "Number", "ReadWrite" },
	{ "ChromaNoiseReductionEnabled", "Boolean", "ReadWrite" }, { "TemporalNoiseReductionEnabled", "Boolean", "ReadWrite" },
	{ "MultipleOutputSupportEnabled", "Boolean", "ReadWrite" }, { "VideoOutputsColorInfo", "Collection", "ReadWrite" },
	{ "RegionOfInterestForCameraControls", "Collection", "ReadWrite" }, { "AEMeteringMode", "Number", "ReadWrite" },
	{ "MaxFrameCoalescingDuration", "Number", "ReadWrite" }, { "LimitAERange", "Boolean", "ReadWrite" },
	{ "TimeMachineSuspendNow", "Boolean", "WriteOnly" }, { "TimeMachineResumeNow", "Boolean", "WriteOnly" },
};
static const char *const deviceProps[][3] = {
	{ "StreamArray", "Collection", "ReadOnly" }, { "Clock", "Clock", "ReadOnly" }, { "ClientIsActive", "Boolean", "ReadWrite" },
	{ "SupportedSynchronizedStreamsGroups", "Collection", "ReadOnly" }, { "MemoryPoolID", "Number", "ReadWrite" },
};

/* the frames' metadata (redfin's md_names): CMCapture's keys, by dlsym; kFigCaptureSampleBufferAttachmentKey_MetadataDictionary */
static NSDictionary *
frameMetadata(uint64_t hostTime, double fps)
{
	static CFStringRef attach;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ attach = key("kFigCaptureSampleBufferAttachmentKey_MetadataDictionary"); });
	if (attach == NULL)
		return nil;
	NSMutableDictionary *m = [NSMutableDictionary dictionary];
	CFStringRef *back = dlsym(RTLD_DEFAULT, "kFigCapturePortType_BackFacingCamera");
	put(m, "kFigCaptureStreamMetadata_PortType", back ? (__bridge NSString *)*back : nil);
	put(m, "kFigCaptureSampleBufferAttachmentKey_OriginalPresentationTimeStamp",
	    CFBridgingRelease(CMTimeCopyAsDictionary(CMClockMakeHostTimeFromSystemUnits(hostTime), NULL)));
	put(m, "kFigCaptureStreamMetadata_ExposureTime", @(1.0 / fps));
	put(m, "kFigCaptureStreamMetadata_AGC", @256);
	put(m, "kFigCaptureStreamMetadata_ispDGain", @256);
	put(m, "kFigCaptureStreamMetadata_sensorDGain", @256);
	put(m, "kFigCaptureStreamMetadata_ISOBase", @32.0);
	put(m, "kFigCaptureStreamMetadata_CurrentFrameRate", @(fps));
	put(m, "kFigCaptureStreamMetadata_LuxLevel", @300);
	put(m, "kFigCaptureStreamMetadata_NormalizedSNR", @40.0);
	put(m, "kFigCaptureStreamMetadata_AFStatus", @0);
	put(m, "kFigCaptureStreamMetadata_FocusingMethod", @0);
	put(m, "kFigCaptureStreamMetadata_AEStable", @YES);
	put(m, "kFigCaptureStreamMetadata_AWBStable", @YES);
	put(m, "kFigCaptureStreamMetadata_AELocked", @NO);
	put(m, "kFigCaptureStreamMetadata_AWBLocked", @NO);
	put(m, "kFigCaptureStreamMetadata_AFLocked", @NO);
	put(m, "kFigCaptureStreamMetadata_ZoomFactor", @1.0);
	return m;
}

/* a synthetic picture: eight vertical bars moving one bar width a second, luma ramp top to bottom */
static void
fillSynthetic(CVPixelBufferRef pb, unsigned n, double fps)
{
	size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
	OSType pf = CVPixelBufferGetPixelFormatType(pb);
	size_t shift = (size_t)(n * (w / 8) / fps);
	static const uint8_t bars[8][3] = {	/* B G R */
		{ 235, 235, 235 }, { 16, 235, 235 }, { 235, 235, 16 }, { 16, 235, 16 },
		{ 235, 16, 235 }, { 16, 16, 235 }, { 235, 16, 16 }, { 16, 16, 16 } };
	CVPixelBufferLockBaseAddress(pb, 0);
	if (pf == kCVPixelFormatType_32BGRA) {
		uint8_t *base = CVPixelBufferGetBaseAddress(pb);
		size_t bpr = CVPixelBufferGetBytesPerRow(pb);
		for (size_t y = 0; y < h; y++) {
			uint8_t *row = base + y * bpr;
			for (size_t x = 0; x < w; x++) {
				const uint8_t *c = bars[((x + shift) * 8 / w) % 8];
				row[4 * x] = c[0], row[4 * x + 1] = c[1], row[4 * x + 2] = c[2], row[4 * x + 3] = 255;
			}
		}
	} else if (CVPixelBufferGetPlaneCount(pb) == 2) {	/* 420f / 420v: Y, then CbCr at half size */
		uint8_t *yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
		size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
		for (size_t y = 0; y < h; y++)
			for (size_t x = 0; x < w; x++) {
				const uint8_t *c = bars[((x + shift) * 8 / w) % 8];
				int Y = (66 * c[2] + 129 * c[1] + 25 * c[0] + 128) / 256 + 16;
				yp[y * ys + x] = (uint8_t)(Y * (h + y) / (2 * h));
				if ((y & 1) == 0 && (x & 1) == 0) {
					cp[(y / 2) * cs + x] = (uint8_t)((-38 * c[2] - 74 * c[1] + 112 * c[0] + 128) / 256 + 128);
					cp[(y / 2) * cs + x + 1] = (uint8_t)((112 * c[2] - 94 * c[1] - 18 * c[0] + 128) / 256 + 128);
				}
			}
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
}

static void
letGo(int i)
{
	for (int k = 0; k < HELD; k++)
		if (st.held[i][k] != NULL) {
			CVPixelBufferRelease(st.held[i][k]);
			st.held[i][k] = NULL;
		}
}

/* one pool buffer for output i (under st.lock), or NULL: no pool, or none to spare */
static CVPixelBufferRef
outputBuffer(int i)
{
	id pool = st.config[i][@"BufferPool"];
	CVPixelBufferRef pb = NULL;
	if (pool == nil || CFGetTypeID((__bridge CFTypeRef)pool) != CVPixelBufferPoolGetTypeID()) {
		if (st.refused[i]++ == 0)
			say("%s: no BufferPool in its configuration", outputNames[i].UTF8String);
		return NULL;
	}
	/* at most HELD kept here plus a few downstream: a stalled consumer gets dropped frames, not a growing pool (jetsam) */
	NSDictionary *aux = @{ (id)kCVPixelBufferPoolAllocationThresholdKey: @(HELD + 4) };
	for (unsigned k = 0; CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, (__bridge CVPixelBufferPoolRef)pool,
	    (__bridge CFDictionaryRef)aux, &pb) != kCVReturnSuccess && k < HELD; k++) {
		unsigned oldest = (st.heldNext[i] + k) % HELD;	/* a pool that will not grow: give back the oldest kept */
		if (st.held[i][oldest] != NULL) {
			CVPixelBufferRelease(st.held[i][oldest]);
			st.held[i][oldest] = NULL;
		}
	}
	if (pb == NULL && st.refused[i]++ % 300 == 0)
		say("%s: pool has no buffer to spare (%llu)", outputNames[i].UTF8String, (unsigned long long)st.refused[i]);
	return pb;
}

/*
 * The kernel's frames (/dev/blueline-camera, patch 0233): MIPI RAW10, RGGB. Each output pixel takes the nearest 2x2 cell
 * (R, the mean of the two Gs, B) from the top 8 bits of each sample, less the black level, times the white balance (grey
 * world, from the last frame) and a gain that brings the green mean to the target, through a gamma table.
 */
static struct {
	float wb[3];		/* R, G, B */
	float gain;
	uint8_t gamma[1024];	/* in: 0..1023 linear (8-bit sample x 4 after gains), out: sRGB-ish 8-bit */
} isp = { { 1.8f, 1.0f, 1.6f }, 2.0f };

static void
ispInit(void)
{
	for (int i = 0; i < 1024; i++)
		isp.gamma[i] = (uint8_t)lrint(255.0 * pow(i / 1023.0, 1 / 2.2));
}

static inline uint8_t
raw8(const uint8_t *row, uint32_t x)
{
	return row[(x >> 2) * 5 + (x & 3)];	/* the high 8 bits; the fifth byte of a group has the low bits */
}

/* the 2x2 cell (cx, cy) as R, G, B (8-bit, black subtracted, not clipped) */
static inline void
cell(const struct blueline_camera_frame *f, const uint8_t *raw, uint32_t cx, uint32_t cy, int black8, int rgb[3])
{
	const uint8_t *r0 = raw + (size_t)(2 * cy) * f->stride, *r1 = r0 + f->stride;
	int a = raw8(r0, 2 * cx) - black8, b = raw8(r0, 2 * cx + 1) - black8, c = raw8(r1, 2 * cx) - black8, d = raw8(r1, 2 * cx + 1) - black8;
	switch (f->bayer) {
	case 1: rgb[0] = b, rgb[1] = (a + d) / 2, rgb[2] = c; break;	/* GRBG */
	case 2: rgb[0] = c, rgb[1] = (a + d) / 2, rgb[2] = b; break;	/* GBRG */
	case 3: rgb[0] = d, rgb[1] = (b + c) / 2, rgb[2] = a; break;	/* BGGR */
	default: rgb[0] = a, rgb[1] = (b + c) / 2, rgb[2] = d; break;	/* RGGB */
	}
}

/* white balance and gain for the next frame, from a 64x48 grid of cells */
static void
ispStats(const struct blueline_camera_frame *f, const uint8_t *raw)
{
	double sum[3] = { 0 };
	int black8 = (int)f->black / 4, rgb[3];
	uint32_t cw = f->width / 2, ch = f->height / 2;
	for (uint32_t j = 0; j < 48; j++)
		for (uint32_t i = 0; i < 64; i++) {
			cell(f, raw, i * cw / 64, j * ch / 48, black8, rgb);
			for (int k = 0; k < 3; k++)
				sum[k] += rgb[k] > 0 ? rgb[k] : 0;
		}
	if (sum[0] < 1 || sum[1] < 1 || sum[2] < 1)
		return;
	float wr = fminf(4, fmaxf(0.5f, (float)(sum[1] / sum[0]))), wb = fminf(4, fmaxf(0.5f, (float)(sum[1] / sum[2])));
	isp.wb[0] += 0.25f * (wr - isp.wb[0]);
	isp.wb[2] += 0.25f * (wb - isp.wb[2]);
	double g = sum[1] / (64 * 48);	/* green mean, 8-bit linear */
	float want = (float)(46.0 / fmax(g, 0.5));	/* ~18 % grey */
	want = fminf(32, fmaxf(0.5f, want));
	isp.gain += 0.3f * (want - isp.gain);
}

static void
fillRaw(CVPixelBufferRef pb, const struct blueline_camera_frame *f, const uint8_t *raw)
{
	size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
	OSType pf = CVPixelBufferGetPixelFormatType(pb);
	uint32_t cw = f->width / 2, ch = f->height / 2;
	int black8 = (int)f->black / 4, rgb[3];
	uint8_t lut[3][272];	/* cell value + 16 (black-subtracted 8-bit, -16..255) -> output, gains and gamma folded in */
	for (int k = 0; k < 3; k++) {
		float m = isp.wb[k] * isp.gain * 4;
		for (int v = 0; v < 272; v++) {
			int o = (int)((v - 16) * m);
			lut[k][v] = isp.gamma[o < 0 ? 0 : o > 1023 ? 1023 : o];
		}
	}
	uint32_t *xs = malloc(w * sizeof *xs);
	if (xs == NULL)
		return;
	for (size_t x = 0; x < w; x++)
		xs[x] = (uint32_t)(x * cw / w);
	CVPixelBufferLockBaseAddress(pb, 0);
	BOOL bgra = pf == kCVPixelFormatType_32BGRA, nv = CVPixelBufferGetPlaneCount(pb) == 2;
	BOOL full = pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
	uint8_t *base = bgra ? CVPixelBufferGetBaseAddress(pb) : nv ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : NULL;
	uint8_t *cp = nv ? CVPixelBufferGetBaseAddressOfPlane(pb, 1) : NULL;
	size_t bpr = bgra ? CVPixelBufferGetBytesPerRow(pb) : nv ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : 0;
	size_t cs = nv ? CVPixelBufferGetBytesPerRowOfPlane(pb, 1) : 0;
	for (size_t y = 0; base && y < h; y++) {
		uint32_t cy = (uint32_t)(y * ch / h);
		uint8_t *row = base + y * bpr;
		for (size_t x = 0; x < w; x++) {
			cell(f, raw, xs[x], cy, black8, rgb);
			uint8_t o[3];
			for (int k = 0; k < 3; k++)
				o[k] = lut[k][rgb[k] < -16 ? 0 : rgb[k] + 16];
			if (bgra) {
				row[4 * x] = o[2], row[4 * x + 1] = o[1], row[4 * x + 2] = o[0], row[4 * x + 3] = 255;
				continue;
			}
			int Y = (77 * o[0] + 150 * o[1] + 29 * o[2]) >> 8;	/* BT.601 full range */
			row[x] = full ? (uint8_t)Y : (uint8_t)(16 + (Y * 219 >> 8));
			if ((y & 1) == 0 && (x & 1) == 0) {
				int cb = ((-43 * o[0] - 85 * o[1] + 128 * o[2]) >> 8), cr = ((128 * o[0] - 107 * o[1] - 21 * o[2]) >> 8);
				if (!full)
					cb = cb * 224 >> 8, cr = cr * 224 >> 8;
				cp[(y / 2) * cs + x] = (uint8_t)(cb + 128);
				cp[(y / 2) * cs + x + 1] = (uint8_t)(cr + 128);
			}
		}
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
	free(xs);
}

static void *
frameThread(void *arg)
{
	unsigned gen = (unsigned)(uintptr_t)arg, n = 0;
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	uint64_t t0 = mach_absolute_time();
	/* the kernel's frames, or synthetic ones where there is no device or /private/var/tmp/bluecam_synthetic says 1 */
	char flag = 0;	/* "1" in the file: synthetic (the file stays on the phone across test boots: "0" undoes it) */
	int ff = open("/private/var/tmp/bluecam_synthetic", O_RDONLY);
	if (ff >= 0) {
		(void)read(ff, &flag, 1);
		close(ff);
	}
	int fd = flag == '1' ? -1 : open(BLUELINE_CAMERA_DEVICE, O_RDONLY);
	int openErr = fd < 0 ? errno : 0;
	size_t cap = 0;
	uint8_t *buf = NULL;
	struct blueline_camera_frame *f = NULL;
	unsigned readErrs = 0;
	if (fd >= 0) {
		ispInit();
		cap = sizeof(struct blueline_camera_frame) + 4096 * 3072 * 5 / 4;
		buf = malloc(cap);
		f = (struct blueline_camera_frame *)buf;
	}
	say("frames begin (format %d, %.0f fps, %s)", st.formatIndex, st.maxFps,
	    fd >= 0 ? "kernel" : openErr ? strerror(openErr) : "synthetic");
	for (;;) {
		@autoreleasepool {
			const uint8_t *raw = NULL;
			if (fd >= 0 && buf != NULL) {
				ssize_t got = read(fd, buf, cap);	/* waits for the next frame (at most 1 s) */
				if (got < (ssize_t)sizeof(*f) || memcmp(f->magic, BLUELINE_CAMERA_MAGIC, 8) != 0 ||
				    got < (ssize_t)(f->header_bytes + (size_t)f->stride * f->height)) {
					if (readErrs++ % 30 == 0)
						say("frame read: %zd (%s)", got, got < 0 ? strerror(errno) : "short");
					if (got < 0 && errno == EIO)
						break;
					pthread_mutex_lock(&st.lock);
					BOOL go = st.running && st.generation == gen;
					pthread_mutex_unlock(&st.lock);
					if (!go)
						break;
					continue;
				}
				raw = buf + f->header_bytes;
				if (n == 0)
					say("first kernel frame: %ux%u stride %u bayer %u black %u, exposure %u lines x %u ns, gain %u/%u",
					    f->width, f->height, f->stride, f->bayer, f->black, f->exposure_lines, f->line_ns, f->gain, f->gain_unity);
			}
			pthread_mutex_lock(&st.lock);
			if (!st.running || st.generation != gen) {
				pthread_mutex_unlock(&st.lock);
				break;
			}
			double fps = st.maxFps > 0 ? fmin(st.maxFps, 30) : 30;
			uint64_t now = raw ? f->time : mach_absolute_time();
			if (raw && f->frame_lines && f->line_ns)
				fps = 1e9 / ((double)f->frame_lines * f->line_ns);
			NSDictionary *md = frameMetadata(now, fps);
			st.metadata = md;
			CFStringRef attach = key("kFigCaptureSampleBufferAttachmentKey_MetadataDictionary");
			/* buffers and handlers under the lock; the picture and the handler calls without it (a handler may call back
			 * into the stream, and Stop must not wait for a conversion) */
			CVPixelBufferRef pbs[OUTPUTS - 1] = { NULL };
			PixelBufferHandler hs[OUTPUTS - 1] = { nil };
			for (int i = 0; i < OUTPUTS - 1; i++) {	/* the moving-picture outputs; StillImage only on a still request */
				if (!st.enabled[i] || st.handler[i] == nil)
					continue;
				if ((pbs[i] = outputBuffer(i)) != NULL)
					hs[i] = st.handler[i];
			}
			pthread_mutex_unlock(&st.lock);
			for (int i = 0; i < OUTPUTS - 1; i++) {
				CVPixelBufferRef pb = pbs[i];
				if (pb == NULL)
					continue;
				if (raw)
					fillRaw(pb, f, raw);
				else
					fillSynthetic(pb, n, fps);
				CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
				CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
				CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
				if (md && attach)	/* mutable: FigImageControl adds its own keys to it */
					CVBufferSetAttachment(pb, attach, (__bridge CFTypeRef)[md mutableCopy], kCVAttachmentMode_ShouldPropagate);
				hs[i](pb, CMClockMakeHostTimeFromSystemUnits(now));
				pthread_mutex_lock(&st.lock);
				if (st.generation != gen) {	/* stopped meanwhile: its held buffers are gone already */
					pthread_mutex_unlock(&st.lock);
					CVPixelBufferRelease(pb);
					continue;
				}
				if (st.held[i][st.heldNext[i]] != NULL)
					CVPixelBufferRelease(st.held[i][st.heldNext[i]]);
				st.held[i][st.heldNext[i]] = pb;
				st.heldNext[i] = (st.heldNext[i] + 1) % HELD;
				if (st.delivered[i]++ == 0) {
					OSType pf = CVPixelBufferGetPixelFormatType(pb);
					say("%s: first picture given (%zux%zu %.4s)", outputNames[i].UTF8String, CVPixelBufferGetWidth(pb),
					    CVPixelBufferGetHeight(pb), (char *)&(OSType){ CFSwapInt32HostToBig(pf) });
				}
				pthread_mutex_unlock(&st.lock);
			}
			if (raw)
				ispStats(f, raw);
			n++;
			if (n % 150 == 0)
				say("frames: %u, given %llu / %llu%s", n, (unsigned long long)st.delivered[0], (unsigned long long)st.delivered[1],
				    raw ? [NSString stringWithFormat:@", seq %llu, wb %.2f %.2f, gain %.1f", f->sequence, isp.wb[0], isp.wb[2], isp.gain].UTF8String : "");
			if (!raw) {
				uint64_t next = t0 + (uint64_t)(n / fps * 1e9 * tb.denom / tb.numer);
				if (next > mach_absolute_time())
					mach_wait_until(next);
			}
		}
	}
	if (fd >= 0)
		close(fd);	/* the last close powers the camera down */
	free(buf);
	say("frames end (%u)", n);
	return NULL;
}

static void
streamFinalize(CMBaseObjectRef o)
{
	say("stream finalize");
}

static int
outputIndex(id name)
{
	for (int i = 0; i < OUTPUTS; i++)
		if ([outputNames[i] isEqual:name])
			return i;
	return -1;
}

static OSStatus
streamCopyProperty(CMBaseObjectRef o, CFStringRef key_, CFAllocatorRef a, void *out)
{
	char k[128];
	str(key_, k, sizeof k);
	id value = nil;
	if (strcmp(k, "SupportedPropertiesDictionary") == 0)
		value = props(streamProps, sizeof streamProps / sizeof streamProps[0]);
	else if (strcmp(k, "SupportedFormatsArray") == 0)
		value = backFormats();
	else if (strcmp(k, "PortType") == 0) {
		CFStringRef *back = dlsym(RTLD_DEFAULT, "kFigCapturePortType_BackFacingCamera");
		value = back && *back ? (__bridge NSString *)*back : nil;
	} else if (strcmp(k, "UniqueID") == 0)
		value = @"com.apple.avfoundation.avcapturedevice.built-in_video:0";
	else if (strcmp(k, "NonLocalizedName") == 0)
		value = @"Back Camera";
	else if (strcmp(k, "Clock") == 0)
		value = (__bridge id)CMClockGetHostTimeClock();
	else if (strcmp(k, "FocalLength") == 0)
		value = @4.38;		/* IMX363 module, mm */
	else if (strcmp(k, "LensFNumber") == 0)
		value = @1.8;
	else if (strcmp(k, "PixelSize") == 0)
		value = @1.4;
	else if (strcmp(k, "MaxZoomFactor") == 0)
		value = @16.0;
	else if (strcmp(k, "HasAutoFocusPositionSensor") == 0)
		value = @NO;
	else if (strcmp(k, "SupportedColorSpaces") == 0)
		value = @[ @0 ];	/* sRGB */
	else {
		pthread_mutex_lock(&st.lock);
		if (strcmp(k, "FormatIndex") == 0)
			value = @(st.formatIndex);
		else if (strcmp(k, "MinimumFrameRate") == 0)
			value = @(st.minFps);
		else if (strcmp(k, "MaximumFrameRate") == 0)
			value = @(st.maxFps);
		else if (strcmp(k, "VideoOutputsColorInfo") == 0)
			value = st.colourInfo ?: @{};
		else if (strcmp(k, "VideoOutputConfigurations") == 0 || strcmp(k, "VideoOutputsEnabled") == 0) {
			/* read back while the graph is built; a failed read tears it down (redfin) */
			NSMutableDictionary *d = [NSMutableDictionary dictionary];
			for (int i = 0; i < OUTPUTS; i++)
				if (k[11] == 'C') {
					if (st.config[i])
						d[outputNames[i]] = st.config[i];
				} else
					d[outputNames[i]] = @(st.enabled[i]);
			value = d;
		}
		pthread_mutex_unlock(&st.lock);
	}
	if (value == nil) {
		say("stream copy %s -> not available", k);
		return kValueNotAvailable;
	}
	*(CFTypeRef *)out = CFBridgingRetain(value);
	if (strcmp(k, "SupportedFormatsArray") == 0 || strcmp(k, "SupportedPropertiesDictionary") == 0 || strcmp(k, "PortType") == 0)
		say("stream copy %s", k);
	return 0;
}

static OSStatus
streamSetProperty(CMBaseObjectRef o, CFStringRef key_, CFTypeRef v)
{
	char k[128], d[256];
	str(key_, k, sizeof k);
	id value = (__bridge id)v;
	BOOL handled = YES;
	pthread_mutex_lock(&st.lock);
	if (strcmp(k, "FormatIndex") == 0 && [value isKindOfClass:[NSNumber class]])
		st.formatIndex = [value intValue];
	else if (strcmp(k, "MinimumFrameRate") == 0 && [value isKindOfClass:[NSNumber class]])
		st.minFps = [value doubleValue];
	else if (strcmp(k, "MaximumFrameRate") == 0 && [value isKindOfClass:[NSNumber class]])
		st.maxFps = [value doubleValue];
	else if (strcmp(k, "VideoOutputsColorInfo") == 0)
		st.colourInfo = [value isKindOfClass:[NSDictionary class]] ? value : nil;
	else if ((strcmp(k, "VideoOutputConfigurations") == 0 || strcmp(k, "VideoOutputsEnabled") == 0 ||
		     strcmp(k, "VideoOutputHandlers") == 0) && [value isKindOfClass:[NSDictionary class]]) {
		for (id name in value) {
			int i = outputIndex(name);
			id one = value[name];
			if (i < 0) {
				say("stream set %s: output %s not here", k, [[name description] UTF8String]);
				continue;
			}
			if (k[11] == 'C') {
				letGo(i);
				st.config[i] = [one isKindOfClass:[NSDictionary class]] ? one : nil;
			} else if (k[11] == 's')
				st.enabled[i] = [one respondsToSelector:@selector(boolValue)] ? [one boolValue] : YES;
			else
				st.handler[i] = [one isKindOfClass:[NSDictionary class]] ? one[@"PixelBufferHandler"] : nil;
		}
	} else
		handled = NO;
	pthread_mutex_unlock(&st.lock);
	if (strcmp(k, "VideoOutputHandlers") == 0)
		say("stream set %s: %lu outputs", k, (unsigned long)[value count]);
	else
		say("stream set %s%s = %s", k, handled ? "" : " (not used)", desc(v, d, sizeof d));
	return 0;
}

static OSStatus
streamStart(CMBaseObjectRef o)
{
	pthread_mutex_lock(&st.lock);
	BOOL was = st.running;
	st.running = YES;
	unsigned gen = ++st.generation;
	for (int i = 0; i < OUTPUTS; i++)
		st.delivered[i] = st.refused[i] = 0;
	pthread_mutex_unlock(&st.lock);
	say("stream start (enabled %d %d %d, handlers %d %d %d, pools %d %d %d)%s", st.enabled[0], st.enabled[1], st.enabled[2],
	    st.handler[0] != nil, st.handler[1] != nil, st.handler[2] != nil, st.config[0][@"BufferPool"] != nil,
	    st.config[1][@"BufferPool"] != nil, st.config[2][@"BufferPool"] != nil, was ? " (was running)" : "");
	pthread_t t;
	pthread_attr_t at;
	pthread_attr_init(&at);
	pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
	int e = pthread_create(&t, &at, frameThread, (void *)(uintptr_t)gen);
	pthread_attr_destroy(&at);
	if (e != 0) {
		st.running = NO;
		return kUnsupported;
	}
	return 0;
}

static OSStatus
streamStop(CMBaseObjectRef o)
{
	pthread_mutex_lock(&st.lock);
	say("stream stop (given %llu / %llu)", (unsigned long long)st.delivered[0], (unsigned long long)st.delivered[1]);
	st.running = NO;
	st.generation++;
	for (int i = 0; i < OUTPUTS; i++)
		letGo(i);
	pthread_mutex_unlock(&st.lock);
	return 0;
}

static OSStatus
streamAddAttachments(CMBaseObjectRef o, void *sbuf, CFDictionaryRef d)
{
	CFStringRef attach = key("kFigCaptureSampleBufferAttachmentKey_MetadataDictionary");
	if (sbuf == NULL || attach == NULL)
		return 0;
	CMSampleBufferRef sb = sbuf;
	if (CMGetAttachment(sb, attach, NULL) != NULL)
		return 0;
	CVImageBufferRef img = CMSampleBufferGetImageBuffer(sb);
	NSDictionary *ours = img ? CFBridgingRelease(CVBufferCopyAttachment(img, attach, NULL)) : nil;
	pthread_mutex_lock(&st.lock);
	NSMutableDictionary *m = [ours isKindOfClass:[NSDictionary class]] ? [ours mutableCopy] : [st.metadata mutableCopy];
	pthread_mutex_unlock(&st.lock);
	if (m)
		CMSetAttachment(sb, attach, (__bridge CFTypeRef)m, kCMAttachmentMode_ShouldPropagate);
	return 0;
}

static const CMBaseClass streamBase = {
	.version = 1,
	.derivedStorageSize = 0xc08,
	.finalize = streamFinalize,
	.copyProperty = streamCopyProperty,
	.setProperty = streamSetProperty,
};

static const StreamClass streamClass = {
	.version = 2,
	.start = streamStart,
	.stop = streamStop,
	.addAttachmentsToSampleBuffer = streamAddAttachments,
};

static const CMBaseVTable streamVTable = { NULL, &streamBase, &streamClass };

/* --- device --- */

static OSStatus
devInvalidate(CMBaseObjectRef o)
{
	say("dev invalidate");
	return 0;
}

static void
devFinalize(CMBaseObjectRef o)
{
	say("dev finalize");
}

static OSStatus
devCopyProperty(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef a, void *out)
{
	char k[128];
	str(key, k, sizeof k);
	if (strcmp(k, "StreamArray") == 0 && backStream != NULL) {
		const void *one[] = { backStream };
		*(CFArrayRef *)out = CFArrayCreate(a, one, 1, &kCFTypeArrayCallBacks);
		say("dev copy %s -> 1 stream", k);
		return 0;
	}
	if (strstr(k, "StreamArray") || strcmp(k, "SupportedSynchronizedStreamsGroups") == 0) {
		/* no streams (or groups) yet: an empty array rather than an error */
		*(CFArrayRef *)out = CFArrayCreate(a, NULL, 0, &kCFTypeArrayCallBacks);
		say("dev copy %s -> empty array", k);
		return 0;
	}
	if (strcmp(k, "SupportedPropertiesDictionary") == 0) {
		*(CFDictionaryRef *)out = CFBridgingRetain(props(deviceProps, sizeof deviceProps / sizeof deviceProps[0]));
		say("dev copy %s", k);
		return 0;
	}
	if (strcmp(k, "Clock") == 0) {
		*(CFTypeRef *)out = CFRetain(CMClockGetHostTimeClock());
		say("dev copy %s -> host time clock", k);
		return 0;
	}
	say("dev copy %s -> not available", k);
	return kValueNotAvailable;
}

static OSStatus
devSetProperty(CMBaseObjectRef o, CFStringRef key, CFTypeRef v)
{
	char k[128], d[256];
	say("dev set %s = %s", str(key, k, sizeof k), desc(v, d, sizeof d));
	return 0;
}

static OSStatus
devCreateProcessingSession(CMBaseObjectRef o, CFAllocatorRef a, CFDictionaryRef opts, const void **out)
{
	char d[256];
	say("dev createProcessingSession %s", desc(opts, d, sizeof d));
	return kUnsupported;
}

static OSStatus
devRequestStreams(CMBaseObjectRef o, CFArrayRef streams, CFDictionaryRef opts)
{
	char d[256];
	say("dev requestStreams %ld, %s", streams ? (long)CFArrayGetCount(streams) : -1L, desc(opts, d, sizeof d));
	return 0;
}

static OSStatus
devRelinquishStreams(CMBaseObjectRef o, CFArrayRef streams, CFDictionaryRef opts)
{
	say("dev relinquishStreams %ld", streams ? (long)CFArrayGetCount(streams) : -1L);
	return 0;
}

static OSStatus
devPerformPearlCalibration(CMBaseObjectRef o, void *buf, CFDictionaryRef opts)
{
	return kUnsupported;
}

static const CMBaseClass devBase = {
	.version = 1,
	.derivedStorageSize = 256,
	.invalidate = devInvalidate,
	.finalize = devFinalize,
	.copyProperty = devCopyProperty,
	.setProperty = devSetProperty,
};

static const DeviceClass devClass = {
	.version = 3,
	.createProcessingSession = devCreateProcessingSession,
	.requestStreams = devRequestStreams,
	.relinquishStreams = devRelinquishStreams,
	.performPearlCalibration = devPerformPearlCalibration,
};

static const CMBaseVTable devVTable = { NULL, &devBase, &devClass };

__attribute__((visibility("default"))) OSStatus
H13ISPCaptureDeviceCreate(CFAllocatorRef a, void *arg1, CMBaseObjectRef *out)
{
	say("H13ISPCaptureDeviceCreate(%p, %p, %p)", a, arg1, out);
	if (pCMDerivedObjectCreate == NULL)
		pCMDerivedObjectCreate = dlsym(RTLD_DEFAULT, "CMDerivedObjectCreate");
	if (pFigCaptureDeviceGetClassID == NULL)
		pFigCaptureDeviceGetClassID = dlsym(RTLD_DEFAULT, "FigCaptureDeviceGetClassID");
	if (pCMDerivedObjectCreate == NULL || pFigCaptureDeviceGetClassID == NULL || out == NULL) {
		say("missing CMDerivedObjectCreate %p / FigCaptureDeviceGetClassID %p", pCMDerivedObjectCreate,
		    pFigCaptureDeviceGetClassID);
		return kUnsupported;
	}
	OSStatus st = pCMDerivedObjectCreate(a, &devVTable, pFigCaptureDeviceGetClassID(), out);
	say("device %p, status %d", *out, (int)st);
	if (pFigCaptureStreamGetClassID == NULL)
		pFigCaptureStreamGetClassID = dlsym(RTLD_DEFAULT, "FigCaptureStreamGetClassID");
	if (st == 0 && backStream == NULL && pFigCaptureStreamGetClassID != NULL) {
		OSStatus ss = pCMDerivedObjectCreate(a, &streamVTable, pFigCaptureStreamGetClassID(), &backStream);
		say("stream %p, status %d", backStream, (int)ss);
	}
	return st;
}

/* mediaserverd's crash-loop causes so far were exceptions in dispatch blocks: log them (the kernel sees only SIGABRT) */
static NSUncaughtExceptionHandler *previousHandler;

static void
uncaught(NSException *e)
{
	say("uncaught %s: %s", e.name.UTF8String, e.reason.UTF8String ?: "(no reason)");
	NSArray<NSNumber *> *pcs = e.callStackReturnAddresses;
	char line[400] = "";
	size_t n = 0;
	for (NSUInteger i = 0; i < pcs.count && i < 24 && n < sizeof line - 20; i++)
		n += snprintf(line + n, sizeof line - n, " 0x%llx", pcs[i].unsignedLongLongValue);
	say("uncaught bt%s", line);
	for (NSUInteger i = 0; i < pcs.count && i < 16; i++) {	/* the frames outside the shared cache, by image */
		Dl_info info;
		const void *pc = (const void *)pcs[i].unsignedLongLongValue;
		if (dladdr(pc, &info) && info.dli_fname && !_dyld_shared_cache_contains_path(info.dli_fname))
			say("uncaught #%lu %s+0x%lx (%s)", (unsigned long)i, strrchr(info.dli_fname, '/') + 1,
			    (unsigned long)((uintptr_t)pc - (uintptr_t)info.dli_fbase), info.dli_sname ?: "?");
	}
	if (previousHandler)
		previousHandler(e);
}

__attribute__((constructor)) static void
loaded(void)
{
	char exe[256] = "?";
	uint32_t n = sizeof exe;
	_NSGetExecutablePath(exe, &n);
	say("loaded into %s", exe);
	previousHandler = NSGetUncaughtExceptionHandler();
	NSSetUncaughtExceptionHandler(uncaught);
}
