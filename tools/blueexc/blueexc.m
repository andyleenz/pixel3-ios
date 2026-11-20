/*
 * blueexc.dylib: logs every Objective-C exception a process throws, with its
 * name, reason and the stack where it was thrown. Crash reports cannot be read
 * on the phone, and an uncaught exception's abort shows only where it was
 * rethrown. Insert it with
 *   sweetenv=PROC:DYLD_INSERT_LIBRARIES=/usr/lib/blueexc.dylib sweetnull=PROC
 * (stderr of a launchd job is /dev/null; sweetnull copies it into the log)
 * and push it with phonetest --push tools/blueexc/out/blueexc.dylib:/usr/lib/blueexc.dylib.
 * Addresses are printed raw; the shared cache slide is on the kernel's CRASH line.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <objc/objc-exception.h>
#include <stdio.h>

static objc_exception_preprocessor previous;
static int count;

static id
log_exception(id exception)
{
	if (count++ < 20 && [exception isKindOfClass:[NSException class]]) {
		NSException *e = exception;
		void *pcs[24];
		int n = backtrace(pcs, 24);

		fprintf(stderr, "BLUEEXC: %s: %s\n", [[e name] UTF8String] ?: "?",
		    [[[e reason] description] UTF8String] ?: "(no reason)");
		for (int i = 1; i < n; i++) {
			Dl_info info;
			if (dladdr(pcs[i], &info) && info.dli_sname != NULL) {
				fprintf(stderr, "BLUEEXC:   %p %s + %ld\n", pcs[i], info.dli_sname,
				    (long)((char *)pcs[i] - (char *)info.dli_saddr));
			} else {
				fprintf(stderr, "BLUEEXC:   %p\n", pcs[i]);
			}
		}
		fflush(stderr);
	}
	return previous != NULL ? previous(exception) : exception;
}

__attribute__((constructor)) static void
install(void)
{
	previous = objc_setExceptionPreprocessor(log_exception);
}
