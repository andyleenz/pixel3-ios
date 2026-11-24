// ca-draw.m - CoreAnimation's Metal compositor on the A630: CARenderer renders a small layer tree into an MTLTexture of
// MTLCreateSystemDefaultDevice's device (on the phone: the BlueMetal plugin's, opted in with BLUE_METAL=1). QuartzCore picks
// its own compositor pipelines and function constants, so this is the path backboardd's render server would take.
//
//   ca-draw [-dump] [out.ppm]
//
// The tree, 256x256 on black: an orange square (48..208, corner radius 24) and over it a blue square (96..160) at
// opacity 0.5. Every probe is symmetric about the centre, so a flipped y axis doesn't matter. On the Mac the same program
// over Apple's Metal gives the reference.
//
// Copyright (c) 2026 pixel3-ios. MIT licence.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

int
main(int argc, char **argv)
{
	@autoreleasepool {
		setvbuf(stdout, NULL, _IOLBF, 0);
		setenv("BLUE_METAL", "1", 0);
		// -dump: the frontend logs CoreAnimation's command buffers (passes, draws, pipelines, bound data)
		if (argc > 1 && !strcmp(argv[1], "-dump")) {
			setenv("NATIVE_METAL_DUMP_CB", "1:4", 1);
			setenv("NATIVE_METAL_DUMP_LOG", "1", 1);
			setenv("NMB_LOG_STDERR", "1", 1);
			argc--, argv++;
		}
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		if (!dev) {
			printf("ca-draw: MTLCreateSystemDefaultDevice: nil\n");
			return 1;
		}
		printf("ca-draw: device \"%s\"\n", dev.name.UTF8String);

		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                                              width:W height:H mipmapped:NO];
		td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		td.storageMode = MTLStorageModePrivate;
		id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
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
