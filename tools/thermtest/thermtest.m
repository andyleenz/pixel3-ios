/*
 * thermtest - the temperature sensors as thermalmonitord sees them (kernel patch 0235, bluethermal=1).
 *
 * Lists the HID services with usage pair (0xFF00, 0x05) through an IOHIDEventSystemClient, reads each one's
 * temperature event, then prints the thermal pressure level (notify "com.apple.system.thermalpressurelevel")
 * and NSProcessInfo's thermal state, every SECS seconds, N times (default 3 x 10 s).
 * Lines go to the console through kern.bluesay ("SAY thermtest[pid]: ...").
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <Foundation/Foundation.h>
#include <notify.h>
#include <stdarg.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
int proc_listallpids(void *buffer, int buffersize);	/* libproc.h is not in the iOS SDK */
int proc_name(int pid, void *buffer, uint32_t buffersize);

static int
find_proc(const char *want)
{
	int pids[2048], n = proc_listallpids(pids, sizeof(pids)) ;
	for (int i = 0; i < n; i++) {
		char name[64] = "";
		proc_name(pids[i], name, sizeof(name));
		if (!strcmp(name, want))
			return pids[i];
	}
	return -1;
}

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
#define kIOHIDEventTypeTemperature 15
#define kIOHIDEventFieldTemperatureLevel (kIOHIDEventTypeTemperature << 16)

static void
say(const char *fmt, ...)
{
	char line[900];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	sysctlbyname("kern.bluesay", NULL, NULL, line, strlen(line));
	if (isatty(1))
		printf("%s\n", line);
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		int rounds = argc > 1 ? atoi(argv[1]) : 3, secs = argc > 2 ? atoi(argv[2]) : 10;
		void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
		IOHIDEventSystemClientRef (*create)(CFAllocatorRef) = dlsym(io, "IOHIDEventSystemClientCreate");
		void (*setMatching)(IOHIDEventSystemClientRef, CFDictionaryRef) = dlsym(io, "IOHIDEventSystemClientSetMatching");
		CFArrayRef (*copyServices)(IOHIDEventSystemClientRef) = dlsym(io, "IOHIDEventSystemClientCopyServices");
		CFTypeRef (*copyProp)(IOHIDServiceClientRef, CFStringRef) = dlsym(io, "IOHIDServiceClientCopyProperty");
		IOHIDEventRef (*copyEvent)(IOHIDServiceClientRef, int64_t, int32_t, int64_t) = dlsym(io, "IOHIDServiceClientCopyEvent");
		double (*getFloat)(IOHIDEventRef, int32_t) = dlsym(io, "IOHIDEventGetFloatValue");
		if (!create || !setMatching || !copyServices || !copyProp || !copyEvent || !getFloat) {
			say("IOHID symbols missing");
			return 1;
		}
		IOHIDEventSystemClientRef c = create(kCFAllocatorDefault);
		setMatching(c, (__bridge CFDictionaryRef)@{ @"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @5 });
		int tok = -1;
		notify_register_check("com.apple.system.thermalpressurelevel", &tok);
		for (int r = 0; r < rounds; r++) {
			NSArray *svcs = CFBridgingRelease(copyServices(c));
			NSMutableString *line = [NSMutableString stringWithFormat:@"%lu services:", (unsigned long)svcs.count];
			for (id s in svcs) {
				NSString *name = CFBridgingRelease(copyProp((__bridge IOHIDServiceClientRef)s, CFSTR("Product")));
				IOHIDEventRef e = copyEvent((__bridge IOHIDServiceClientRef)s, kIOHIDEventTypeTemperature, 0, 0);
				if (e) {
					[line appendFormat:@" %@ %.1f;", name, getFloat(e, kIOHIDEventFieldTemperatureLevel)];
					CFRelease(e);
				} else
					[line appendFormat:@" %@ -;", name];
			}
			uint64_t level = 0;
			if (tok >= 0)
				notify_get_state(tok, &level);
			say("round %d: thermalmonitord pid %d, pressure level %llu, thermal state %ld", r, find_proc("thermalmonitord"),
			    level, (long)NSProcessInfo.processInfo.thermalState);
			for (NSUInteger o = 0; o < line.length; o += 200)
				say("  %s", [line substringWithRange:NSMakeRange(o, MIN((NSUInteger)200, line.length - o))].UTF8String);
			if (r + 1 < rounds)
				sleep(secs);
		}
	}
	return 0;
}
