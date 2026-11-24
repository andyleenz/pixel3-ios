/*
 * bluemis.dylib - lets installd accept self-signed (ad-hoc) apps.
 *
 * Loaded into installd with the boot-arg
 *   sweetenv=installd:DYLD_INSERT_LIBRARIES=/usr/lib/bluemis.dylib
 * (kernel 0214 allows it next to backboardd's entry, split by ';').
 *
 * installd checks an app's signature with libmis: InstalledContentLibrary's
 * MICodeSigningVerifier calls MISValidateSignatureAndCopyInfo, a wrapper inside libmis
 * that jumps straight to MISValidateSignatureAndCopyInfoWithProgress. Both live in the
 * shared cache, and dyld interposing does not reach that call (tried on the phone), so
 * the WithProgress entry is patched in place: its first four instructions (a plain
 * prologue, checked) move to a trampoline in our own __TEXT, and the entry jumps to us.
 * Pages are made writable with VM_PROT_COPY like blueeagl. An ad-hoc signature fails
 * there with 0xe8008014 ("The executable contains an invalid signature").
 * This interposes that call. The real check runs first; if it fails, the call
 * returns 0 with signing info read from the main executable's own code
 * signature: SigningID, CdHash, Entitlements and TeamID. The kernel's AMFI policy
 * (cs_enforcement_disable, sailfish 0139) runs the binary.
 *
 * The idea, and the info keys installd reads, are documented by AppSync Unified
 * (akemin-dayo/AppSync, GPL-3). This is a separate implementation: plain dyld
 * patching and our own signature parser, with no Substrate and no
 * certificate hooks. SignerCertificate is Apple's public "Apple iPhone OS
 * Application Signing" certificate (apple-iphone-os-application-signing.der,
 * bytes as in AppSync's kSecSigningCertificate; SHA-256 8AE18558...055CD3).
 *
 * In SpringBoard it instead makes FrontBoard trust the app (see trust_hooks).
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "out/cert.h"   /* apple-iphone-os-application-signing.der (build.sh, xxd -i) */

extern int MISValidateSignatureAndCopyInfoWithProgress(CFStringRef path, CFDictionaryRef options,
                                                       CFDictionaryRef *info, void *progress);
extern int MISValidateSignatureAndCopyInfo(CFStringRef path, CFDictionaryRef options, CFDictionaryRef *info);

/* stderr, plus /dev/console (the persistent log, as bluerun); the sandbox may refuse the latter */
#define LOG(...) do { \
	char m_[512]; \
	int n_ = snprintf(m_, sizeof(m_), "BLUEMIS: " __VA_ARGS__); \
	if (n_ > (int)sizeof(m_) - 1) n_ = sizeof(m_) - 1; \
	fputs(m_, stderr); \
	int c_ = open("/dev/console", O_WRONLY | O_NOCTTY); \
	if (c_ >= 0) { write(c_, m_, (size_t)n_); close(c_); } \
} while (0)

