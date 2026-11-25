// BlueMetal.m - the Metal plugin for the Pixel 3's Adreno 630: /System/Library/Extensions/BlueMetal.bundle.
//
// iOS 16.7's Metal (MTLRegisterDevices, on the first MTLCreateSystemDefaultDevice/MTLCopyAllDevices of a process)
// matches every IOAcceleratorES service, loads /System/Library/Extensions/<MetalPluginName>.bundle, takes the class
// named by MetalPluginClassName (else the principal class), keeps it only if it subclasses _MTLDevice
// (getMetalPluginClassForService) and registers what -alloc/-initWithAcceleratorPort: returns (MTLAddDevice). The kernel's
// IOAcceleratorES (xnu patches 0107, 0215) names this bundle and BlueMetalDevice.
//
// Every process that touches Metal loads this bundle, CoreAnimation's included, so it stays small. Who gets a device:
//   - environment BLUE_METAL=1 (BLUE_METAL=0 refuses) decides first;
//   - then /usr/local/etc/bluemetal.procs, a name (getprogname) a line: NAME opts in, -NAME refuses;
//   - else apps: the executable of an .app bundle under /Applications or an installed app's container (not its
//     extensions). System daemons (backboardd composites on GL) stay off unless named.
// BLUE_METAL_LOG=1 logs (stderr and os_log) each new problem the frontend records, and every 5 s its status and texture
// counters when they changed.
// An opted-in process gets the native Metal frontend (UniXNU's AdrenoMetal over the metal2vulkan runtime on Turnip),
// loaded from /usr/lib/bluemetal.dylib only then.
//
// Copyright (c) 2026 pixel3-ios. MIT licence.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <pthread.h>
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
is_app(void)
{
	static const char *const roots[] = { "/Applications/", "/private/var/containers/Bundle/", "/var/containers/Bundle/",
		"/private/var/mobile/Containers/Bundle/", "/var/mobile/Containers/Bundle/" };
	char path[1024];
	uint32_t size = sizeof path;
	const char *app;
	// the app's own executable, not an extension inside it (widgets: memory limits too small for the stack)
	if (_NSGetExecutablePath(path, &size) != 0 || !(app = strstr(path, ".app/")) || strchr(app + 5, '/'))
		return 0;
	for (size_t i = 0; i < sizeof roots / sizeof roots[0]; i++)
		if (strncmp(path, roots[i], strlen(roots[i])) == 0)
			return 1;
	return 0;
}

static int
opted_in(void)
{
	const char *env = getenv("BLUE_METAL");
	if (env)
		return strcmp(env, "0") != 0;
	const char *me = getprogname();
	FILE *f = fopen(PROCS, "r");
	if (f) {
		char line[256];
		int verdict = -1;
		while (verdict < 0 && fgets(line, sizeof line, f)) {
			line[strcspn(line, "\r\n# \t")] = 0;
			if (line[0] == '-' && strcmp(line + 1, me) == 0)
				verdict = 0;
			else if (line[0] && strcmp(line, me) == 0)
				verdict = 1;
		}
		fclose(f);
		if (verdict >= 0)
			return verdict;
	}
	return is_app();
}

static void
say(const char *what, const char *text)
{
	os_log(OS_LOG_DEFAULT, "BlueMetal: %{public}s: %{public}s %{public}s", getprogname(), what, text);
	fprintf(stderr, "BlueMetal: %s: %s %s\n", getprogname(), what, text);
}

static void
problem(const char *text)
{
	say("problem:", text);
}

static size_t (*status_fn)(char *, size_t);
static size_t (*formats_fn)(char *, size_t);

static void *
status_loop(void *arg)
{
	(void)arg;
	char last[2][1024] = { "", "" }, now[1024];
	for (;;) {
		sleep(5);
		size_t (*fn[2])(char *, size_t) = { status_fn, formats_fn };
		for (int i = 0; i < 2; i++) {
			if (!fn[i])
				continue;
			now[0] = 0;
			fn[i](now, sizeof now);
			if (strcmp(now, last[i])) {
				say(i ? "textures" : "status", now);
				strlcpy(last[i], now, sizeof last[i]);
			}
		}
	}
	return NULL;
}

static void
start_log(void *lib)
{
	void (**hook)(const char *) = dlsym(lib, "native_bridge_metal_problem_hook");
	if (hook)
		*hook = problem;
	status_fn = (size_t (*)(char *, size_t))dlsym(lib, "native_bridge_metal_status");
	formats_fn = (size_t (*)(char *, size_t))dlsym(lib, "native_bridge_metal_formats");
	pthread_t t;
	if (pthread_create(&t, NULL, status_loop, NULL) == 0)
		pthread_detach(t);
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
	const char *log = getenv("BLUE_METAL_LOG");
	if (log && strcmp(log, "0"))
		start_log(lib);
	id device = open(TURNIP, cache, registry, NULL);
	os_log(OS_LOG_DEFAULT, "BlueMetal: %{public}s: device %{public}s", getprogname(), device ? "ready" : "refused");
	fprintf(stderr, "BlueMetal: %s: device %s\n", getprogname(), device ? "ready" : "refused");
	return device;
}
@end
