/*
 * bluevt.dylib - VideoToolbox rotation that also scales, without the iPhone's hardware scaler.
 *
 * Loaded with DYLD_INSERT_LIBRARIES=/usr/lib/bluevt.dylib (sweetenv) into Camera, mediaserverd and assetsd.
 *
 * VTPixelRotationSessionRotateImage rotates into a buffer of a different size only on AppleM2ScalerCSCDriver,
 * which this phone does not have. In software it returns kVTImageRotationNotSupportedErr (-12914) whenever the
 * destination is not the rotated source's size (tools/camera/vtscale, mem4: rotate 180 or 0 into 480x360 fails in
 * 0.1 ms; rotations at full size and VTPixelTransferSession scaling both work). Camera's CAMThumbnailGenerator
 * asks for exactly that ({480, 360} in orientation 3), so the capture had no preview image, assetsd no thumbnail,
 * and Photos' grid stayed empty.
 *
 * The entry is patched in place as in tools/apps/bluemis (shared-cache callers are not reached by dyld
 * interposing): its first four instructions move to a trampoline. On -12914 the call is done in two steps that
 * work in software: rotate (same session, so its rotation and flips apply) into a buffer of the source's format
 * at the rotated size, then VTPixelTransferSession into the caller's buffer (scale and format).
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define LOG(...) do { \
	char m_[512]; \
	int n_ = snprintf(m_, sizeof(m_), "BLUEVT: " __VA_ARGS__); \
	if (n_ > (int)sizeof(m_) - 1) n_ = sizeof(m_) - 1; \
	fputs(m_, stderr); \
	int c_ = open("/dev/console", O_WRONLY | O_NOCTTY); \
	if (c_ >= 0) { write(c_, m_, (size_t)n_); close(c_); } \
} while (0)

static char me[64] = "?";

typedef OSStatus (*rotate_fn)(VTPixelRotationSessionRef, CVPixelBufferRef, CVPixelBufferRef);
static rotate_fn original;      /* the trampoline: the moved prologue, then back */

static CVPixelBufferRef
make(size_t w, size_t h, OSType f)
{
	CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
	    &kCFTypeDictionaryValueCallBacks);
	const void *k[] = { kCVPixelBufferIOSurfacePropertiesKey };
	const void *v[] = { empty };
	CFDictionaryRef a = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CVPixelBufferRef pb = NULL;
	if (CVPixelBufferCreate(NULL, w, h, f, a, &pb) != kCVReturnSuccess) {
		pb = NULL;
	}
	CFRelease(a);
	CFRelease(empty);
	return pb;
}

static OSStatus
bluevt_rotate(VTPixelRotationSessionRef s, CVPixelBufferRef src, CVPixelBufferRef dst)
{
	OSStatus st = original(s, src, dst);
	if (st != kVTImageRotationNotSupportedErr || src == NULL || dst == NULL) {
		return st;
	}
	uint64_t t0 = mach_absolute_time();
	CFStringRef rot = NULL;
	(void)VTSessionCopyProperty(s, kVTPixelRotationPropertyKey_Rotation, kCFAllocatorDefault, &rot);
	bool quarter = rot && (CFEqual(rot, kVTRotation_CW90) || CFEqual(rot, kVTRotation_CCW90));
	if (rot) {
		CFRelease(rot);
	}
	size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);
	CVPixelBufferRef tmp = make(quarter ? sh : sw, quarter ? sw : sh, CVPixelBufferGetPixelFormatType(src));
	if (tmp == NULL) {
		LOG("%s: no %zux%zu buffer for the two-step rotation\n", me, quarter ? sh : sw, quarter ? sw : sh);
		return st;
	}
	OSStatus r1 = original(s, src, tmp), r2 = -1;
	if (r1 == noErr) {
		VTPixelTransferSessionRef x = NULL;
		r2 = VTPixelTransferSessionCreate(NULL, &x);
		if (r2 == noErr) {
			r2 = VTPixelTransferSessionTransferImage(x, tmp, dst);
			VTPixelTransferSessionInvalidate(x);
			CFRelease(x);
		}
	}
	CVPixelBufferRelease(tmp);
	static atomic_int told;
	if (atomic_fetch_add(&told, 1) < 3 || r1 != noErr || r2 != noErr) {
		mach_timebase_info_data_t tb;
		mach_timebase_info(&tb);
		OSType sf = CVPixelBufferGetPixelFormatType(src), df = CVPixelBufferGetPixelFormatType(dst);
		LOG("%s: rotate %zux%zu '%c%c%c%c' -> %zux%zu '%c%c%c%c'%s in two steps: rotate %d, scale %d, %.1f ms\n", me,
		    sw, sh, sf >> 24, sf >> 16, sf >> 8, sf, CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst),
		    df >> 24, df >> 16, df >> 8, df, quarter ? " (quarter turn)" : "", (int)r1, (int)r2,
		    (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6);
	}
	return r1 == noErr && r2 == noErr ? noErr : st;
}

