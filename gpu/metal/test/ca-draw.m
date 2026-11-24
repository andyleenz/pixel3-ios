// ca-draw.m - CoreAnimation's Metal compositor on the A630: CARenderer renders a small layer tree into an MTLTexture of
// MTLCreateSystemDefaultDevice's device (on the phone: the BlueMetal plugin's, opted in with BLUE_METAL=1). QuartzCore picks
// its own compositor pipelines and function constants, so this is the path backboardd's render server would take.
//
//   ca-draw [-dump] [-iosurface] [out.ppm]
//   ca-draw -bench [frames]
//   ca-draw -a8: an alpha-only CGImage (806x234, rows of 832 bytes: a rect and an ellipse) as layer contents over white, as the
//     lock screen's clock comes from SpringBoard
//   ca-draw -rgba: the same with 32-bit BGRA images at rows of 752, 816 and 768 bytes
//   ca-draw -text: a CATextLayer ("12:34", white on black, 256x96) drawn as text art and hashed, as the lock screen's clock
//   ca-draw -matrix: -bench 12 again in child processes under several TU_DEBUG settings (Turnip's render modes)
//
// -iosurface: the target is an IOSurface-backed texture, as backboardd's display surfaces are, and the check reads
// the surface's pages from the CPU (IOSurfaceLock) instead of a blit.
// -bench: frames (default 30) of a screen-sized (1125x2250) IOSurface target, the blue square moving each frame; prints the
// time of each frame (CARenderer render + the GPU until its command buffer completes) and the pipeline-free average.
//
// The tree, 256x256 on black: an orange square (48..208, corner radius 24) and over it a blue square (96..160) at
// opacity 0.5. Every probe is symmetric about the centre, so a flipped y axis doesn't matter. On the Mac the same program
// over Apple's Metal gives the reference.
//
// Copyright (c) 2026 pixel3-ios. MIT licence.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

extern char **environ;

#define W 256
#define H 256

static CGColorRef
rgb(CGFloat r, CGFloat g, CGFloat b)
{
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGFloat c[4] = { r, g, b, 1 };
	CGColorRef color = CGColorCreate(cs, c);
	CGColorSpaceRelease(cs);
	return color;
}

static uint32_t
px(const uint8_t *pix, int x, int y)
{
	const uint8_t *p = pix + (y * W + x) * 4;
	return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
}

static int
near(uint32_t a, uint32_t b, int tol)
{
	for (int s = 0; s < 32; s += 8) {
		int d = (int)((a >> s) & 0xff) - (int)((b >> s) & 0xff);
		if (d > tol || d < -tol)
			return 0;
	}
	return 1;
}

static double
now_ms(void)
{
	return CACurrentMediaTime() * 1000.0;
}

