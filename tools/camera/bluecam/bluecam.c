/*
 * bluecam - a CMCapture capture-device plug-in for the Pixel 3 cameras.
 *
 * CMCapture (mediaserverd) loads the first plug-in whose IOKit class exists:
 * FigCaptureGetCaptureDeviceCreateFunction() walks {AppleH13CamIn, /System/Library/MediaCapture/H13ISP.mediacapture,
 * H13ISPCaptureDeviceCreate}, then H10, H9, H6. Kernel patch 0232 publishes an AppleH13CamIn stub, and this
 * library is installed at that path, so every capture client (AVFoundation apps, Camera.app) goes through it.
 *
 * Stage 1 (this file): the device and stream objects exist and answer nothing; every CopyProperty / SetProperty
 * key and every class call is printed on the console (kern.bluesay, kernel patch 0231), so the property set
 * CMCapture needs can be filled in from what it asks for.
 *
 * Interface (read from H10ISP.mediacapture, iOS 16.7): CMDerivedObjectCreate objects, WebKit's CMBaseClass layout.
 *   OSStatus H13ISPCaptureDeviceCreate(CFAllocatorRef, void *unknown, FigCaptureDeviceRef *out)
 *   device base: storage 256; Invalidate, Finalize, CopyProperty, SetProperty
 *   device class v3: CreateProcessingSession, RequestStreams, RelinquishStreams, PerformPearlCalibration
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
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

enum { kValueNotAvailable = -12783, kUnsupported = -12782 };	/* kCMBaseObjectError_* */

static OSStatus (*pCMDerivedObjectCreate)(CFAllocatorRef, const CMBaseVTable *, CMBaseClassID, CMBaseObjectRef *);
static CMBaseClassID (*pFigCaptureDeviceGetClassID)(void);

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
	if (strstr(k, "StreamArray")) {	/* no streams yet: an empty array rather than an error */
		*(CFArrayRef *)out = CFArrayCreate(a, NULL, 0, &kCFTypeArrayCallBacks);
		say("dev copy %s -> empty array", k);
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
	return st;
}

__attribute__((constructor)) static void
loaded(void)
{
	char exe[256] = "?";
	uint32_t n = sizeof exe;
	extern int _NSGetExecutablePath(char *, uint32_t *);
	_NSGetExecutablePath(exe, &n);
	say("loaded into %s", exe);
}
