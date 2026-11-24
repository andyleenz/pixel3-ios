/*
 * blueps: which processes use the CPU (iOS has no ps or top). Samples every
 * process's user + system time every 250 ms for SECONDS (default 10) and
 * prints the busiest: CPU % of one core over the window, and how many pids
 * with that name came and went (a crash loop shows as many). Processes that
 * live less than one sample are not seen.
 *
 *   tools/bluesh.py run -t 40 /usr/local/bin/blueps [SECONDS]
 */
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* libproc and sys/proc_info.h are not in the iPhoneOS SDK */
struct proc_taskinfo {
	uint64_t pti_virtual_size, pti_resident_size;
	uint64_t pti_total_user, pti_total_system;
	uint64_t pti_threads_user, pti_threads_system;
	int32_t pti_policy, pti_faults, pti_pageins, pti_cow_faults;
	int32_t pti_messages_sent, pti_messages_received;
	int32_t pti_syscalls_mach, pti_syscalls_unix, pti_csw;
	int32_t pti_threadnum, pti_numrunning, pti_priority;
};
#define PROC_PIDTASKINFO 4
int proc_listallpids(void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);

#define MAXP 4096
struct ent {
	int pid;
	char name[64];
	uint64_t first, last;	/* CPU time (mach units) at first and last sample */
	int seen_at_start;
	int wakes0, wakes;
};
static struct ent ents[MAXP];
static int nents;

struct row {
	char name[64];
	uint64_t cpu;
	int pids, csw;
};

static void
sample(int start)
{
	static int pids[MAXP];
	int n = proc_listallpids(pids, sizeof(pids)) ;
	for (int i = 0; i < n && i < MAXP; i++) {
		struct proc_taskinfo ti;
		if (proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) != (int)sizeof(ti)) {
			continue;
		}
		uint64_t t = ti.pti_total_user + ti.pti_total_system;
		struct ent *e = NULL;
		for (int j = 0; j < nents; j++) {
			if (ents[j].pid == pids[i]) {
				e = &ents[j];
				break;
			}
		}
		if (e == NULL) {
			if (nents == MAXP) {
				continue;
			}
			e = &ents[nents++];
			e->pid = pids[i];
			if (proc_name(pids[i], e->name, sizeof(e->name)) <= 0) {
				snprintf(e->name, sizeof(e->name), pids[i] == 0 ? "kernel_task" : "pid%d", pids[i]);
			}
			e->seen_at_start = start;
			e->first = start ? t : 0;
			e->wakes0 = start ? ti.pti_csw : 0;
		}
		e->last = t;
		e->wakes = ti.pti_csw;
	}
}

static int
cmp(const void *a, const void *b)
{
	const struct row *x = a, *y = b;
	return x->cpu < y->cpu ? 1 : x->cpu > y->cpu ? -1 : 0;
}

int
main(int argc, char **argv)
{
	int secs = argc > 1 ? atoi(argv[1]) : 10;
	if (secs < 1) {
		secs = 10;
	}
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	uint64_t t0 = mach_absolute_time();
	sample(1);
	for (int i = 0; i < secs * 4; i++) {
		usleep(250000);
		sample(0);
	}
	uint64_t wall = mach_absolute_time() - t0;
	static struct row rows[MAXP];
	int nr = 0;
	uint64_t total = 0;
	for (int j = 0; j < nents; j++) {
		struct ent *e = &ents[j];
		uint64_t d = e->last - e->first;
		total += d;
		int k;
		for (k = 0; k < nr; k++) {
			if (strcmp(rows[k].name, e->name) == 0) {
				break;
			}
		}
		if (k == nr) {
			strlcpy(rows[nr++].name, e->name, sizeof(rows[0].name));
		}
		rows[k].cpu += d;
		rows[k].csw += e->wakes - e->wakes0;
		if (!e->seen_at_start) {
			rows[k].pids++;
		}
	}
	qsort(rows, nr, sizeof(rows[0]), cmp);
	printf("%d s, %d processes seen, all together %.1f%% of one core (timebase %u/%u)\n", secs, nents,
	    100.0 * total / wall, tb.numer, tb.denom);
	printf("  %%core  new  csw/s  name\n");
	for (int k = 0; k < nr && k < 30; k++) {
		if (rows[k].cpu * 1000 < wall && !rows[k].pids) {
			break;
		}
		printf("  %5.1f  %3d  %5d  %s\n", 100.0 * rows[k].cpu / wall, rows[k].pids, rows[k].csw / secs,
		    rows[k].name);
	}
	return 0;
}