static int
bench_one(id<MTLDevice> dev, int frames, int bw, int bh, int surface)
{
	IOSurfaceRef ios = !surface ? NULL : IOSurfaceCreate((__bridge CFDictionaryRef) @{
		(id)kIOSurfaceWidth : @(bw), (id)kIOSurfaceHeight : @(bh), (id)kIOSurfaceBytesPerElement : @4,
		(id)kIOSurfaceBytesPerRow : @((bw * 4 + 63) / 64 * 64), (id)kIOSurfacePixelFormat : @(0x42475241)
	});
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                              width:bw height:bh mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = surface ? MTLStorageModeShared : MTLStorageModePrivate;
	id<MTLTexture> tex = surface ? (ios ? [dev newTextureWithDescriptor:td iosurface:ios plane:0] : nil) : [dev newTextureWithDescriptor:td];
	if (!tex) {
		printf("ca-draw: bench: no target texture\n");
		return 1;
	}
	id<MTLCommandQueue> q = [dev newCommandQueue];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	CALayer *root = [CALayer layer];
	root.frame = CGRectMake(0, 0, bw, bh);
	root.backgroundColor = rgb(0, 0, 0);
	root.opaque = YES;
	CALayer *sq = [CALayer layer];
	sq.frame = CGRectMake(bw * 0.09, bh * 0.13, bw * 0.8, bh * 0.4);
	sq.backgroundColor = rgb(1, 0.5, 0);
	sq.cornerRadius = bw * 0.05;
	[root addSublayer:sq];
	CALayer *blue = [CALayer layer];
	blue.frame = CGRectMake(bw * 0.18, bh * 0.18, bw * 0.27, bw * 0.27);
	blue.backgroundColor = rgb(0, 0, 1);
	blue.opacity = 0.5;
	[root addSublayer:blue];
	[CATransaction commit];
	CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue : q }];
	r.layer = root;
	r.bounds = CGRectMake(0, 0, bw, bh);
	double sum = 0, lo = 1e9, hi = 0;
	int counted = 0;
	for (int f = 0; f < frames; f++) {
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		blue.position = CGPointMake(bw * (0.3 + (f % 20) * 0.02), bh * (0.25 + (f % 20) * 0.02));
		[CATransaction commit];
		[CATransaction flush];
		double t0 = now_ms();
		[r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
		[r addUpdateRect:r.bounds];
		[r render];
		[r endFrame];
		double t1 = now_ms();
		id<MTLCommandBuffer> cb = [q commandBuffer];
		[cb commit];
		[cb waitUntilCompleted];
		double t2 = now_ms();
		if (f < 3 || f == frames - 1)
			printf("ca-draw: bench frame %2d: %7.2f ms (render %.2f, GPU wait %.2f)\n", f, t2 - t0, t1 - t0, t2 - t1);
		if (f >= 3) {
			sum += t2 - t0, counted++;
			lo = t2 - t0 < lo ? t2 - t0 : lo;
			hi = t2 - t0 > hi ? t2 - t0 : hi;
		}
	}
	if (counted)
		printf("ca-draw: bench %4dx%-4d %-9s frames 3..%d mean %7.2f ms, min %7.2f, max %7.2f\n", bw, bh,
		    surface ? "IOSurface" : "private", frames - 1, sum / counted, lo, hi);
	return 0;
}

