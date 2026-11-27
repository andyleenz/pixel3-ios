/*
 * vtxfer metal|cpu [W H] [VAR=VALUE...] - VTPixelTransferSession scaling as CMPhoto does for a photograph's thumbnail, checked.
 *
 * Fills a 4032x3024 420f IOSurface-backed buffer with a known pattern (Y = horizontal ramp, Cb = 64, Cr = 192),
 * scales it to W x H (default 240x320, 420f) and prints the destination planes' row stats and errors against the
 * expected ramp. "metal" sets BLUE_METAL=1 (BlueMetal gives this process a device), "cpu" BLUE_METAL=0, to compare
 * VideoToolbox's Metal path with its CPU path. "trace" (after metal) logs VideoToolbox's Metal calls (BlueMetal's
 * NB* classes swizzled: functions, textures, buffers, dispatches, render passes). VAR=VALUE arguments are set in the environment first (runtime switches).
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>
#include <objc/runtime.h>
#include <mach/mach_time.h>

static CVPixelBufferRef
make(size_t w, size_t h)
{
	NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
	CVPixelBufferRef pb = NULL;
	CVReturn r = CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, (__bridge CFDictionaryRef)a, &pb);
	if (r != 0)
		printf("CVPixelBufferCreate %zux%zu: %d\n", w, h, r);
	return pb;
}

static const char *
texinfo(id<MTLTexture> t)
{
	static char b[4][160];
	static int n;
	char *o = b[n++ & 3];
	if (t == nil)
		return "nil";
	snprintf(o, 160, "%lux%lu fmt %lu usage %lx storage %lu type %lu surf %p plane %lu", (unsigned long)t.width,
	    (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.usage, (unsigned long)t.storageMode,
	    (unsigned long)t.textureType, t.iosurface, (unsigned long)t.iosurfacePlane);
	return o;
}

/* A small float table (the scaler's filter taps): its bytes as the CPU reads them against a GPU blit copy of it. */
static void
compareTable(id<MTLTexture> t)
{
	size_t w = t.width, h = t.height, row = w * 16, n = row * h;
	float *cpu = calloc(1, n);
	[t getBytes:cpu bytesPerRow:row fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
	id<MTLDevice> dev = t.device;
	id<MTLBuffer> buf = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
	id<MTLCommandQueue> q = [dev newCommandQueue];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
	    toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:n];
	[be endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	const float *gpu = buf.contents;
	size_t bad = 0, firstBad = SIZE_MAX;
	for (size_t k = 0; k < n / 4; k++)
		if (cpu[k] != gpu[k]) {
			bad++;
			if (firstBad == SIZE_MAX)
				firstBad = k;
		}
	printf("trace: table %zux%zu: %zu of %zu floats differ CPU vs GPU blit", w, h, bad, n / 4);
	if (bad)
		printf(" (first at texel %zu,%zu: cpu %g gpu %g)", firstBad / 4 % w, firstBad / 4 / w, cpu[firstBad], gpu[firstBad]);
	printf("\n  cpu row 1: %g %g %g %g | row 20: %g %g %g %g\n", cpu[w * 4], cpu[w * 4 + 1], cpu[w * 4 + 2], cpu[w * 4 + 3],
	    cpu[20 * w * 4], cpu[20 * w * 4 + 1], cpu[20 * w * 4 + 2], cpu[20 * w * 4 + 3]);
	printf("  gpu row 1: %g %g %g %g | row 20: %g %g %g %g\n", gpu[w * 4], gpu[w * 4 + 1], gpu[w * 4 + 2], gpu[w * 4 + 3],
	    gpu[20 * w * 4], gpu[20 * w * 4 + 1], gpu[20 * w * 4 + 2], gpu[20 * w * 4 + 3]);
	free(cpu);
}

#define SWZ(cls, sel, ret, blockargs, body) do { \
	Method m = class_getInstanceMethod(cls, sel); \
	if (m == NULL) { printf("trace: no %s\n", sel_getName(sel)); break; } \
	typedef ret (*F) blockargs; \
	F orig = (F)method_getImplementation(m); (void)orig; \
	method_setImplementation(m, imp_implementationWithBlock(body)); \
} while (0)