/* the trampoline's page: a whole 16 KiB page of brk #1 in its own section (bluemis, app6) */
__asm__(".section __TEXT,__bluetramp,regular,pure_instructions\n"
        ".p2align 14\n"
        "_bluevt_tramp:\n"
        ".fill 4096, 4, 0xd4200020\n"
        ".text\n");
extern char bluevt_tramp[] __asm__("_bluevt_tramp");

static bool
pc_relative(uint32_t i)
{
	return (i & 0x1f000000) == 0x10000000 ||       /* ADR, ADRP */
	       (i & 0x7c000000) == 0x14000000 ||       /* B, BL */
	       (i & 0x3b000000) == 0x18000000 ||       /* LDR (literal) */
	       (i & 0x7e000000) == 0x34000000 ||       /* CBZ, CBNZ */
	       (i & 0x7e000000) == 0x36000000 ||       /* TBZ, TBNZ */
	       (i & 0xff000010) == 0x54000000;         /* B.cond */
}

static bool
write_code(void *dst, const void *src, size_t n)
{
	vm_address_t a = (vm_address_t)dst & ~(vm_address_t)(vm_page_size - 1);
	vm_size_t len = (((vm_address_t)dst + n + vm_page_size - 1) & ~(vm_address_t)(vm_page_size - 1)) - a;
	kern_return_t kr = vm_protect(mach_task_self(), a, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
	if (kr != KERN_SUCCESS) {
		LOG("%s: vm_protect RW %p: %d\n", me, dst, kr);
		return false;
	}
	memcpy(dst, src, n);
	kr = vm_protect(mach_task_self(), a, len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate(dst, n);
	if (kr != KERN_SUCCESS) {
		LOG("%s: vm_protect RX %p: %d\n", me, dst, kr);
		return false;
	}
	return true;
}

__attribute__((constructor)) static void
bluevt_init(void)
{
	char path[256] = "?";
	uint32_t len = sizeof(path);
	_NSGetExecutablePath(path, &len);
	const char *base = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
	snprintf(me, sizeof(me), "%s[%d]", base, getpid());

	uint32_t *t = (uint32_t *)(void *)VTPixelRotationSessionRotateImage;
	for (int i = 0; i < 4; i++) {
		if (pc_relative(t[i])) {
			LOG("%s: VTPixelRotationSessionRotateImage instruction %d (0x%08x) is PC-relative: not hooked\n", me, i, t[i]);
			return;
		}
	}
	/* trampoline: the four instructions, then ldr x16, #8; br x16; .quad t + 4 */
	uint32_t code[8];
	memcpy(code, t, 16);
	code[4] = 0x58000050;
	code[5] = 0xd61f0200;
	uint64_t back = (uint64_t)(t + 4);
	memcpy(&code[6], &back, 8);
	if (!write_code(bluevt_tramp, code, sizeof(code))) {
		return;
	}
	original = (rotate_fn)(void *)bluevt_tramp;
	/* entry: ldr x16, #8; br x16; .quad bluevt_rotate */
	uint32_t jump[4] = { 0x58000050, 0xd61f0200 };
	uint64_t to = (uint64_t)bluevt_rotate;
	memcpy(&jump[2], &to, 8);
	if (!write_code(t, jump, sizeof(jump))) {
		original = NULL;
		return;
	}
	LOG("%s: hooked VTPixelRotationSessionRotateImage at %p\n", me, (void *)t);
}