static void
clear_bench(id<MTLCommandQueue> q, id<MTLTexture> t, const char *what, int frames)
{
	double sum = 0, gpu = 0, sched = 0;
	for (int i = 0; i < frames; i++) {
		double t0 = now_ms();
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = t;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear;
		rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLCommandBuffer> cb = [q commandBuffer];
		[[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
		double te = now_ms();
		[cb commit];
		double tc = now_ms();
		[cb waitUntilScheduled];
		double ts = now_ms();
		[cb waitUntilCompleted];
		double td = now_ms();
		double g = (cb.GPUEndTime - cb.GPUStartTime) * 1000;
		if (i < 4)
			printf("ca-draw: clear %s %d: encode %.2f, commit %.2f, scheduled +%.2f, completed +%.2f ms, GPU %.3f ms\n", what,
			    i, te - t0, tc - te, ts - tc, td - ts, g);
		if (i >= 3)
			sum += td - t0, gpu += g, sched += ts - tc;
	}
	printf("ca-draw: bench clear 1125x2250 %s: mean %.2f ms, GPU %.3f ms, commit to scheduled %.2f ms\n", what,
	    sum / (frames - 3), gpu / (frames - 3), sched / (frames - 3));
}

static int
bench(id<MTLDevice> dev, int frames)
{
	// the queue alone: an empty command buffer, committed and waited for
	id<MTLCommandQueue> q = [dev newCommandQueue];
	double sum = 0;
	for (int i = 0; i < frames; i++) {
		double t0 = now_ms();
		id<MTLCommandBuffer> cb = [q commandBuffer];
		[cb commit];
		[cb waitUntilCompleted];
		if (i >= 3)
			sum += now_ms() - t0;
	}
	printf("ca-draw: bench empty command buffer: mean %.2f ms\n", sum / (frames - 3));
	// a clear of a screen-sized texture, one render pass, nothing drawn: private, then an IOSurface (an import)
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                              width:1125 height:2250 mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModePrivate;
	clear_bench(q, [dev newTextureWithDescriptor:td], "private", frames);
	IOSurfaceRef ios = IOSurfaceCreate((__bridge CFDictionaryRef) @{
		(id)kIOSurfaceWidth : @1125, (id)kIOSurfaceHeight : @2250, (id)kIOSurfaceBytesPerElement : @4,
		(id)kIOSurfaceBytesPerRow : @((1125 * 4 + 63) / 64 * 64), (id)kIOSurfacePixelFormat : @(0x42475241)
	});
	td.storageMode = MTLStorageModeShared;
	id<MTLTexture> st = ios ? [dev newTextureWithDescriptor:td iosurface:ios plane:0] : nil;
	if (st)
		clear_bench(q, st, "IOSurface", frames);
	td.storageMode = MTLStorageModeShared;  // linear, no IOSurface: the runtime's own memory
	clear_bench(q, [dev newTextureWithDescriptor:td], "shared", frames);
	return bench_one(dev, frames, 256, 256, 0) | bench_one(dev, frames, 1125, 2250, 0) | bench_one(dev, frames, 1125, 2250, 1);
}

// renders root (tw x th) into a private texture and prints it as 64 columns of text art (green channel, inverted if asked)
// and a hash
static void
render_art(id<MTLDevice> dev, CALayer *root, int tw, int th, int invert, const char *what)
{
	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                              width:tw height:th mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
	id<MTLCommandQueue> q = [dev newCommandQueue];
	CARenderer *r = [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue : q }];
	r.layer = root;
	r.bounds = CGRectMake(0, 0, tw, th);
	[CATransaction flush];
	[r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
	[r addUpdateRect:r.bounds];
	[r render];
	[r endFrame];
	id<MTLBuffer> rb = [dev newBufferWithLength:tw * th * 4 options:MTLResourceStorageModeShared];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
	[bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(tw, th, 1)
	           toBuffer:rb destinationOffset:0 destinationBytesPerRow:tw * 4 destinationBytesPerImage:tw * th * 4];
	[bl endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	const uint8_t *pix = rb.contents;
	uint64_t hash = 1469598103934665603ull;
	unsigned lit = 0;
	for (int i = 0; i < tw * th; i++) {
		uint32_t v = ((const uint32_t *)pix)[i];
		lit += invert ? (v & 0x00ffffff) != 0x00ffffff : (v & 0x00ffffff) != 0;
		hash = (hash ^ v) * 1099511628211ull;
	}
	// cells of tw/64 x the same height: ' ' none, '.' some, '+' half, '#' most of the cell's green
	int cw = tw / 64, ch = cw;
	for (int y = 0; y + ch <= th; y += ch) {
		char line[65];
		for (int c = 0; c < 64; c++) {
			unsigned sum = 0;
			for (int dy = 0; dy < ch; dy++)
				for (int dx = 0; dx < cw; dx++) {
					unsigned g = pix[((y + dy) * tw + c * cw + dx) * 4 + 1];
					sum += invert ? 255 - g : g;
				}
			sum /= cw * ch;
			line[c] = sum > 192 ? '#' : sum > 96 ? '+' : sum > 16 ? '.' : ' ';
		}
		line[64] = 0;
		printf("ca-draw: %s |%s|\n", what, line);
	}
	printf("ca-draw: %s %u lit pixels, hash %016llx\n", what, lit, (unsigned long long)hash);
}

static int
text(id<MTLDevice> dev)
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	CALayer *root = [CALayer layer];
	root.frame = CGRectMake(0, 0, 256, 96);
	root.backgroundColor = rgb(0, 0, 0);
	root.opaque = YES;
	CATextLayer *t = [CATextLayer layer];
	t.frame = CGRectMake(8, 8, 240, 80);
	t.string = @"12:34";
	t.fontSize = 64;
	t.foregroundColor = rgb(1, 1, 1);
	t.contentsScale = 1;
	[root addSublayer:t];
	[CATransaction commit];
	render_art(dev, root, 256, 96, 0, "text");
	return 0;
}

// gray: a DeviceGray 8-bit image (white shapes) over black; mask: the same bytes as a CGImageMaskCreate mask over white
static void
a8_one(id<MTLDevice> dev, uint8_t *bits, int iw, int ih, int row, int mask)
{
	CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, bits, (size_t)row * ih, NULL);
	CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray(), rgb_ = CGColorSpaceCreateDeviceRGB();
	// mask 2: 32-bit BGRA (premultiplied, alpha first, little endian), the same shapes in white
	CGImageRef img = mask == 1 ? CGImageMaskCreate(iw, ih, 8, 8, row, dp, NULL, false)
	               : mask == 2 ? CGImageCreate(iw, ih, 8, 32, row, rgb_,
	                                 (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, dp, NULL, false,
	                                 kCGRenderingIntentDefault)
	                           : CGImageCreate(iw, ih, 8, 8, row, gray, (CGBitmapInfo)kCGImageAlphaNone, dp, NULL, false,
	                                 kCGRenderingIntentDefault);
	const char *what = mask == 1 ? "a8 mask" : mask == 2 ? "rgba" : "a8 gray";
	if (mask == 2)
		mask = 0;
	printf("ca-draw: %s image %zux%zu, %zu bytes per row\n", what, CGImageGetWidth(img), CGImageGetHeight(img),
	    CGImageGetBytesPerRow(img));
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	CALayer *root = [CALayer layer];
	root.frame = CGRectMake(0, 0, 832, 260);
	root.backgroundColor = mask ? rgb(1, 1, 1) : rgb(0, 0, 0);  // the largest image (806x234) with a margin
	root.opaque = YES;
	CALayer *l = [CALayer layer];
	l.frame = CGRectMake(13, 13, iw, ih);
	l.contents = (__bridge id)img;
	[root addSublayer:l];
	[CATransaction commit];
	render_art(dev, root, 832, 260, mask, what);
}

static int
a8(id<MTLDevice> dev)
{
	// widths and rows as backboardd's clock and date textures have them (bbm5, bbm6): 832 is a multiple of 64, 544 and 672 are not
	const int sizes[][3] = { { 806, 234, 832 }, { 542, 234, 544 }, { 671, 234, 672 } };
	for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
		const int iw = sizes[i][0], ih = sizes[i][1], row = sizes[i][2];
		uint8_t *bits = calloc(row, ih);
		for (int y = 0; y < ih; y++)
			for (int x = 0; x < iw; x++) {
				int rect = x >= iw * 6 / 80 && x < iw * 26 / 80 && y >= 40 && y < 190;
				double ex = (x - iw * 0.7) / (iw * 0.21), ey = (y - 115) / 95.0;
				bits[y * row + x] = rect || ex * ex + ey * ey <= 1 ? 255 : 0;
			}
		printf("ca-draw: a8 %dx%d rows of %d\n", iw, ih, row);
		a8_one(dev, bits, iw, ih, row, 0);
	}
	return 0;
}

// -rgba: 32-bit images at rows that are multiples of 16 but not of 64 (752, 816) and one of 64 (768), as backboardd's boot
// logo (sheared under Metal, bbm8)
static int
rgba(id<MTLDevice> dev)
{
	const int sizes[][3] = { { 186, 234, 752 }, { 201, 234, 816 }, { 190, 234, 768 } };
	for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
		const int iw = sizes[i][0], ih = sizes[i][1], row = sizes[i][2];
		uint8_t *bits = calloc(row, ih);
		for (int y = 0; y < ih; y++)
			for (int x = 0; x < iw; x++) {
				int rect = x >= iw / 10 && x < iw * 4 / 10 && y >= 40 && y < 190;
				double ex = (x - iw * 0.7) / (iw * 0.25), ey = (y - 115) / 95.0;
				if (rect || ex * ex + ey * ey <= 1)
					memset(bits + y * row + x * 4, 255, 4);
			}
		printf("ca-draw: rgba %dx%d rows of %d\n", iw, ih, row);
		a8_one(dev, bits, iw, ih, row, 2);
	}
	return 0;
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		if (argc > 1 && !strcmp(argv[1], "-matrix")) {
			const char *modes[] = { "startup", "sysmem", "gmem", "nobin", "nolrz" };
			char self[1024];
			uint32_t size = sizeof self;
			if (_NSGetExecutablePath(self, &size))
				return 1;
			for (unsigned m = 0; m < sizeof modes / sizeof modes[0]; m++) {
				printf("ca-draw: matrix: TU_DEBUG=%s\n", modes[m]);
				setenv("TU_DEBUG", modes[m], 1);
				char *args[] = { self, "-bench", "12", NULL };
				pid_t pid;
				int st = 0;
				if (posix_spawn(&pid, self, NULL, NULL, args, environ) == 0)
					waitpid(pid, &st, 0);
				printf("ca-draw: matrix: TU_DEBUG=%s exit %d\n", modes[m], WIFEXITED(st) ? WEXITSTATUS(st) : -1);
			}
			return 0;
		}
		setenv("BLUE_METAL", "1", 0);
		// -dump: the frontend logs CoreAnimation's command buffers (passes, draws, pipelines, bound data)
		if (argc > 1 && !strcmp(argv[1], "-dump")) {
			setenv("NATIVE_METAL_DUMP_CB", "1:4", 1);
			setenv("NATIVE_METAL_DUMP_LOG", "1", 1);
			setenv("NMB_LOG_STDERR", "1", 1);
			argc--, argv++;
		}
		int surface = 0;
		if (argc > 1 && !strcmp(argv[1], "-iosurface"))
			surface = 1, argc--, argv++;
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		if (!dev) {
			printf("ca-draw: MTLCreateSystemDefaultDevice: nil\n");
			return 1;
		}
		printf("ca-draw: device \"%s\"\n", dev.name.UTF8String);
		if (argc > 1 && !strcmp(argv[1], "-bench"))
			return bench(dev, argc > 2 ? atoi(argv[2]) : 30);
		if (argc > 1 && !strcmp(argv[1], "-text"))
			return text(dev);
		if (argc > 1 && !strcmp(argv[1], "-a8"))
			return a8(dev);
		if (argc > 1 && !strcmp(argv[1], "-rgba"))
			return rgba(dev);

		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                                              width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModePrivate;
		IOSurfaceRef ios = NULL;
		id<MTLTexture> tex;
		if (surface) {
			ios = IOSurfaceCreate((__bridge CFDictionaryRef) @{
				(id)kIOSurfaceWidth : @W, (id)kIOSurfaceHeight : @H, (id)kIOSurfaceBytesPerElement : @4,
				(id)kIOSurfaceBytesPerRow : @(W * 4), (id)kIOSurfacePixelFormat : @(0x42475241) /* 'BGRA' */
			});
			if (!ios) {
				printf("ca-draw: IOSurfaceCreate: NULL\n");
				return 1;
			}
			IOSurfaceLock(ios, 0, NULL);
			memset(IOSurfaceGetBaseAddress(ios), 0x55, IOSurfaceGetAllocSize(ios));
			IOSurfaceUnlock(ios, 0, NULL);
			td.storageMode = MTLStorageModeShared;
			tex = [dev newTextureWithDescriptor:td iosurface:ios plane:0];
			printf("ca-draw: IOSurface %u, %zu bytes, row %zu: texture %s\n", IOSurfaceGetID(ios), IOSurfaceGetAllocSize(ios),
			    IOSurfaceGetBytesPerRow(ios), tex ? "ok" : "nil");
		} else
			tex = [dev newTextureWithDescriptor:td];
		if (!tex) {
			printf("ca-draw: no target texture\n");
			return 1;
		}
		id<MTLCommandQueue> q = [dev newCommandQueue];

		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		CALayer *root = [CALayer layer];
		root.frame = CGRectMake(0, 0, W, H);
		root.backgroundColor = rgb(0, 0, 0);
		root.opaque = YES;
		CALayer *sq = [CALayer layer];
		sq.frame = CGRectMake(48, 48, 160, 160);
		sq.backgroundColor = rgb(1, 0.5, 0);
		sq.cornerRadius = 24;
		[root addSublayer:sq];
		CALayer *blue = [CALayer layer];
		blue.frame = CGRectMake(96, 96, 64, 64);
		blue.backgroundColor = rgb(0, 0, 1);
		blue.opacity = 0.5;
		[root addSublayer:blue];
		[CATransaction commit];

		// CA_NOQ=1: the renderer's own queue (it commits and waits until scheduled) instead of ours
		CARenderer *r = [CARenderer rendererWithMTLTexture:tex
		                                          options:getenv("CA_NOQ") ? @{} : @{ kCARendererMetalCommandQueue : q }];
		if (!r) {
			printf("ca-draw: rendererWithMTLTexture: nil\n");
			return 1;
		}
		r.layer = root;
		r.bounds = CGRectMake(0, 0, W, H);
		[CATransaction flush];
		[r beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
		CGRect ub = r.updateBounds;
		printf("ca-draw: update bounds %.0f,%.0f %.0fx%.0f\n", ub.origin.x, ub.origin.y, ub.size.width, ub.size.height);
		[r addUpdateRect:r.bounds];
		[r render];
		[r endFrame];
		if (getenv("CA_NOQ"))
			usleep(200000);
		printf("ca-draw: CARenderer frame rendered\n");

		// after CoreAnimation's command buffer on the same queue: copy out
		id<MTLBuffer> rb = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
		[bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
		           toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
		[bl endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
		if (cb.status != MTLCommandBufferStatusCompleted) {
			printf("ca-draw: readback status %ld: %s\n", (long)cb.status, cb.error.description.UTF8String);
			return 1;
		}
		const uint8_t *pix = rb.contents;
		if (ios) {
			// the surface's own pages, as the display reads them (rows are W * 4 bytes, checked above)
			IOSurfaceLock(ios, kIOSurfaceLockReadOnly, NULL);
			const uint8_t *sp = IOSurfaceGetBaseAddress(ios);
			size_t row = IOSurfaceGetBytesPerRow(ios), differ = 0;
			for (int y = 0; y < H; y++)
				differ += memcmp(sp + y * row, pix + y * W * 4, W * 4) != 0;
			printf("ca-draw: IOSurface pages vs blit: %zu of %d rows differ\n", differ, H);
			uint8_t *copy = malloc(W * H * 4);
			for (int y = 0; y < H; y++)
				memcpy(copy + y * W * 4, sp + y * row, W * 4);
			IOSurfaceUnlock(ios, kIOSurfaceLockReadOnly, NULL);
			pix = copy;
		}

		// expected: orange ff ff 80 00; blue at 0.5 over orange (premultiplied source-over) ff 80 40 80
		struct { int x, y; uint32_t want; const char *what; } probes[] = {
			{ 128, 128, 0xff804080u, "centre: blue at 0.5 over orange" },
			{ 64, 128, 0xffff8000u, "orange, left of the blue" },
			{ 192, 128, 0xffff8000u, "orange, right of the blue" },
			{ 128, 64, 0xffff8000u, "orange, above or below the blue" },
			{ 50, 50, 0xff000000u, "corner of the square, cut by the radius" },
			{ 205, 205, 0xff000000u, "opposite corner, cut" },
			{ 10, 10, 0xff000000u, "background" },
		};
		int bad = 0;
		for (unsigned i = 0; i < sizeof probes / sizeof probes[0]; i++) {
			uint32_t v = px(pix, probes[i].x, probes[i].y);
			int ok = near(v, probes[i].want, 3);
			bad += !ok;
			printf("ca-draw: (%3d,%3d) %08x want %08x %s  %s\n", probes[i].x, probes[i].y, v, probes[i].want, ok ? "ok " : "BAD",
			    probes[i].what);
		}
		uint32_t orange = 0, lit = 0;
		uint64_t hash = 1469598103934665603ull;
		for (int i = 0; i < W * H; i++) {
			uint32_t v = ((const uint32_t *)pix)[i];
			lit += (v & 0x00ffffff) != 0;
			orange += v == 0xffff8000u;
			hash = (hash ^ v) * 1099511628211ull;
		}
		printf("ca-draw: %u lit pixels, %u orange, hash %016llx\n", lit, orange, (unsigned long long)hash);
		if (argc > 1) {
			FILE *f = fopen(argv[1], "wb");
			if (f) {
				fprintf(f, "P6\n%d %d\n255\n", W, H);
				for (int i = 0; i < W * H; i++)
					fputc(pix[i * 4 + 2], f), fputc(pix[i * 4 + 1], f), fputc(pix[i * 4], f);
				fclose(f);
			}
		}
		printf("ca-draw: %s\n", bad ? "DRAW WRONG" : "DRAW ok");
		return bad ? 3 : 0;
	}
}
