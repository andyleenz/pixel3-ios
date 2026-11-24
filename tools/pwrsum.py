#!/usr/bin/env python3
"""Summarise a power run's log (tools/pwr.sh, or any boot with bluebatt_usb_off=).

  tools/pwrsum.py work/test/pwr1.txt [work/test/pwr2.txt ...]

Splits the boot into phases at the scripted power-key presses:
  on1    SpringBoard up, before the first press (screen on, idle)
  off    whenever the display is off
  on2    after the second press
  wake   display on between the presses without the script
  input  within 60 s of a key or touch the script did not send
and prints, per phase, the battery current (MAX1720x, only while USB input is
suspended, first SETTLE samples after each change dropped), DPU flips and the
per-CPU timer interrupts and IPIs per second (SWEET SMP lines, 5 s apart).
"""
import re
import statistics
import sys

SETTLE = 2  # samples (10 s each) dropped after a phase change
TOUCH_HOLD = 6  # samples (60 s) after unscripted input that go to "input"

re_cur = re.compile(r'MAX1720X: #\d+ \d+% \d+ mV \(avg \d+\) (-?\d+) mA')
re_flip = re.compile(r'BLUE DPU: 5s: (\d+) flips')
re_smp = re.compile(r'SWEET SMP: cpu(\d) timer (\d+) ipi (\d+) next')


def summarise(path):
    # Phases follow the display, not just the script: on1 (before the first
    # scripted press), off (display off), on2 (after the second press), wake
    # (display on in between: someone or something woke it). A sample within
    # TOUCH_HOLD samples of a key or touch that the script did not send goes
    # to "input" instead, so a person using the phone doesn't skew a phase.
    phase = None
    on_batt = False
    settle = 0
    cur, flips, smp_rate, smp_acc = {}, {}, {}, {}
    smp_prev = {}
    steps_seen = 0
    sb = False
    display_on = True
    touched = 0
    script_key = 0
    for line in open(path, errors='replace'):
        if 'USB input suspended for' in line:
            on_batt, settle = True, SETTLE
        if 'BLUELINE SCRIPT: sb+' in line:
            sb = True
        if 'BLUELINE SCRIPT: step' in line:
            steps_seen += 1
            script_key = 2        # the scripted key's own down/up lines
        if 'BLUELINE KEYS: key' in line or 'SWEET HID: touch 0 down' in line:
            if script_key:
                script_key -= 1
            else:
                touched = TOUCH_HOLD
        if 'SWEET FB: display off' in line:
            display_on, settle = False, SETTLE
        elif 'SWEET FB: display on' in line:
            display_on, settle = True, SETTLE
        if not sb:
            ph = None
        elif not display_on:
            ph = 'off'
        elif steps_seen == 0:
            ph = 'on1'
        elif steps_seen >= 2:
            ph = 'on2'
        else:
            ph = 'wake'
        m = re_cur.search(line)
        if m and ph and on_batt:
            if touched:
                touched -= 1
                cur.setdefault('input', []).append(-int(m.group(1)))
            elif settle:
                settle -= 1
            else:
                cur.setdefault(ph, []).append(-int(m.group(1)))
        if touched:
            ph = ph and 'input'
        m = re_flip.search(line)
        if m and ph:
            flips.setdefault(ph, []).append(int(m.group(1)))
        m = re_smp.search(line)
        if m:
            c, t, i = int(m.group(1)), int(m.group(2)), int(m.group(3))
            if c in smp_prev and ph:
                pt, pi = smp_prev[c]
                acc = smp_acc.setdefault(ph, [0, 0])
                acc[0] += (t - pt) / 5
                acc[1] += (i - pi) / 5
            smp_prev[c] = (t, i)
            if c == 7 and ph in smp_acc:
                smp_rate.setdefault(ph, []).append(tuple(smp_acc.pop(ph)))
    print(path)
    print(f"  {'phase':5} {'mA med':>7} {'mA p90':>7} {'n':>3}  {'flips/s':>7}  {'timer/s':>8} {'ipi/s':>7} (all 8 cores)")
    for ph in ('on1', 'off', 'on2', 'wake', 'input'):
        if ph in ('wake', 'input') and ph not in cur and ph not in flips:
            continue
        c = sorted(cur.get(ph, []))
        f = flips.get(ph, [])
        s = smp_rate.get(ph, [])
        med = f"{statistics.median(c):7.0f}" if c else '      -'
        p90 = f"{c[int(len(c) * 0.9) - 1 if len(c) > 1 else 0]:7.0f}" if c else '      -'
        fl = f"{sum(f) / (5 * len(f)):7.1f}" if f else '      -'
        tm = f"{statistics.median(x[0] for x in s):8.0f}" if s else '       -'
        ip = f"{statistics.median(x[1] for x in s):7.0f}" if s else '      -'
        print(f"  {ph:5} {med} {p90} {len(c):3}  {fl}  {tm} {ip}")


for p in sys.argv[1:]:
    summarise(p)
