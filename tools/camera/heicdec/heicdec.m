/*
 * heicdec: can this phone decode a HEIC (as assetsd must, to make Photos' thumbnails)?
 *
 *   heicdec FILE [MAXPIXELS [OPTS]]
 *
 * OPTS letters change the thumbnail call: h kCGImageSourceUseHardwareAcceleratedDecode, a FromImageIfAbsent instead
 * of FromImageAlways (an embedded thumbnail first), z MaxPixelSize 0. "haz" is assetsd's import call (mem3 os_log:
 * "Failed to generate small thumbnail ... public.heic").
 *
 * Through ImageIO: the image's type and size, then a thumbnail (CGImageSourceCreateThumbnailAtIndex, MAXPIXELS
 * default 256, from the full image) and the full image, each with its time and the mean of its pixels (0 for
 * a picture that came out black). Then whether VideoToolbox has an HEVC decoder (VTIsHardwareDecodeSupported and
 * a decompression session for 'hvc1'). Exit 0 if the thumbnail decoded.
 */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <VideoToolbox/VideoToolbox.h>
#include <mach/mach_time.h>

static double
ms_since(uint64_t t0)
{
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6;
}

static double
mean_of(CGImageRef img)
{
	size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
	if (w > 512) {	/* sample a 512-wide copy */
		h = h * 512 / w;
		w = 512;
	}
	uint8_t *px = calloc(w * h, 4);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef c = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
	CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
	double sum = 0;
	for (size_t i = 0; i < w * h; i++)
		sum += (px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2]) / 3.0;
	CGContextRelease(c);
	CGColorSpaceRelease(cs);
	free(px);
	return sum / (double)(w * h);
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2) {
			fprintf(stderr, "usage: heicdec FILE [MAXPIXELS [OPTS: h a z]]\n");
			return 2;
		}
		int maxpx = argc > 2 ? atoi(argv[2]) : 256;
		const char *opts = argc > 3 ? argv[3] : "";
		NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
		CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
		if (src == NULL) {
			printf("source: none\n");
			return 1;
		}
		NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
		printf("source: type %s, %zu image(s), %s x %s\n", [(__bridge NSString *)CGImageSourceGetType(src) UTF8String],
		    CGImageSourceGetCount(src), [[props[@"PixelWidth"] description] UTF8String],
		    [[props[@"PixelHeight"] description] UTF8String]);
		NSArray *emb = props[@"ThumbnailImages"];
		printf("embedded thumbnail(s): %lu\n", (unsigned long)emb.count);

		int rc = 1;
		uint64_t t0 = mach_absolute_time();
		NSMutableDictionary *topt = [NSMutableDictionary dictionary];
		topt[strchr(opts, 'a') ? (id)kCGImageSourceCreateThumbnailFromImageIfAbsent :
		    (id)kCGImageSourceCreateThumbnailFromImageAlways] = @YES;
		topt[(id)kCGImageSourceThumbnailMaxPixelSize] = @(strchr(opts, 'z') ? 0 : maxpx);
		topt[(id)kCGImageSourceCreateThumbnailWithTransform] = @YES;
		if (strchr(opts, 'h')) {
			topt[@"kCGImageSourceUseHardwareAcceleratedDecode"] = @YES;
		}
		printf("thumbnail options: %s\n", [[topt description] UTF8String]);
		CGImageRef th = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)topt);
		if (th) {
			printf("thumbnail: %zux%zu in %.1f ms, mean %.1f\n", CGImageGetWidth(th), CGImageGetHeight(th), ms_since(t0),
			    mean_of(th));
			CGImageRelease(th);
			rc = 0;
		} else {
			printf("thumbnail: failed after %.1f ms\n", ms_since(t0));
		}
		t0 = mach_absolute_time();
		CGImageRef full = CGImageSourceCreateImageAtIndex(src, 0, NULL);
		if (full) {
			double m = mean_of(full);	/* (decoding is lazy: the draw decodes) */
			printf("full: %zux%zu decoded and drawn in %.1f ms, mean %.1f\n", CGImageGetWidth(full),
			    CGImageGetHeight(full), ms_since(t0), m);
			CGImageRelease(full);
		} else {
			printf("full: failed after %.1f ms\n", ms_since(t0));
		}
		CFRelease(src);

		printf("VideoToolbox: hardware HEVC decode %s\n", VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? "yes" : "no");
		return rc;
	}
}
