// BlueMetal.m - the Metal plugin for the Pixel 3's Adreno 630: /System/Library/Extensions/BlueMetal.bundle.
//
// iOS 16.7's Metal (MTLRegisterDevices, on the first MTLCreateSystemDefaultDevice/MTLCopyAllDevices of a process)
// matches every IOAcceleratorES service, loads /System/Library/Extensions/<MetalPluginName>.bundle, takes the class
// named by MetalPluginClassName (else the principal class), keeps it only if it subclasses _MTLDevice
// (getMetalPluginClassForService) and registers what -alloc/-initWithAcceleratorPort: returns (MTLAddDevice). The kernel's
// IOAcceleratorES (xnu patches 0107, 0215) names this bundle and BlueMetalDevice.
//
// Every process that touches Metal loads this bundle, CoreAnimation's included, so it stays small and answers nil
// unless the process opts in:
//   - environment BLUE_METAL=1 (BLUE_METAL=0 refuses), or
//   - its name (getprogname) on a line of /usr/local/etc/bluemetal.procs.
// An opted-in process gets the native Metal frontend (UniXNU's AdrenoMetal over the metal2vulkan runtime on Turnip),
// loaded from /usr/lib/bluemetal.dylib only then.
//
// Copyright (c) 2026 pixel3-ios. MIT licence.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <os/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define FRONTEND "/usr/lib/bluemetal.dylib"
#define TURNIP "/usr/lib/bluevk.dylib"
#define PROCS "/usr/local/etc/bluemetal.procs"

extern int IORegistryEntryGetRegistryEntryID(unsigned entry, uint64_t *id);

static int
opted_in(void)
{
	const char *env = getenv("BLUE_METAL");
	if (env)
		return strcmp(env, "0") != 0;
	FILE *f = fopen(PROCS, "r");
	if (!f)
		return 0;
	const char *me = getprogname();
	char line[256];
	int yes = 0;
	while (!yes && fgets(line, sizeof line, f)) {
		line[strcspn(line, "\r\n# \t")] = 0;
		yes = line[0] && strcmp(line, me) == 0;
	}
	fclose(f);
	return yes;
}

@interface _MTLDevice : NSObject
@end

// only a key into Metal's discovery: init answers the frontend's device (or nil), never this object
@interface BlueMetalDevice : _MTLDevice
- (id)initWithAcceleratorPort:(unsigned)port;
@end

@implementation BlueMetalDevice
// Metal calls [[cls alloc] initWithAcceleratorPort:]. init answers another object, so ARC releases the allocated one, and
// -[_MTLDevice dealloc] on an instance _MTLDevice's init never set up crashes (dispatch_release of a NULL queue). alloc
// answers one placeholder kept here for good, so that release never deallocates it.
+ (id)allocWithZone:(struct _NSZone *)zone
{
	static id placeholder;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		placeholder = [super allocWithZone:zone];
	});
	return placeholder;
}

- (id)initWithAcceleratorPort:(unsigned)port
{
	if (!opted_in())
		return nil;
	void *lib = dlopen(FRONTEND, RTLD_NOW | RTLD_LOCAL);
	id (*open)(const char *, const char *, uint64_t, void (*)(const char *, const char *)) =
	    lib ? dlsym(lib, "native_bridge_metal_open") : NULL;
	if (!open) {
		os_log_error(OS_LOG_DEFAULT, "BlueMetal: %{public}s: %{public}s", FRONTEND, dlerror());
		fprintf(stderr, "BlueMetal: %s: %s\n", FRONTEND, dlerror());
		return nil;
	}
	uint64_t registry = 0;
	IORegistryEntryGetRegistryEntryID(port, &registry);
	char cache[96];
	snprintf(cache, sizeof cache, "/private/var/tmp/bluemetal-%u", getuid());
	mkdir(cache, 0700);
	id device = open(TURNIP, cache, registry, NULL);
	os_log(OS_LOG_DEFAULT, "BlueMetal: %{public}s: device %{public}s", getprogname(), device ? "ready" : "refused");
	fprintf(stderr, "BlueMetal: %s: device %s\n", getprogname(), device ? "ready" : "refused");
	return device;
}
@end
