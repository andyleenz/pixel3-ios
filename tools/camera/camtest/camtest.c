/*
 * camtest: read frames from /dev/blueline-camera (kernel patch 0233) and print what came.
 *
 *   camtest [FRAMES [LINES GAIN [FRAME_LINES]]]
 *
 * FRAMES (default 30) frames are read; with LINES and GAIN an EXPOSURE command is sent after the
 * first frame (GAIN linear, 256 = 1x). Each frame: size, sequence, interval and fps from the
 * header's mach time, the centre row's mean (10-bit, before black level), how long read() took.
 * Lines go to the console through kern.bluesay ("SAY camtest[pid]: ...") and, on a terminal, to
 * stdout. Exit 0 when all frames came with rising sequence numbers.
 */
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include "../blueline_camera.h"

static void
say(const char *fmt, ...)
{
	char line[400];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	sysctlbyname("kern.bluesay", NULL, NULL, line, strlen(line));
	if (isatty(1)) {
		printf("%s\n", line);
	}
}

static double
ms(uint64_t ticks)
{
	static mach_timebase_info_data_t tb;
	if (tb.denom == 0) {
		mach_timebase_info(&tb);
	}
	return (double)ticks * tb.numer / tb.denom / 1e6;
}

/* RAW10, MIPI packed: 4 pixels in 5 bytes, high 8 bits each, then the 4 low 2-bit pairs */
static double
row_mean(const uint8_t *row, uint32_t width)
{
	uint64_t sum = 0;
	for (uint32_t x = 0; x < width; x++) {
		const uint8_t *g = row + (x >> 2) * 5;
		sum += (uint32_t)g[x & 3] << 2 | (g[4] >> ((x & 3) * 2) & 3);
	}
	return width ? (double)sum / width : 0;
}

