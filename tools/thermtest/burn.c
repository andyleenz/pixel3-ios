/*
 * burn - CPU load for thermal tests: N threads (default 8) spin on floating point for SECS seconds
 * (default 300), then print the loop count per thread (throughput falls as the CPUs are throttled).
 *
 *   burn [SECS] [THREADS]
 *
 * Copyright (c) 2026 pixel3-ios. MIT licence.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int secs = 300;
static volatile int stop;

static void *
spin(void *arg)
{
	volatile unsigned long *count = arg;	/* volatile: else kept in a register until the end */
	double x = 1.0001;
	while (!stop) {
		for (int i = 0; i < 100000; i++)
			x = x * 1.0000001 + 0.0000001;
		(*count)++;
	}
	return (void *)(long)(x > 0);
}

int
main(int argc, char **argv)
{
	int n = argc > 2 ? atoi(argv[2]) : 8;
	secs = argc > 1 ? atoi(argv[1]) : 300;
	if (n < 1 || n > 64)
		n = 8;
	pthread_t t[64];
	unsigned long c[64] = {0}, last = 0;
	for (int i = 0; i < n; i++)
		pthread_create(&t[i], NULL, spin, &c[i]);
	for (int s = 1; s <= secs; s++) {
		struct timespec ts = {1, 0};
		nanosleep(&ts, NULL);
		if (s % 30 == 0) {
			unsigned long sum = 0;
			for (int i = 0; i < n; i++)
				sum += c[i];
			printf("burn %4ds: %lu loops/s\n", s, (sum - last) / 30);
			fflush(stdout);
			last = sum;
		}
	}
	stop = 1;
	for (int i = 0; i < n; i++)
		pthread_join(t[i], NULL);
	return 0;
}
