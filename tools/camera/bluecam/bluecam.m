/*
 * bluecam - a CMCapture capture-device plug-in for the Pixel 3 cameras.
 *
 * CMCapture (mediaserverd) loads the first plug-in whose IOKit class exists:
 * FigCaptureGetCaptureDeviceCreateFunction() walks {AppleH13CamIn, /System/Library/MediaCapture/H13ISP.mediacapture,
 * H13ISPCaptureDeviceCreate}, then H10, H9, H6. Kernel patch 0232 publishes an AppleH13CamIn stub, and this
 * library is installed at that path, so every capture client (AVFoundation apps, Camera.app) goes through it.
 *
 * Stage 2 (this file): a device with one back-camera stream that answers its port type and the stream formats
 * named in CMCapture's AVCaptureSession.plist; AVFoundation lists "Back Camera". Start is still refused (no frames).
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

static void
streamFinalize(CMBaseObjectRef o)
{
	say("stream finalize");
}

static OSStatus
streamCopyProperty(CMBaseObjectRef o, CFStringRef key, CFAllocatorRef a, void *out)
{
	char k[128];
	str(key, k, sizeof k);
	if (strcmp(k, "SupportedPropertiesDictionary") == 0) {
		*(CFDictionaryRef *)out = (__bridge_retained CFDictionaryRef)[BCAnyKey new];
		say("stream copy %s -> any key", k);
		return 0;
	}
	if (strcmp(k, "SupportedFormatsArray") == 0) {
		*(CFArrayRef *)out = (__bridge_retained CFArrayRef)backFormats();
		say("stream copy %s -> %lu formats", k, (unsigned long)backFormats().count);
		return 0;
	}
	if (strcmp(k, "PortType") == 0) {
		CFStringRef *back = dlsym(RTLD_DEFAULT, "kFigCapturePortType_BackFacingCamera");
		if (back && *back) {
			*(CFStringRef *)out = CFRetain(*back);
			say("stream copy %s -> %s", k, str(*back, (char[64]){0}, 64));
			return 0;
		}
	}
	say("stream copy %s -> not available", k);
	return kValueNotAvailable;
}

static OSStatus
streamSetProperty(CMBaseObjectRef o, CFStringRef key, CFTypeRef v)
{
	char k[128], d[256];
	say("stream set %s = %s", str(key, k, sizeof k), desc(v, d, sizeof d));
	return 0;
}

static OSStatus
streamStart(CMBaseObjectRef o)
{
	say("stream start");
	return kUnsupported;
}

static OSStatus
streamStop(CMBaseObjectRef o)
{
	say("stream stop");
	return 0;
}

static OSStatus
streamAddAttachments(CMBaseObjectRef o, void *sbuf, CFDictionaryRef d)
{
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
		*(CFDictionaryRef *)out = (__bridge_retained CFDictionaryRef)[BCAnyKey new];
		say("dev copy %s -> any key", k);
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
