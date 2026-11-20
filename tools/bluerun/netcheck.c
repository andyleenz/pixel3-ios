/*
 * netcheck: what iOS makes of en0, every few seconds, for a Wi-Fi test boot.
 *
 *   netcheck [ROUNDS [SECONDS]]        (default 12 rounds, 10 s apart)
 *
 * Each round prints en0's flags and IPv4 addresses (getifaddrs), then the
 * configd store's keys about it: the network services set up for any
 * interface (Setup:/Network/Service/.../Interface, their device names) and
 * State:/Network/Interface/en0/... (link, IPv4) -- that is, whether configd
 * has a service for en0 at all, and whether IPConfiguration got an address.
 * Keys that carry a network's name (AirPort, SSID) are left out.
 *
 * SystemConfiguration is looked up at run time (tools/bluerun/build.sh links
 * CoreFoundation only).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef const void *store_t;
static store_t (*create)(CFAllocatorRef, CFStringRef, void *, void *);
static CFArrayRef (*keylist)(store_t, CFStringRef);
static CFPropertyListRef (*value)(store_t, CFStringRef);

static void
cfprint(const char *prefix, CFTypeRef thing)
{
	CFStringRef d = CFCopyDescription(thing);
	char buf[8192];

	if (d == NULL || !CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8)) {
		snprintf(buf, sizeof(buf), "(too long or not text)");
	}
	for (char *c = buf; *c; c++) {
		if (*c == '\n' || *c == '\t') {
			*c = ' ';
		}
	}
	printf("%s%s\n", prefix, buf);
	if (d != NULL) {
		CFRelease(d);
	}
}

static void
keys(store_t store, const char *pattern, bool values)
{
	CFStringRef p = CFStringCreateWithCString(NULL, pattern, kCFStringEncodingUTF8);
	CFArrayRef list = keylist(store, p);
	CFIndex n = list != NULL ? CFArrayGetCount(list) : 0;

	printf("  %ld keys match %s\n", (long)n, pattern);
	for (CFIndex i = 0; i < n && i < 24; i++) {
		CFStringRef key = CFArrayGetValueAtIndex(list, i);
		char k[256];

		CFStringGetCString(key, k, sizeof(k), kCFStringEncodingUTF8);
		if (strstr(k, "AirPort") != NULL || strstr(k, "SSID") != NULL) {
			continue;
		}
		if (values) {
			CFPropertyListRef v = value(store, key);
			char prefix[300];

			snprintf(prefix, sizeof(prefix), "    %s = ", k);
			if (v != NULL) {
				cfprint(prefix, v);
				CFRelease(v);
			} else {
				printf("%s(none)\n", prefix);
			}
		} else {
			printf("    %s\n", k);
		}
	}
	if (list != NULL) {
		CFRelease(list);
	}
	CFRelease(p);
}

/* a preferences file: its top-level keys, and for the interface list and services, each entry (no network names) */
static void
plist(const char *path)
{
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
	CFReadStreamRef in = CFReadStreamCreateWithFile(NULL, url);
	CFPropertyListRef p = NULL;

	if (in != NULL && CFReadStreamOpen(in)) {
		p = CFPropertyListCreateWithStream(NULL, in, 0, kCFPropertyListImmutable, NULL, NULL);
		CFReadStreamClose(in);
	}
	if (p == NULL || CFGetTypeID(p) != CFDictionaryGetTypeID()) {
		printf("  %s: %s\n", path, p == NULL ? "none or unreadable" : "not a dictionary");
	} else {
		CFIndex n = CFDictionaryGetCount(p);
		const void *k[64], *v[64];

		printf("  %s: %ld keys\n", path, (long)n);
		CFDictionaryGetKeysAndValues(p, k, v);
		for (CFIndex i = 0; i < n && i < 64; i++) {
			char key[128];

			CFStringGetCString(k[i], key, sizeof(key), kCFStringEncodingUTF8);
			if (strcmp(key, "Interfaces") == 0 || strcmp(key, "NetworkServices") == 0 || strcmp(key, "Sets") == 0 ||
			    strcmp(key, "CurrentSet") == 0 || strcmp(key, "Model") == 0) {
				char prefix[160];

				snprintf(prefix, sizeof(prefix), "    %s = ", key);
				cfprint(prefix, v[i]);
			} else {
				printf("    %s\n", key);
			}
		}
	}
	if (p != NULL) {
		CFRelease(p);
	}
	if (in != NULL) {
		CFRelease(in);
	}
	CFRelease(url);
}

int
main(int argc, char **argv)
{
	int rounds = argc > 1 ? atoi(argv[1]) : 12, gap = argc > 2 ? atoi(argv[2]) : 10;
	void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
	store_t store = NULL;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (sc != NULL) {
		create = (store_t (*)(CFAllocatorRef, CFStringRef, void *, void *))dlsym(sc, "SCDynamicStoreCreate");
		keylist = (CFArrayRef (*)(store_t, CFStringRef))dlsym(sc, "SCDynamicStoreCopyKeyList");
		value = (CFPropertyListRef (*)(store_t, CFStringRef))dlsym(sc, "SCDynamicStoreCopyValue");
	}
	if (create != NULL && keylist != NULL && value != NULL) {
		store = create(NULL, CFSTR("netcheck"), NULL, NULL);
	}
	printf("netcheck: SystemConfiguration %s, store %s\n", sc != NULL ? "loaded" : dlerror(), store != NULL ? "open" : "NOT open");
	for (int r = 1; r <= rounds; r++) {
		struct ifaddrs *list, *a;

		printf("round %d\n", r);
		if (getifaddrs(&list) == 0) {
			for (a = list; a != NULL; a = a->ifa_next) {
				if (strncmp(a->ifa_name, "en", 2) != 0 || a->ifa_addr == NULL) {
					continue;
				}
				if (a->ifa_addr->sa_family == AF_INET) {
					char ip[32];

					inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, ip, sizeof(ip));
					printf("  %s inet %s\n", a->ifa_name, ip);
				} else if (a->ifa_addr->sa_family == AF_LINK) {
					printf("  %s flags %#x%s%s\n", a->ifa_name, a->ifa_flags, (a->ifa_flags & IFF_UP) ? " UP" : " down",
					    (a->ifa_flags & IFF_RUNNING) ? " RUNNING" : "");
				}
			}
			freeifaddrs(list);
		}
		if (store != NULL) {
			keys(store, "Setup:/Network/Service/.*/Interface", true);
			keys(store, "State:/Network/Interface/en0/.*", true);
			keys(store, "State:/Network/Global/IPv4", true);
			if (r == 1 || r == 4) {
				keys(store, "Setup:/.*", false);
				keys(store, "Plugin:.*", true);
				keys(store, "State:/Network/Interface", true);
				keys(store, "State:/Network/Interface/.*/Link", true);
				plist("/private/var/preferences/SystemConfiguration/NetworkInterfaces.plist");
				plist("/private/var/preferences/SystemConfiguration/preferences.plist");
			}
		}
		if (r < rounds) {
			sleep((unsigned)gap);
		}
	}
	return 0;
}