int
main(int argc, char **argv)
{
	int frames = argc > 1 ? atoi(argv[1]) : 30;
	struct blueline_camera_command ex = { BLUELINE_CAMERA_EXPOSURE, 0, 0, 0, 0, 0 };
	int want_ex = argc > 3;
	if (want_ex) {
		ex.a = (uint32_t)strtoul(argv[2], NULL, 0);
		ex.b = (uint32_t)strtoul(argv[3], NULL, 0);
		ex.c = argc > 4 ? (uint32_t)strtoul(argv[4], NULL, 0) : 0;
	}
	if (frames < 1) {
		frames = 1;
	}

	uint64_t t0 = mach_absolute_time();
	int fd = open(BLUELINE_CAMERA_DEVICE, O_RDWR);
	if (fd < 0) {
		say("open %s: %s", BLUELINE_CAMERA_DEVICE, strerror(errno));
		return 1;
	}
	say("opened %s in %.1f ms; reading %d frames", BLUELINE_CAMERA_DEVICE, ms(mach_absolute_time() - t0), frames);

	/* the header alone: learns the size (the first frame may take a few EAGAINs while the sensor starts) */
	struct blueline_camera_frame h;
	ssize_t n = -1;
	for (int tries = 0; tries < 8; tries++) {
		n = read(fd, &h, sizeof(h));
		if (n >= 0 || errno != EAGAIN) {
			break;
		}
		say("header: EAGAIN (%d)", tries + 1);
	}
	if (n != (ssize_t)sizeof(h) || memcmp(h.magic, BLUELINE_CAMERA_MAGIC, 8) != 0) {
		say("header read: %zd bytes, %s", n, n < 0 ? strerror(errno) : "bad magic");
		close(fd);
		return 1;
	}
	size_t frame_bytes = (size_t)h.stride * h.height;
	say("first frame %.1f ms after open: %ux%u stride %u format %u bayer %u black %u; %zu bytes; exposure %u lines "
	    "of %u ns, gain %u/%u (max %u), frame %u lines (min %u), fps x1000 %u, flags 0x%x",
	    ms(mach_absolute_time() - t0), h.width, h.height, h.stride, h.format, h.bayer, h.black, frame_bytes,
	    h.exposure_lines, h.line_ns, h.gain, h.gain_unity, h.gain_max, h.frame_lines, h.frame_lines_min,
	    h.reserved[BLUELINE_CAMERA_R_FPS_MILLI], h.reserved[BLUELINE_CAMERA_R_FLAGS]);

	size_t size = h.header_bytes + frame_bytes;
	uint8_t *buf = malloc(size);
	if (!buf) {
		say("no memory for %zu bytes", size);
		close(fd);
		return 1;
	}
	uint64_t last_seq = 0, first_time = 0, last_time = 0, first_seq = 0;
	int good = 0, again = 0, repeats = 0;
	uint64_t *hashes = calloc((size_t)frames, sizeof(uint64_t));
	for (int i = 0; i < frames;) {
		uint64_t r0 = mach_absolute_time();
		n = read(fd, buf, size);
		uint64_t r1 = mach_absolute_time();
		if (n < 0) {
			if (errno == EAGAIN && ++again < 8) {
				say("frame %d: EAGAIN", i + 1);
				continue;
			}
			say("frame %d: read: %s", i + 1, strerror(errno));
			break;
		}
		const struct blueline_camera_frame *f = (const struct blueline_camera_frame *)buf;
		if ((size_t)n < sizeof(*f) || memcmp(f->magic, BLUELINE_CAMERA_MAGIC, 8) != 0) {
			say("frame %d: %zd bytes, bad header", i + 1, n);
			break;
		}
		const uint8_t *pix = buf + f->header_bytes;
		double mean = (size_t)n >= f->header_bytes + (size_t)f->stride * (f->height / 2 + 1)
		    ? row_mean(pix + (size_t)f->stride * (f->height / 2), f->width) : -1;
		double dt = last_time ? ms(f->time - last_time) : 0;
		/* FNV-1a of the pixels: a frame whose bytes equal an earlier one's is old data handed out again */
		uint64_t hv = 1469598103934665603ull;
		for (size_t k = 0; k + f->header_bytes < (size_t)n; k++)
			hv = (hv ^ pix[k]) * 1099511628211ull;
		int same = -1;
		for (int j = 0; j < i && same < 0; j++)
			if (hashes[j] == hv)
				same = j + 1;
		hashes[i] = hv;
		repeats += same > 0;
		char sametext[40] = "";
		if (same > 0)
			snprintf(sametext, sizeof(sametext), ", SAME PIXELS AS FRAME %d", same);
		say("frame %d: %zd bytes, seq %llu%s, +%.1f ms (%.1f fps), centre row mean %.1f, exposure %u gain %u frame %u, "
		    "read %.1f ms, hash %016llx%s", i + 1, n, f->sequence, last_seq && f->sequence != last_seq + 1 ? " (skipped some)" : "", dt,
		    dt > 0 ? 1000.0 / dt * (double)(f->sequence - last_seq) : 0, mean, f->exposure_lines, f->gain,
		    f->frame_lines, ms(r1 - r0), (unsigned long long)hv, sametext);
		if (f->sequence > last_seq && (size_t)n == size) {
			good++;
		}
		if (!first_time) {
			first_time = f->time;
			first_seq = f->sequence;
		}
		last_seq = f->sequence;
		last_time = f->time;
		i++;
		if (i == 1 && want_ex) {
			if (write(fd, &ex, sizeof(ex)) != (ssize_t)sizeof(ex)) {
				say("EXPOSURE %u lines gain %u frame %u: %s", ex.a, ex.b, ex.c, strerror(errno));
			} else {
				say("EXPOSURE %u lines gain %u frame %u sent", ex.a, ex.b, ex.c);
			}
		}
	}
	double span = ms(last_time - first_time);
	say("done: %d of %d frames whole and in order; sensor frames %llu-%llu, %.1f fps over %.0f ms", good, frames,
	    first_seq, last_seq, span > 0 ? 1000.0 * (double)(last_seq - first_seq) / span : 0, span);
	free(buf);
	t0 = mach_absolute_time();
	close(fd);
	say("closed in %.1f ms; %d frame(s) repeated an earlier frame's pixels", ms(mach_absolute_time() - t0), repeats);
	return good == frames ? 0 : 1;
}