static void
trace(void)
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	printf("trace: device %s\n", dev.name.UTF8String);
	Class lib = objc_getClass("NBLibrary"), ce = objc_getClass("NBComputeEncoder"), re = objc_getClass("NBRenderEncoder"),
	      cb = objc_getClass("NBCommandBuffer");
	Class nbbuf = objc_getClass("NBBuffer"), nbtex = objc_getClass("NBTexture");
	SWZ(nbbuf, @selector(newTextureWithDescriptor:offset:bytesPerRow:), id, (id, SEL, MTLTextureDescriptor *, NSUInteger, NSUInteger),
	    ^id(id me, MTLTextureDescriptor *d, NSUInteger off, NSUInteger row) {
		id t = orig(me, @selector(newTextureWithDescriptor:offset:bytesPerRow:), d, off, row);
		printf("trace: texture on buffer (%lu bytes, contents %p): %lux%lu fmt %lu offset %lu row %lu\n",
		    (unsigned long)[(id<MTLBuffer>)me length], [(id<MTLBuffer>)me contents], (unsigned long)d.width,
		    (unsigned long)d.height, (unsigned long)d.pixelFormat, (unsigned long)off, (unsigned long)row);
		return t;
	});
	SWZ(nbtex, @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), void, (id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger),
	    ^(id me, MTLRegion r, NSUInteger l, const void *b, NSUInteger row) {
		printf("trace: replaceRegion %lu,%lu %lux%lu row %lu on %s\n", (unsigned long)r.origin.x, (unsigned long)r.origin.y,
		    (unsigned long)r.size.width, (unsigned long)r.size.height, (unsigned long)row, texinfo(me));
		orig(me, @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), r, l, b, row);
	});
	SWZ(lib, @selector(newFunctionWithName:), id, (id, SEL, NSString *), ^id(id me, NSString *name) {
		id f = orig(me, @selector(newFunctionWithName:), name);
		printf("trace: function %s -> %p\n", name.UTF8String, f);
		return f;
	});
	SWZ(lib, @selector(newFunctionWithName:constantValues:error:), id, (id, SEL, NSString *, id, NSError **),
	    ^id(id me, NSString *name, id cv, NSError **e) {
		id f = orig(me, @selector(newFunctionWithName:constantValues:error:), name, cv, e);
		printf("trace: function %s (constants) -> %p\n", name.UTF8String, f);
		return f;
	});
	SWZ(ce, @selector(setTexture:atIndex:), void, (id, SEL, id, NSUInteger), ^(id me, id<MTLTexture> t, NSUInteger i) {
		printf("trace: compute texture %lu: %s\n", (unsigned long)i, texinfo(t));
		if (t.pixelFormat == MTLPixelFormatRGBA32Float && t.storageMode != MTLStorageModePrivate)
			compareTable(t);
		orig(me, @selector(setTexture:atIndex:), t, i);
	});
	SWZ(ce, @selector(setBuffer:offset:atIndex:), void, (id, SEL, id, NSUInteger, NSUInteger),
	    ^(id me, id<MTLBuffer> b, NSUInteger o, NSUInteger i) {
		printf("trace: compute buffer %lu: %lu bytes + %lu\n", (unsigned long)i, (unsigned long)b.length, (unsigned long)o);
		orig(me, @selector(setBuffer:offset:atIndex:), b, o, i);
	});
	SWZ(ce, @selector(dispatchThreadgroups:threadsPerThreadgroup:), void, (id, SEL, MTLSize, MTLSize),
	    ^(id me, MTLSize g, MTLSize t) {
		printf("trace: dispatch groups %lux%lux%lu of %lux%lux%lu\n", (unsigned long)g.width, (unsigned long)g.height,
		    (unsigned long)g.depth, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth);
		orig(me, @selector(dispatchThreadgroups:threadsPerThreadgroup:), g, t);
	});
	SWZ(ce, @selector(dispatchThreads:threadsPerThreadgroup:), void, (id, SEL, MTLSize, MTLSize),
	    ^(id me, MTLSize g, MTLSize t) {
		printf("trace: dispatch threads %lux%lux%lu of %lux%lux%lu\n", (unsigned long)g.width, (unsigned long)g.height,
		    (unsigned long)g.depth, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth);
		orig(me, @selector(dispatchThreads:threadsPerThreadgroup:), g, t);
	});
	SWZ(re, @selector(setFragmentTexture:atIndex:), void, (id, SEL, id, NSUInteger), ^(id me, id<MTLTexture> t, NSUInteger i) {
		printf("trace: fragment texture %lu: %s\n", (unsigned long)i, texinfo(t));
		orig(me, @selector(setFragmentTexture:atIndex:), t, i);
	});
	SWZ(re, @selector(drawPrimitives:vertexStart:vertexCount:), void, (id, SEL, NSUInteger, NSUInteger, NSUInteger),
	    ^(id me, NSUInteger p, NSUInteger s0, NSUInteger n) {
		printf("trace: draw %lu vertices (primitive %lu)\n", (unsigned long)n, (unsigned long)p);
		orig(me, @selector(drawPrimitives:vertexStart:vertexCount:), p, s0, n);
	});
	SWZ(cb, @selector(renderCommandEncoderWithDescriptor:), id, (id, SEL, MTLRenderPassDescriptor *),
	    ^id(id me, MTLRenderPassDescriptor *d) {
		for (int i = 0; i < 2; i++)
			if (d.colorAttachments[i].texture != nil)
				printf("trace: render pass colour %d: %s load %lu store %lu\n", i, texinfo(d.colorAttachments[i].texture),
				    (unsigned long)d.colorAttachments[i].loadAction, (unsigned long)d.colorAttachments[i].storeAction);
		return orig(me, @selector(renderCommandEncoderWithDescriptor:), d);
	});
}