static uint32_t
be32(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* Signing info from the binary's own LC_CODE_SIGNATURE (thin arm64 only). NULL if none. */
static CFMutableDictionaryRef
info_from_binary(const char *bin)
{
	CFMutableDictionaryRef d = NULL;
	struct stat st;
	uint8_t *f = NULL;
	int fd = open(bin, O_RDONLY);

	if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64) ||
	    (f = malloc((size_t)st.st_size)) == NULL || read(fd, f, (size_t)st.st_size) != st.st_size) {
		LOG("can't read %s\n", bin);
		goto out;
	}
	const struct mach_header_64 *mh = (const void *)f;
	if (mh->magic != MH_MAGIC_64) {
		LOG("%s: not a thin 64-bit Mach-O (magic 0x%x)\n", bin, mh->magic);
		goto out;
	}
	const uint8_t *lc = f + sizeof(*mh), *end = lc + mh->sizeofcmds;
	const struct linkedit_data_command *cs = NULL;
	for (uint32_t i = 0; i < mh->ncmds && lc + sizeof(struct load_command) <= end; i++) {
		const struct load_command *l = (const void *)lc;
		if (l->cmd == LC_CODE_SIGNATURE)
			cs = (const void *)lc;
		lc += l->cmdsize;
	}
	if (cs == NULL || (uint64_t)cs->dataoff + cs->datasize > (uint64_t)st.st_size) {
		LOG("%s: no code signature\n", bin);
		goto out;
	}
	const uint8_t *sb = f + cs->dataoff;
	if (be32(sb) != 0xfade0cc0) {
		LOG("%s: bad SuperBlob\n", bin);
		goto out;
	}
	uint32_t count = be32(sb + 8);
	const uint8_t *cd = NULL, *ent = NULL;
	uint8_t cd_hash_type = 0;
	for (uint32_t i = 0; i < count && 12 + i * 8 + 8 <= cs->datasize; i++) {
		uint32_t type = be32(sb + 12 + i * 8), off = be32(sb + 16 + i * 8);
		if (off + 8 > cs->datasize)
			continue;
		const uint8_t *b = sb + off;
		if ((type == 0 || (type >= 0x1000 && type < 0x1005)) && be32(b) == 0xfade0c02 && off + 40 <= cs->datasize) {
			/* prefer the strongest hash: 1 SHA-1, 2 SHA-256 */
			if (cd == NULL || b[37] > cd_hash_type)
				cd = b, cd_hash_type = b[37];
		} else if (type == 5 && be32(b) == 0xfade7171) {
			ent = b;
		}
	}
	if (cd == NULL) {
		LOG("%s: no CodeDirectory\n", bin);
		goto out;
	}

	d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	uint32_t cd_len = be32(cd + 4), ident_off = be32(cd + 20);
	if (ident_off < cd_len) {
		CFStringRef id = CFStringCreateWithCString(NULL, (const char *)cd + ident_off, kCFStringEncodingUTF8);
		if (id != NULL) {
			CFDictionarySetValue(d, CFSTR("SigningID"), id);
			CFRelease(id);
		}
	}
	uint8_t h[CC_SHA256_DIGEST_LENGTH];
	if (cd_hash_type == 2)
		CC_SHA256(cd, cd_len, h);
	else
		CC_SHA1(cd, cd_len, h);
	CFDataRef cdhash = CFDataCreate(NULL, h, 20);          /* CDHash = first 20 bytes */
	CFDictionarySetValue(d, CFSTR("CdHash"), cdhash);
	CFRelease(cdhash);

	if (ent != NULL) {
		CFDataRef xml = CFDataCreate(NULL, ent + 8, be32(ent + 4) - 8);
		CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, xml, kCFPropertyListImmutable, NULL, NULL);
		CFRelease(xml);
		if (pl != NULL && CFGetTypeID(pl) == CFDictionaryGetTypeID()) {
			CFDictionarySetValue(d, CFSTR("Entitlements"), pl);
			const void *team = CFDictionaryGetValue(pl, CFSTR("com.apple.developer.team-identifier"));
			if (team != NULL)
				CFDictionarySetValue(d, CFSTR("TeamID"), team);
		}
		if (pl != NULL)
			CFRelease(pl);
	}
	int v;
	CFNumberRef n;
	v = 2;                          /* SignerType: 2 App Store, 3 developer (as AppSync) */
	n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFDictionarySetValue(d, CFSTR("SignerType"), n);
	CFRelease(n);
	v = 0x20100;
	n = CFNumberCreate(NULL, kCFNumberIntType, &v);
	CFDictionarySetValue(d, CFSTR("SignatureVersion"), n);
	CFRelease(n);
	CFDictionarySetValue(d, CFSTR("ValidatedByProfile"), kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("ValidatedByUniversalProfile"), kCFBooleanFalse);
	CFDictionarySetValue(d, CFSTR("ValidatedByLocalProfile"), kCFBooleanFalse);
	CFDateRef now = CFDateCreate(NULL, CFAbsoluteTimeGetCurrent());
	CFDictionarySetValue(d, CFSTR("SigningTime"), now);
	CFRelease(now);
	/* installd takes the signer identity from this certificate's subject: Apple's public
	 * 2008 "Apple iPhone OS Application Signing" leaf, as AppSync uses (it parses, so no
	 * Security hooks are needed) */
	CFDataRef cert = CFDataCreate(NULL, apple_iphone_os_application_signing_der,
	                              apple_iphone_os_application_signing_der_len);
	CFDictionarySetValue(d, CFSTR("SignerCertificate"), cert);
	CFRelease(cert);
out:
	free(f);
	if (fd >= 0)
		close(fd);
	return d;
}

