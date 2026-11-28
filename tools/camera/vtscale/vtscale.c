/*
 * vtscale: which VideoToolbox pixel operations work on this phone, which has no AppleM2ScalerCSCDriver (the
 * iPhone's hardware scaler)? Camera's thumbnail fails with kVTImageRotationNotSupportedErr (-12914) on a rotation.
 *
 *   vtscale
 *
 * For a 4032x3024 source (420f and BGRA, IOSurface-backed, a gradient): VTPixelTransferSession to the same size, to
 * 480x360, and 420f to BGRA; VTPixelRotationSession by 90 and 180 degrees, and by 180 into 480x360 (rotate and scale). Each line: the status, the time and the
 * mean of the output's first plane (0 for a buffer left empty). Exit 0 if every call returned 0.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>

static CVPixelBufferRef
make(int w, int h, OSType f)
{
	CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	const void *k[] = { kCVPixelBufferIOSurfacePropertiesKey };
	const void *v[] = { empty };
	CFDictionaryRef a = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CVPixelBufferRef pb = NULL;
	CVReturn r = CVPixelBufferCreate(NULL, w, h, f, a, &pb);
	CFRelease(a);
	CFRelease(empty);
	if (r != kCVReturnSuccess) {
		printf("make %dx%d '%.4s': %d\n", w, h, (char *)&(OSType){ CFSwapInt32HostToBig(f) }, r);
		return NULL;
	}
	return pb;
}

static void
fill(CVPixelBufferRef pb)
{
	CVPixelBufferLockBaseAddress(pb, 0);
	size_t n = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetPlaneCount(pb) : 1;
	for (size_t p = 0; p < n; p++) {
		uint8_t *b = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBaseAddressOfPlane(pb, p) : CVPixelBufferGetBaseAddress(pb);
		size_t rb = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb);
		size_t h = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb);
		for (size_t y = 0; y < h; y++) {
			for (size_t x = 0; x < rb; x++) {
				b[y * rb + x] = p ? 128 : (uint8_t)(16 + (x + y) % 200);
			}
		}
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
}

static double
mean(CVPixelBufferRef pb)
{
	CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	uint8_t *b = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb);
	size_t rb = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb);
	size_t h = CVPixelBufferIsPlanar(pb) ? CVPixelBufferGetHeightOfPlane(pb, 0) : CVPixelBufferGetHeight(pb);
	uint64_t s = 0;
	for (size_t y = 0; y < h; y++) {
		for (size_t x = 0; x < rb; x++) {
			s += b[y * rb + x];
		}
	}
	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	return (double)s / (double)(rb * h);
}

static double
ms_since(uint64_t t0)
{
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
}

static int bad;

static void
transfer(const char *what, CVPixelBufferRef src, int w, int h, OSType f)
{
	CVPixelBufferRef dst = make(w, h, f);
	VTPixelTransferSessionRef s = NULL;
	OSStatus st = VTPixelTransferSessionCreate(NULL, &s);
	uint64_t t0 = mach_absolute_time();
	if (st == 0 && dst) {
		st = VTPixelTransferSessionTransferImage(s, src, dst);
	}
	printf("transfer %-28s %6d  %7.1f ms  mean %.1f\n", what, (int)st, ms_since(t0), dst && st == 0 ? mean(dst) : 0.0);
	bad |= st != 0 || !dst;
	if (s) {
		VTPixelTransferSessionInvalidate(s);
		CFRelease(s);
	}
	if (dst) {
		CVPixelBufferRelease(dst);
	}
}

static void
rotate(const char *what, CVPixelBufferRef src, int deg, OSType f, int dw, int dh)
{
	int w = (int)CVPixelBufferGetWidth(src), h = (int)CVPixelBufferGetHeight(src);
	CVPixelBufferRef dst = dw ? make(dw, dh, f) : deg % 180 ? make(h, w, f) : make(w, h, f);
	VTPixelRotationSessionRef s = NULL;
	OSStatus st = VTPixelRotationSessionCreate(NULL, &s);
	if (st == 0) {
		CFStringRef ang = deg == 90 ? kVTRotation_CW90 : deg == 180 ? kVTRotation_180 : kVTRotation_0;
		st = VTSessionSetProperty(s, kVTPixelRotationPropertyKey_Rotation, ang);
	}
	uint64_t t0 = mach_absolute_time();
	if (st == 0 && dst) {
		st = VTPixelRotationSessionRotateImage(s, src, dst);
	}
	printf("rotate   %-28s %6d  %7.1f ms  mean %.1f\n", what, (int)st, ms_since(t0), dst && st == 0 ? mean(dst) : 0.0);
	bad |= st != 0 || !dst;
	if (s) {
		VTPixelRotationSessionInvalidate(s);
		CFRelease(s);
	}
	if (dst) {
		CVPixelBufferRelease(dst);
	}
}

int
main(void)
{
	const OSType yuv = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, bgra = kCVPixelFormatType_32BGRA;
	CVPixelBufferRef sy = make(4032, 3024, yuv), sb = make(4032, 3024, bgra);
	if (!sy || !sb) {
		return 1;
	}
	fill(sy);
	fill(sb);
	printf("source means: 420f %.1f, BGRA %.1f\n", mean(sy), mean(sb));
	transfer("420f same size", sy, 4032, 3024, yuv);
	transfer("420f -> 480x360 420f", sy, 480, 360, yuv);
	transfer("420f -> 4032x3024 BGRA", sy, 4032, 3024, bgra);
	transfer("420f -> 480x360 BGRA", sy, 480, 360, bgra);
	transfer("BGRA -> 480x360 BGRA", sb, 480, 360, bgra);
	rotate("420f 180", sy, 180, yuv, 0, 0);
	rotate("420f 90", sy, 90, yuv, 0, 0);
	rotate("BGRA 180", sb, 180, bgra, 0, 0);
	rotate("BGRA 90", sb, 90, bgra, 0, 0);
	/* Camera's thumbnail: rotated and scaled at once (CAMThumbnailGenerator, {480, 360} in orientation 3) */
	rotate("420f 180 -> 480x360", sy, 180, yuv, 480, 360);
	rotate("420f 180 -> 480x360 BGRA", sy, 180, bgra, 480, 360);
	rotate("BGRA 180 -> 480x360", sb, 180, bgra, 480, 360);
	rotate("420f 0 -> 480x360", sy, 0, yuv, 480, 360);
	return bad;
}