/* "tables": replaceRegion then a GPU blit copy back, for several formats and sizes; how many rows reach the GPU. */
static void
tables(void)
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	struct { MTLPixelFormat f; size_t bpp; const char *name; } fmts[] = {
		{ MTLPixelFormatRGBA32Float, 16, "rgba32f" }, { MTLPixelFormatRGBA8Unorm, 4, "rgba8" }, { MTLPixelFormatR32Float, 4, "r32f" } };
	size_t widths[] = { 15, 16, 26, 32, 64 }, heights[] = { 16, 64, 200 };
	for (size_t fi = 0; fi < 3; fi++)
		for (size_t wi = 0; wi < 5; wi++)
			for (size_t hi = 0; hi < 3; hi++) {
				size_t w = widths[wi], h = heights[hi], row = w * fmts[fi].bpp, n = row * h;
				MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmts[fi].f width:w height:h mipmapped:NO];
				d.usage = MTLTextureUsageShaderRead;
				id<MTLTexture> t = [dev newTextureWithDescriptor:d];
				uint8_t *src = malloc(n);
				for (size_t k = 0; k < n; k++)
					src[k] = (uint8_t)(k * 7 + k / 251 + 1) | 1;
				[t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:src bytesPerRow:row];
				id<MTLBuffer> buf = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
				id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
				id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
				[be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
				    toBuffer:buf destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:n];
				[be endEncoding];
				[cb commit];
				[cb waitUntilCompleted];
				const uint8_t *g = buf.contents;
				size_t goodRows = 0;
				while (goodRows < h && memcmp(src + goodRows * row, g + goodRows * row, row) == 0)
					goodRows++;
				size_t badRows = 0;
				for (size_t r = 0; r < h; r++)
					badRows += memcmp(src + r * row, g + r * row, row) != 0;
				printf("tables: %s %zux%zu (row %zu, %zu bytes): first bad row %zd, %zu bad rows\n", fmts[fi].name, w, h, row, n,
				    goodRows == h ? (ssize_t)-1 : (ssize_t)goodRows, badRows);
				free(src);
			}
}