/* PATH is the .app bundle or a bare executable. */
static char *
main_executable(CFStringRef path)
{
	char p[1024], bin[1280];
	struct stat st;

	if (!CFStringGetFileSystemRepresentation(path, p, sizeof(p)) || stat(p, &st) != 0)
		return NULL;
	if (!S_ISDIR(st.st_mode))
		return strdup(p);
	snprintf(bin, sizeof(bin), "%s/Info.plist", p);
	CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bin, (CFIndex)strlen(bin), false);
	CFReadStreamRef rs = u ? CFReadStreamCreateWithFile(NULL, u) : NULL;
	CFPropertyListRef pl = NULL;
	if (rs != NULL && CFReadStreamOpen(rs)) {
		pl = CFPropertyListCreateWithStream(NULL, rs, 0, kCFPropertyListImmutable, NULL, NULL);
		CFReadStreamClose(rs);
	}
	if (rs)
		CFRelease(rs);
	if (u)
		CFRelease(u);
	char *ret = NULL;
	if (pl != NULL && CFGetTypeID(pl) == CFDictionaryGetTypeID()) {
		CFStringRef exe = CFDictionaryGetValue(pl, CFSTR("CFBundleExecutable"));
		char e[256];
		if (exe != NULL && CFGetTypeID(exe) == CFStringGetTypeID() &&
		    CFStringGetCString(exe, e, sizeof(e), kCFStringEncodingUTF8)) {
			snprintf(bin, sizeof(bin), "%s/%s", p, e);
			ret = strdup(bin);
		}
	}
	if (pl)
		CFRelease(pl);
	return ret;
}

/* the real result R for PATH; a failure becomes 0 with our info */
static int
bluemis_fix(CFStringRef path, CFDictionaryRef *info, int r)
{
	char p[1024] = "?";

	CFStringGetFileSystemRepresentation(path, p, sizeof(p));
	LOG("validate %s -> 0x%x\n", p, r);

	if (r == 0)
		return 0;
	CFStringGetFileSystemRepresentation(path, p, sizeof(p));
	if (info == NULL) {
		LOG("%s: MIS 0x%x, no info wanted -> 0\n", p, r);
		return 0;
	}
	if (*info != NULL) {
		LOG("%s: MIS 0x%x with info -> 0\n", p, r);
		return 0;
	}
	char *bin = main_executable(path);
	CFMutableDictionaryRef d = bin ? info_from_binary(bin) : NULL;
	if (d == NULL) {
		LOG("%s: MIS 0x%x, no signature to read: left failing\n", p, r);
		free(bin);
		return r;
	}
	char id[256] = "-";
	CFStringRef sid = CFDictionaryGetValue(d, CFSTR("SigningID"));
	if (sid)
		CFStringGetCString(sid, id, sizeof(id), kCFStringEncodingUTF8);
	LOG("%s: MIS 0x%x -> 0 (ad-hoc: %s, %ld keys)\n", p, r, id, (long)CFDictionaryGetCount(d));
	free(bin);
	*info = d;
	return 0;
}

typedef int (*mis_progress_fn)(CFStringRef, CFDictionaryRef, CFDictionaryRef *, void *);
static mis_progress_fn original;        /* the trampoline: the moved prologue, then back */

static int
bluemis_validate_progress(CFStringRef path, CFDictionaryRef options, CFDictionaryRef *info, void *progress)
{
	return bluemis_fix(path, info, original(path, options, info, progress));
}

/*
 * The trampoline's code page: a whole 16 KiB page of brk #1 in its own section, so no
 * code that runs while it is being written (this file's) shares the page; making a
 * page RW takes away execute, and the first version died there (app6).
 */
__asm__(".section __TEXT,__bluetramp,regular,pure_instructions\n"
        ".p2align 14\n"
        "_bluemis_tramp:\n"
        ".fill 4096, 4, 0xd4200020\n"
        ".text\n");
extern char bluemis_tramp[] __asm__("_bluemis_tramp");

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

