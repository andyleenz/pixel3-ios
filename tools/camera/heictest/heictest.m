/*
 * heictest FILE [--register] - decode a HEIC/JPEG with ImageIO the way the Photos thumbnailer does, and report.
 *
 * Prints the image source status, then times CGImageSourceCreateImageAtIndex (full decode),
 * CGImageSourceCreateThumbnailAtIndex from the full image (320 px) and from the embedded thumbnail only.
 * --register first registers VCPHEVC's software HEVC decoder with VideoToolbox for 'hvc1'.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

static double
ms(uint64_t a, uint64_t b)
{
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	return (double)(b - a) * tb.numer / tb.denom / 1e6;
}

static void
report(const char *what, CGImageRef img, uint64_t t0)
{
	uint64_t t1 = mach_absolute_time();
	if (img == NULL) {
		printf("%s: failed (%.1f ms)\n", what, ms(t0, t1));
		return;
	}
	printf("%s: %zux%zu, %zu bpc, %.1f ms\n", what, CGImageGetWidth(img), CGImageGetHeight(img),
	    CGImageGetBitsPerComponent(img), ms(t0, t1));
	CFDataRef d = CGDataProviderCopyData(CGImageGetDataProvider(img));
	if (d != NULL) {
		const uint8_t *p = CFDataGetBytePtr(d);
		size_t n = CFDataGetLength(d), mid = n / 2 & ~(size_t)3;
		printf("  pixel bytes %zu, middle %02x %02x %02x %02x\n", n, p[mid], p[mid + 1], p[mid + 2], p[mid + 3]);
		CFRelease(d);
	}
	CGImageRelease(img);
}

static void
registerDecoder(void)
{
	void *codec = dlopen("/System/Library/VideoCodecs/VCPHEVC.videocodec", RTLD_NOW | RTLD_LOCAL);
	void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW | RTLD_GLOBAL);
	void *create = codec ? dlsym(codec, "HEVCVideoDecoder_CreateInstance") : NULL;
	int (*reg)(uint32_t, void *) = vt ? dlsym(vt, "VTRegisterVideoDecoder") : NULL;
	printf("decoder create %p, VTRegisterVideoDecoder %p\n", create, reg);
	if (create != NULL && reg != NULL)
		printf("registered hvc1: %d\n", reg('hvc1', create));
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fprintf(stderr, "usage: heictest FILE [--register]\n");
			return 2;
		}
		if (argc > 2 && strcmp(argv[2], "--register") == 0)
			registerDecoder();
		NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
		CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
		if (src == NULL) {
			printf("no image source\n");
			return 1;
		}
		printf("type %s, count %zu, status %d\n", [(__bridge NSString *)CGImageSourceGetType(src) UTF8String],
		    CGImageSourceGetCount(src), (int)CGImageSourceGetStatus(src));
		uint64_t t0 = mach_absolute_time();
		report("full", CGImageSourceCreateImageAtIndex(src, 0, NULL), t0);
		NSDictionary *thumb = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
			(id)kCGImageSourceThumbnailMaxPixelSize: @320, (id)kCGImageSourceCreateThumbnailWithTransform: @YES };
		t0 = mach_absolute_time();
		report("thumbnail 320", CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)thumb), t0);
		NSDictionary *emb = @{ (id)kCGImageSourceCreateThumbnailFromImageIfAbsent: @NO };
		t0 = mach_absolute_time();
		report("embedded thumbnail", CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)emb), t0);
		CFRelease(src);
	}
	return 0;
}
