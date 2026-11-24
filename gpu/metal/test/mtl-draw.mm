// mtl-draw.mm - Metal on the phone: UniXNU's native Metal frontend (AdrenoMetal, MIT) over the metal2vulkan runtime, on our
// Turnip (/usr/lib/bluevk.dylib) through bluedrm. No plugin and no system process: the program opens the frontend's device
// itself, then draws QuartzCore's stroke_line pipeline through the Metal API, the picture gpu/mesa-ios/test/vk-draw.c draws
// through Vulkan, and checks the same pixels.
//
//   mtl-draw [TURNIP] [QUARTZCORE.metallib] [PAIRS]
//
// TURNIP defaults to /usr/lib/bluevk.dylib, the metallib to the system QuartzCore's. With PAIRS > 0 it then runs the
// frontend's benchmark (native_bridge_metal_benchmark): the first PAIRS vertex/fragment pairs of the metallib made into
// BGRA8 render states and drawn once each.
//
// Copyright (c) 2026 pixel3-ios. MIT licence.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "NativeBridgeMetalFrontend.h"

#define W 256
#define H 256

static void
missing(const char *cls, const char *sel)
{
	printf("mtl-draw: missing %s %s\n", cls, sel);
}

static int
draw(id<MTLDevice> dev, NSString *libpath)
{
	NSError *err = nil;
	// MTL_DRAW_TRI=tri.metallib (test/tri.metal): one full-screen orange triangle instead, the frontend alone
	const char *tri = getenv("MTL_DRAW_TRI");
	if (tri)
		libpath = @(tri);
	id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:libpath] error:&err];
	if (!lib) {
		printf("mtl-draw: newLibraryWithURL %s: %s\n", libpath.UTF8String, err.description.UTF8String);
		return 1;
	}
	id<MTLFunction> vf = [lib newFunctionWithName:tri ? @"tri_v" : @"stroke_line_vert_lpf"];
	id<MTLFunction> ff = [lib newFunctionWithName:tri ? @"tri_f" : @"stroke_line_frag_lpf"];
	if (!vf || !ff) {
		printf("mtl-draw: no stroke_line functions\n");
		return 1;
	}
	MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
	rpd.vertexFunction = vf;
	rpd.fragmentFunction = ff;
	rpd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
	if (!ps) {
		printf("mtl-draw: pipeline: %s\n", err.description.UTF8String);
		return 1;
	}
	printf("mtl-draw: pipeline stroke_line_vert_lpf + stroke_line_frag_lpf created\n");

	// [[buffer(1)]]: points; 2: transform (x' = x * [0].x + [3].x, y' = y * [1].y + [3].y), 64 bytes; 5: color, half width,
	// half cap length, 24 bytes (the indices in metal2vulkan's meta, interface.slots)
	static const float points[][2] = { { 48, 48 }, { 208, 48 }, { 208, 208 }, { 48, 208 }, { 48, 48 }, { 208, 208 } };
	const NSUInteger nseg = sizeof(points) / sizeof(points[0]) - 1;
	float xf[16] = { 0 };
	xf[0] = 2.0f / W;
	xf[5] = 2.0f / H;
	xf[12] = -1.0f;
	xf[13] = -1.0f;
	float style[6] = { 1.0f, 0.5f, 0.0f, 1.0f, 4.0f, 4.0f };
	id<MTLBuffer> pts = [dev newBufferWithBytes:points length:sizeof(points) options:MTLResourceStorageModeShared];

	MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                                                              width:W height:H mipmapped:NO];
	td.usage = MTLTextureUsageRenderTarget;
	td.storageMode = MTLStorageModePrivate;
	id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
	id<MTLBuffer> rb = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];

	id<MTLCommandQueue> q = [dev newCommandQueue];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = tex;
	rp.colorAttachments[0].loadAction = MTLLoadActionClear;
	rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
	[enc setRenderPipelineState:ps];
	[enc setViewport:(MTLViewport){ 0, 0, W, H, 0, 1 }];
	[enc setScissorRect:(MTLScissorRect){ 0, 0, W, H }];
	[enc setVertexBuffer:pts offset:0 atIndex:1];
	[enc setVertexBytes:xf length:sizeof(xf) atIndex:2];
	[enc setVertexBytes:style length:sizeof(style) atIndex:5];
	if (tri)
		[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	else
		[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:nseg];
	[enc endEncoding];
	id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
	[bl copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
	           toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
	[bl endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	if (cb.status != MTLCommandBufferStatusCompleted) {
		printf("mtl-draw: command buffer status %ld: %s\n", (long)cb.status, cb.error.description.UTF8String);
		return 1;
	}

	const uint8_t *pix = (const uint8_t *)rb.contents;
	auto px = [&](int x, int y) {
		const uint8_t *p = pix + (y * W + x) * 4;
		return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
	};
	uint32_t lit = 0, full = 0;
	for (int i = 0; i < W * H; i++) {
		uint32_t v = ((const uint32_t *)pix)[i];
		lit += (v & 0x00ffffff) != 0;
		full += v == 0xffff8000u;
	}
	if (tri) {
		printf("mtl-draw: triangle: %u of %u pixels orange\n", full, W * H);
		return full == W * H ? 0 : 3;
	}
	struct { int x, y; uint32_t want; const char *what; } probes[] = {
		{ 128, 48, 0xffff8000u, "top edge, centre of the stroke" },
		{ 208, 128, 0xffff8000u, "right edge" },
		{ 128, 128, 0xffff8000u, "diagonal, centre" },
		{ 128, 60, 0xff000000u, "inside the square, off the strokes" },
		{ 10, 10, 0xff000000u, "outside" },
	};
	int bad = 0;
	for (auto &p : probes) {
		uint32_t v = px(p.x, p.y), v2 = px(p.x - (p.x == 208), p.y - (p.y == 48));
		int ok = v == p.want || v2 == p.want;
		bad += !ok;
		printf("mtl-draw: (%3d,%3d) %08x %s  %s\n", p.x, p.y, v, ok ? "ok " : "BAD", p.what);
	}
	printf("mtl-draw: %u lit pixels, %u full orange (vk-draw: 6770, 5174)\n", lit, full);
	printf("mtl-draw: %s\n", bad ? "DRAW WRONG" : "DRAW ok");
	return bad ? 3 : 0;
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		const char *turnip = argc > 1 ? argv[1] : "/usr/lib/bluevk.dylib";
		NSString *qc = argc > 2 ? @(argv[2]) : @"/System/Library/Frameworks/QuartzCore.framework/default.metallib";
		unsigned pairs = argc > 3 ? (unsigned)atoi(argv[3]) : 0;
		const char *cache = "/private/var/tmp/mtl-draw-cache";
		// the frontend's own diagnostics, to stderr (bluerun captures it)
		setenv("SHENG_DIAG", "1", 0);
		setenv("NMB_LOG_STDERR", "1", 0);
		mkdir(cache, 0755);
		id<MTLDevice> dev = native_bridge_metal_open(turnip, cache, 0, missing);
		if (!dev) {
			char why[512] = "";
			native_bridge_metal_first_problem(why, sizeof why);
			printf("mtl-draw: no device: %s\n", why);
			return 1;
		}
		printf("mtl-draw: device \"%s\"\n", dev.name.UTF8String);
		int r = draw(dev, qc);
		char p0[1024] = "";
		if (native_bridge_metal_first_problem(p0, sizeof p0))
			printf("mtl-draw: problem after the draw: %s\n", p0);
		char line[1024] = "";
		native_bridge_metal_status(line, sizeof line);
		printf("mtl-draw: status %s\n", line);
		if (pairs) {
			static char out[16384];
			native_bridge_metal_benchmark(dev, qc.UTF8String, pairs, out, sizeof out);
			fputs(out, stdout);
		}
		char why[512] = "";
		if (native_bridge_metal_first_problem(why, sizeof why))
			printf("mtl-draw: first problem: %s\n", why);
		return r;
	}
}