/* write N bytes of code at DST (shared cache or our __TEXT): private copy of the page(s) */
static bool
write_code(void *dst, const void *src, size_t n)
{
	vm_address_t a = (vm_address_t)dst & ~(vm_address_t)(vm_page_size - 1);
	vm_size_t len = (((vm_address_t)dst + n + vm_page_size - 1) & ~(vm_address_t)(vm_page_size - 1)) - a;
	kern_return_t kr = vm_protect(mach_task_self(), a, len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
	if (kr != KERN_SUCCESS) {
		LOG("vm_protect RW %p: %d\n", dst, kr);
		return false;
	}
	memcpy(dst, src, n);
	kr = vm_protect(mach_task_self(), a, len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
	sys_icache_invalidate(dst, n);
	if (kr != KERN_SUCCESS) {
		LOG("vm_protect RX %p: %d\n", dst, kr);
		return false;
	}
	return true;
}

static void
hook(void)
{
	uint32_t *t = (uint32_t *)(void *)MISValidateSignatureAndCopyInfoWithProgress;
	uint32_t code[8];

	for (int i = 0; i < 4; i++)
		if (pc_relative(t[i])) {
			LOG("WithProgress instruction %d (0x%08x) is PC-relative: not hooked\n", i, t[i]);
			return;
		}
	/* trampoline: the four instructions, then ldr x16, #8; br x16; .quad t + 4 */
	memcpy(code, t, 16);
	code[4] = 0x58000050;
	code[5] = 0xd61f0200;
	uint64_t back = (uint64_t)(t + 4);
	memcpy(&code[6], &back, 8);
	if (!write_code(bluemis_tramp, code, sizeof(code)))
		return;
	original = (mis_progress_fn)(void *)bluemis_tramp;
	/* entry: ldr x16, #8; br x16; .quad bluemis_validate_progress */
	uint32_t jump[4] = { 0x58000050, 0xd61f0200 };
	uint64_t to = (uint64_t)bluemis_validate_progress;
	memcpy(&jump[2], &to, 8);
	if (!write_code(t, jump, sizeof(jump))) {
		original = NULL;
		return;
	}
	LOG("hooked MISValidateSignatureAndCopyInfoWithProgress at %p\n", (void *)t);
}


/*
 * SpringBoard: FrontBoard refuses to launch an app whose signature it does not trust
 * ("invalid code signature, inadequate entitlements or its profile has not been
 * explicitly trusted", app12). The trust answers are replaced, when they say anything
 * else, by the trusted values AppSync Unified's FrontBoard part returns:
 * FBSSignatureValidationService -trustStateForApplication: 8, FBApplicationTrustData
 * -trustState and -trustStateWithTrustRequiredReasons: 2. Plain method replacement.
 */
typedef unsigned long (*trust_app_fn)(id, SEL, id);
typedef unsigned long (*trust_fn)(id, SEL);
typedef unsigned long (*trust_reasons_fn)(id, SEL, unsigned long *);
static trust_app_fn orig_trust_app;
static trust_fn orig_trust;
static trust_reasons_fn orig_trust_reasons;

static unsigned long
my_trust_app(id self, SEL sel, id app)
{
	unsigned long v = orig_trust_app(self, sel, app);
	if (v != 8)
		LOG("trustStateForApplication: %lu -> 8\n", v);
	return 8;
}

static unsigned long
my_trust(id self, SEL sel)
{
	unsigned long v = orig_trust(self, sel);
	if (v != 2)
		LOG("trustState: %lu -> 2\n", v);
	return 2;
}

static unsigned long
my_trust_reasons(id self, SEL sel, unsigned long *reasons)
{
	unsigned long v = orig_trust_reasons(self, sel, reasons);
	if (v != 2) {
		LOG("trustStateWithTrustRequiredReasons: %lu (reasons 0x%lx) -> 2\n", v, reasons ? *reasons : 0);
		if (reasons)
			*reasons = 0;
	}
	return 2;
}

static void *
replace(const char *cls, const char *sel, void *imp)
{
	Class c = objc_getClass(cls);
	Method m = c ? class_getInstanceMethod(c, sel_registerName(sel)) : NULL;
	if (m == NULL) {
		LOG("no -[%s %s]\n", cls, sel);
		return NULL;
	}
	LOG("replaced -[%s %s]\n", cls, sel);
	return (void *)method_setImplementation(m, (IMP)imp);
}

static void
trust_hooks(void)
{
	orig_trust_app = (trust_app_fn)replace("FBSSignatureValidationService", "trustStateForApplication:", (void *)my_trust_app);
	orig_trust = (trust_fn)replace("FBApplicationTrustData", "trustState", (void *)my_trust);
	orig_trust_reasons = (trust_reasons_fn)replace("FBApplicationTrustData", "trustStateWithTrustRequiredReasons:",
	                                               (void *)my_trust_reasons);
}

__attribute__((constructor)) static void
bluemis_init(void)
{
	char name[256] = "?";
	uint32_t len = sizeof(name);
	_NSGetExecutablePath(name, &len);
	LOG("loaded in %s[%d], libmis WithProgress at %p\n", name, getpid(),
	    (void *)MISValidateSignatureAndCopyInfoWithProgress);
	const char *base = strrchr(name, '/') ? strrchr(name, '/') + 1 : name;
	if (strcmp(base, "SpringBoard") == 0)
		trust_hooks();
	else
		hook();
}
