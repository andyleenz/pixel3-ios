#!/usr/bin/env python3
"""Frame gaps from eagl's timeline lines ("BLUEEAGL: tl: g N began US ended US ...").

  tools/framegaps.py [--skip 40] [--idle 150] work/test/RUN.txt ...

Gap = time between the starts of consecutive frames, after the first --skip
frames. Gaps over --idle ms are idle time (nothing to draw), not slow frames,
and are left out. Prints frames, gap median and p90, and gaps over 33 ms (the
LOG.md frame-timing table).
"""
import argparse
import re
import statistics

ap = argparse.ArgumentParser()
ap.add_argument('--skip', type=int, default=40)
ap.add_argument('--idle', type=float, default=150)
ap.add_argument('logs', nargs='+')
a = ap.parse_args()
re_tl = re.compile(r'BLUEEAGL: tl: g (\d+) began (\d+) ended (\d+)')
print(f"{'run':24} {'frames':>6} {'median':>7} {'p90':>7} {'>33ms':>6}")
for path in a.logs:
    t = [int(m.group(2)) for m in map(re_tl.search, open(path, errors='replace')) if m]
    t = t[a.skip:]
    g = sorted((y - x) / 1000 for x, y in zip(t, t[1:]) if 0 < (y - x) / 1000 <= a.idle)
    if not g:
        print(f"{path:24} no frames")
        continue
    print(f"{path.split('/')[-1]:24} {len(t):6} {statistics.median(g):6.1f}ms {g[int(len(g) * 0.9)]:6.1f}ms {sum(x > 33 for x in g):6}")
