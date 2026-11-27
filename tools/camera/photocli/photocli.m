/*
 * photocli - one photograph through AVCapturePhotoOutput from the command line (bluesh run), as the Camera app takes
 * them, with every delegate callback and error printed:
 *
 *   photocli [jpeg|hevc] [OUT]     default jpeg, OUT /private/var/tmp/photocli.jpg (.heic for hevc)
 *
 * Runs a photo-preset session on the back camera, waits 3 s, captures, writes the file representation to OUT and
 * exits 0; exits 1 on an error and 2 after 30 s with no photo.
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#import <AVFoundation/AVFoundation.h>
#include <stdio.h>

@interface Shot : NSObject <AVCapturePhotoCaptureDelegate>
@property (copy) NSString *out;
@end

@implementation Shot
- (void)captureOutput:(AVCapturePhotoOutput *)o willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)r
{
	printf("will begin: %dx%d\n", r.photoDimensions.width, r.photoDimensions.height);
}
- (void)captureOutput:(AVCapturePhotoOutput *)o willCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)r
{
	printf("will capture\n");
}
- (void)captureOutput:(AVCapturePhotoOutput *)o didCapturePhotoForResolvedSettings:(AVCaptureResolvedPhotoSettings *)r
{
	printf("did capture\n");
}
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error
{
	NSData *d = [photo fileDataRepresentation];
	printf("did finish processing: error %s, %lu bytes\n", error ? error.description.UTF8String : "none", (unsigned long)d.length);
	if (d.length && [d writeToFile:self.out atomically:YES])
		printf("written %s\n", self.out.UTF8String);
	fflush(stdout);
}
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)r
    error:(NSError *)error
{
	printf("did finish capture: error %s\n", error ? error.description.UTF8String : "none");
	fflush(stdout);
	exit(error ? 1 : 0);
}
@end

int
main(int argc, char **argv)
{
	@autoreleasepool {
		BOOL hevc = argc > 1 && strcmp(argv[1], "hevc") == 0;
		Shot *shot = [Shot new];
		shot.out = argc > 2 ? @(argv[2]) : hevc ? @"/private/var/tmp/photocli.heic" : @"/private/var/tmp/photocli.jpg";
		setvbuf(stdout, NULL, _IOLBF, 0);
		AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
		printf("device: %s\n", dev ? dev.localizedName.UTF8String : "none");
		if (!dev)
			return 1;
		NSError *err = nil;
		AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
		if (!in) {
			printf("input: %s\n", err.description.UTF8String);
			return 1;
		}
		AVCaptureSession *s = [AVCaptureSession new];
		s.sessionPreset = AVCaptureSessionPresetPhoto;
		AVCapturePhotoOutput *po = [AVCapturePhotoOutput new];
		if (![s canAddInput:in] || ![s canAddOutput:po]) {
			printf("cannot add input or output\n");
			return 1;
		}
		[s addInput:in];
		[s addOutput:po];
		printf("codecs: %s\n", [[po.availablePhotoCodecTypes componentsJoinedByString:@" "] UTF8String]);
		[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:s queue:nil
		    usingBlock:^(NSNotification *n) { printf("session error: %s\n", [n.userInfo description].UTF8String); }];
		[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionWasInterruptedNotification object:s queue:nil
		    usingBlock:^(NSNotification *n) { printf("interrupted: %s\n", [n.userInfo description].UTF8String); }];
		printf("camera access: %ld (3 = authorised)\n", (long)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]);
		[s startRunning];
		printf("running: %d, interrupted %d\n", s.isRunning, s.isInterrupted);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			AVVideoCodecType c = hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeJPEG;
			if (![po.availablePhotoCodecTypes containsObject:c])
				printf("%s not offered; asking anyway\n", c.UTF8String);
			AVCapturePhotoSettings *ps = [AVCapturePhotoSettings photoSettingsWithFormat:@{ AVVideoCodecKey: c }];
			printf("capturing (%s)\n", c.UTF8String);
			[po capturePhotoWithSettings:ps delegate:shot];
		});
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			printf("timeout: no photo after 30 s\n");
			exit(2);
		});
		[[NSRunLoop mainRunLoop] run];
	}
	return 0;
}
