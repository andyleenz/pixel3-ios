/*
 * Why does installd's signature check fail? Runs the same checks by hand on
 * each bundle given and prints the raw results:
 *   - SecStaticCodeCheckValidityWithErrors (the Security framework status
 *     that libmis maps; 0xe8008001 is libmis's "unrecognized status")
 *   - MISValidateSignatureAndCopyInfo with no options and with options
 *     (installd uses AllowAdHocSigning+TrustCacheOnly for system apps; libmis
 *     then asks the AppleMobileFileIntegrity IOService, selector 6)
 *   - __mac_syscall("AMFI", 0x5f), libmis's "cdhash in trust cache?" query
 *
 *   mistest /Applications/MobileSafari.app /var/tmp/Calculator.app
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef const struct __SecCode *SecStaticCodeRef;
static OSStatus (*CreateWithPath)(CFURLRef, uint32_t, SecStaticCodeRef *);
static OSStatus (*CheckValidity)(SecStaticCodeRef, uint32_t, void *, CFErrorRef *);
static OSStatus (*CopySigningInfo)(SecStaticCodeRef, uint32_t, CFDictionaryRef *);
static int (*MISValidate)(CFStringRef, CFDictionaryRef, CFDictionaryRef *);
static int (*mac_syscall)(const char *, int, void *);

static void
show(const char *what, CFTypeRef obj)
{
	char buf[1024] = "";
	CFStringRef d = obj ? CFCopyDescription(obj) : NULL;
	if (d) {
		CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8);
		CFRelease(d);
	}
	printf("  %s: %s\n", what, buf);
}

static void
mis(const char *path, const char *opt)
{
	CFStringRef p = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
	CFMutableDictionaryRef o = CFDictionaryCreateMutable(NULL, 0,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	for (const char *q = opt; q && *q;) {	/* "A+B": several options */
		const char *e = strchr(q, '+');
		size_t n = e ? (size_t)(e - q) : strlen(q);
		CFStringRef k = CFStringCreateWithBytes(NULL, (const UInt8 *)q, (CFIndex)n,
		    kCFStringEncodingUTF8, false);
		CFDictionarySetValue(o, k, kCFBooleanTrue);
		CFRelease(k);
		q = e ? e + 1 : NULL;
	}
	CFDictionaryRef info = NULL;
	int r = MISValidate(p, o, &info);
	printf("  MIS %s: 0x%x\n", opt ? opt : "(no options)", r);
	if (info) {
		CFStringRef keys[] = { CFSTR("SignerType"), CFSTR("CdHash"), CFSTR("SigningID") };
		for (int i = 0; i < 3; i++) {
			CFTypeRef v = CFDictionaryGetValue(info, keys[i]);
			if (v) {
				show(i == 0 ? "    SignerType" : i == 1 ? "    CdHash" : "    SigningID", v);
			}
		}
		CFRelease(info);
	}
	CFRelease(o);
	CFRelease(p);
}

int
main(int argc, char **argv)
{
	void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
	void *lm = dlopen("/usr/lib/libmis.dylib", RTLD_NOW);
	CreateWithPath = dlsym(sec, "SecStaticCodeCreateWithPath");
	CheckValidity = dlsym(sec, "SecStaticCodeCheckValidityWithErrors");
	CopySigningInfo = dlsym(sec, "SecCodeCopySigningInformation");
	MISValidate = dlsym(lm, "MISValidateSignatureAndCopyInfo");
	mac_syscall = dlsym(RTLD_DEFAULT, "__mac_syscall");
	printf("mistest: sec %p lm %p create %p check %p mis %p mac %p\n", sec, lm,
	    (void *)CreateWithPath, (void *)CheckValidity, (void *)MISValidate, (void *)mac_syscall);
	if (!CreateWithPath || !CheckValidity || !MISValidate) {
		return 1;
	}
	for (int i = 1; i < argc; i++) {
		printf("%s\n", argv[i]);
		CFURLRef u = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[i],
		    strlen(argv[i]), true);
		SecStaticCodeRef code = NULL;
		OSStatus s = CreateWithPath(u, 0, &code);
		printf("  SecStaticCodeCreateWithPath: %d\n", (int)s);
		if (code) {
			uint32_t flags[] = { 0, 0x7 /* MIS's base flags, eq case */, 0x2001 };
			for (int f = 0; f < 3; f++) {
				CFErrorRef err = NULL;
				s = CheckValidity(code, flags[f], NULL, &err);
				printf("  CheckValidity(0x%x): %d\n", flags[f], (int)s);
				if (err) {
					show("    error", err);
					CFRelease(err);
				}
			}
			CFDictionaryRef si = NULL;
			if (CopySigningInfo && CopySigningInfo(code, 0, &si) == 0 && si) {
				CFTypeRef h = CFDictionaryGetValue(si, CFSTR("unique"));
				show("cdhash", h);
				if (h && mac_syscall && CFDataGetLength(h) >= 20) {
					struct { uint8_t h[20]; uint32_t pad; uint64_t out; } q = { .out = 0 };
					memcpy(q.h, CFDataGetBytePtr(h), 20);
					int r = mac_syscall("AMFI", 0x5f, &q);
					printf("  AMFI 0x5f: %d errno %d out 0x%llx\n", r, r ? errno : 0,
					    (unsigned long long)q.out);
				}
				CFRelease(si);
			}
			CFRelease(code);
		}
		CFRelease(u);
		mis(argv[i], NULL);
		mis(argv[i], "ValidateSignatureOnly");
		mis(argv[i], "TrustCacheOnly");
		mis(argv[i], "AllowAdHocSigning");
		mis(argv[i], "AllowAdHocSigning+TrustCacheOnly");	/* installd, system apps */
	}
	return 0;
}