int
main(int argc, char **argv)
{
	if (argc < 2 || (strcmp(argv[1], "metal") != 0 && strcmp(argv[1], "cpu") != 0)) {
		fprintf(stderr, "usage: vtxfer metal|cpu [W H]\n");
		return 2;
	}
	setenv("BLUE_METAL", strcmp(argv[1], "metal") == 0 ? "1" : "0", 1);
	size_t dw = 240, dh = 320;
	int n = 0;
	bool tracing = false;
	for (int i = 2; i < argc; i++) {
		if (strcmp(argv[i], "trace") == 0)
			tracing = true;
		else if (strcmp(argv[i], "tables") == 0) {
			tables();
			return 0;
		}
		else if (strchr(argv[i], '=') != NULL)
			putenv(argv[i]);
		else if (n++ == 0)
			dw = strtoul(argv[i], NULL, 0);
		else
			dh = strtoul(argv[i], NULL, 0);
	}
	if (tracing)
		trace();
	CVPixelBufferRef src = make(4032, 3024), dst = make(dw, dh);
	if (!src || !dst)
		return 1;
	CVPixelBufferLockBaseAddress(src, 0);
	uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(src, 0), *c = CVPixelBufferGetBaseAddressOfPlane(src, 1);
	size_t yr = CVPixelBufferGetBytesPerRowOfPlane(src, 0), cr = CVPixelBufferGetBytesPerRowOfPlane(src, 1);
	for (size_t j = 0; j < 3024; j++)
		for (size_t i = 0; i < 4032; i++)
			y[j * yr + i] = (uint8_t)(i * 255 / 4031);
	for (size_t j = 0; j < 1512; j++)
		for (size_t i = 0; i < 2016; i++) {
			c[j * cr + 2 * i] = 64;
			c[j * cr + 2 * i + 1] = 192;
		}
	CVPixelBufferUnlockBaseAddress(src, 0);

	VTPixelTransferSessionRef s = NULL;
	OSStatus st = VTPixelTransferSessionCreate(NULL, &s);
	uint64_t t0 = mach_absolute_time();
	st = st ? st : VTPixelTransferSessionTransferImage(s, src, dst);
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	printf("transfer %zux%zu: %d, %.1f ms\n", dw, dh, (int)st, (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6);

	CVPixelBufferLockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
	y = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
	c = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
	yr = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
	cr = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
	printf("dst rows: Y %zu, CbCr %zu\n", yr, cr);
	// The image is rotated in no way: Y should be a ramp along x in every row, CbCr 64/192.
	double yerr = 0, cerr = 0;
	size_t ybad = 0, cbad = 0;
	for (size_t j = 0; j < dh; j++)
		for (size_t i = 0; i < dw; i++) {
			int want = (int)((i + 0.5) * 255 / dw), d = abs((int)y[j * yr + i] - want);
			yerr += d;
			ybad += d > 8;
		}
	for (size_t j = 0; j < dh / 2; j++)
		for (size_t i = 0; i < dw / 2; i++) {
			int d = abs((int)c[j * cr + 2 * i] - 64) + abs((int)c[j * cr + 2 * i + 1] - 192);
			cerr += d;
			cbad += d > 8;
		}
	printf("Y mean error %.2f, %zu of %zu off by > 8\n", yerr / (dw * dh), ybad, dw * dh);
	printf("CbCr mean error %.2f, %zu of %zu off by > 8\n", cerr / (dw * dh / 4), cbad, dw * dh / 4);
	printf("Y row 0:");
	for (size_t i = 0; i < 16; i++)
		printf(" %d", y[i * dw / 16]);
	printf("\nY row %zu:", dh / 2);
	for (size_t i = 0; i < 16; i++)
		printf(" %d", y[dh / 2 * yr + i * dw / 16]);
	printf("\nCbCr row 0: %d %d %d %d\n", c[0], c[1], c[2], c[3]);
	FILE *f = fopen("/private/var/tmp/vtxfer.yuv", "w");	// both planes as they are in memory, rows included
	if (f != NULL) {
		fwrite(y, 1, yr * dh, f);
		fwrite(c, 1, cr * dh / 2, f);
		fclose(f);
	}
	CVPixelBufferUnlockBaseAddress(dst, kCVPixelBufferLock_ReadOnly);
	return 0;
}
