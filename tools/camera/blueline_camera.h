/*
 * /dev/blueline-camera: the rear IMX363's frames for user space (patch 0233, bsd/dev/blueline_camera_probe.c).
 * Copy of the kernel's bsd/sys/blueline_camera.h (xnu/patches/0233): keep the two the same.
 *
 * The ABI is ios-redfin's /dev/redwood-camera (sys/redwood_camera.h, MIT, github.com/DenialOfGravity/ios-redfin)
 * with the prefix BLUELINE_CAMERA_ and the magic "BLFRAME1": the same structure layouts and command numbers.
 *
 *   open()   the first one powers the rear camera up and starts its frames (2016x1512 RAW10, 2x2 binned);
 *            the last close stops them and powers it down.
 *   read()   waits (at most 1 s, else EAGAIN) for the newest frame not read yet: a struct
 *            blueline_camera_frame, then as many of the frame's bytes as the buffer has room for.
 *            A buffer of at most the header's size gets the header only (the frame stays unread).
 *            EIO when the camera failed to start or stopped delivering: until the last close.
 *   write()  commands: a struct blueline_camera_command, then what it says follows.
 *            EXPOSURE is taken; SENSOR 1 (the rear) and FORMAT RAW10 are accepted and change nothing;
 *            FOCUS is accepted and ignored (focus reads NO_FOCUS); the others return ENOTSUP.
 */
#ifndef _SYS_BLUELINE_CAMERA_H_
#define _SYS_BLUELINE_CAMERA_H_

#include <stdint.h>

#define BLUELINE_CAMERA_DEVICE          "/dev/blueline-camera"
#define BLUELINE_CAMERA_MAGIC           "BLFRAME1"

struct blueline_camera_frame {
	char            magic[8];       /* BLUELINE_CAMERA_MAGIC */
	uint32_t        header_bytes;   /* this structure's size: the frame's bytes follow */
	uint32_t        width, height;  /* pixels */
	uint32_t        stride;         /* bytes from one line to the next */
	uint32_t        format;         /* 1: MIPI RAW10, four pixels in five bytes */
	uint32_t        bayer;          /* the order of a 2x2 cell: 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR */
	uint32_t        black;          /* the black level, in 10-bit steps */
	uint64_t        sequence;       /* the frame's number since the sensor started, from 1 */
	uint64_t        time;           /* when the frame was done, in mach_absolute_time() units */
	uint32_t        exposure_lines; /* the exposure it was taken with, in lines ... */
	uint32_t        line_ns;        /* ... of this many nanoseconds */
	uint32_t        gain;           /* analog gain, linear: gain_unity is 1x */
	uint32_t        gain_unity;
	uint32_t        gain_max;
	uint32_t        frame_lines;    /* the frame's length in lines (frames a second: 1e9 / (frame_lines * line_ns)) */
	uint32_t        frame_lines_min; /* the mode's own length: the shortest frame */
	uint32_t        frame_lines_max;
	uint32_t        margin;         /* exposure_lines is at most frame_lines - margin */
	uint32_t        sensor;         /* 0 macro, 1 wide (rear), 2 front, 3 ultra-wide: always 1 here */
	uint32_t        focus;          /* BLUELINE_CAMERA_NO_FOCUS: no lens motor driver */
	uint32_t        reserved[5];    /* by BLUELINE_CAMERA_R_* */
};

#define BLUELINE_CAMERA_NO_FOCUS        0xffffffffu
#define BLUELINE_CAMERA_FOCUS_MAX       1023u

#define BLUELINE_CAMERA_R_FLAGS         0       /* BLUELINE_CAMERA_FLAG_* */
#define BLUELINE_CAMERA_R_SOF_LO        1       /* (0 here) */
#define BLUELINE_CAMERA_R_SOF_HI        2       /* (0 here) */
#define BLUELINE_CAMERA_R_DGAIN         3       /* digital gain unity | max << 16; 0: none */
#define BLUELINE_CAMERA_R_FPS_MILLI     4       /* the mode's frames a second x 1000 */
#define BLUELINE_CAMERA_FLAG_FLASH_LIT  (1u << 0)
#define BLUELINE_CAMERA_FLAG_LENS_MOVING (1u << 1)
#define BLUELINE_CAMERA_FLAG_MODE_CHANGED (1u << 2)     /* the first frame read after the sensor started */

enum {
	BLUELINE_CAMERA_EXPOSURE = 1,   /* a: lines, b: gain (linear), c: frame lines (0: the shortest that holds the exposure) */
	BLUELINE_CAMERA_KEEP = 2,       /* (ENOTSUP) */
	BLUELINE_CAMERA_SENSOR = 3,     /* a: which (as the header's sensor): 1 only */
	BLUELINE_CAMERA_FOCUS = 4,      /* (ignored) */
	BLUELINE_CAMERA_FLASH = 5,      /* (ENOTSUP) */
	BLUELINE_CAMERA_FORMAT = 6,     /* a: BLUELINE_CAMERA_FORMAT_RAW10 only */
	BLUELINE_CAMERA_COLOUR = 7,     /* (ENOTSUP) */
};
enum { BLUELINE_CAMERA_FORMAT_RAW10 = 1, BLUELINE_CAMERA_FORMAT_NV12 = 2 };

struct blueline_camera_command {
	uint32_t        command;
	uint32_t        bytes;          /* of what follows this structure */
	uint32_t        a, b, c, d;
};

#endif /* _SYS_BLUELINE_CAMERA_H_ */
