# Fast hardware iteration

How a kernel change goes from an edit to a log from the phone in about a minute, with nobody touching the
phone. Built on 2026-11-19 while bringing up the Adreno 630 GMU. Before this, one test took about 35
minutes: a full kernel build, then a person pressing buttons and tapping through recovery to fetch the log.

| Step | Before | Now |
| --- | --- | --- |
| Kernel build after a patch change | ~25 min (full) | ~25 s (`build-xnu.sh --quick`) |
| Boot, get to recovery, enable adb, pull the log | ~10 min, by hand | ~45 s, automatic |
| **One test** | **~35 min** | **~70 s** |

## The pieces

**1. Incremental kernel builds: `tools/build-xnu.sh --quick`.** After one full build in `work/kbuild`, only
our `xnu/patches` that changed (or are new or gone) are taken back out of the patched tree, together with
every patch after them, and put back in. make then recompiles what they touch and relinks. Changing the
pins (ios-sweet, sailfish, dxb, MACOS_VERSION) still needs a full build.

**2. A kernel that reboots itself: 0127, `bluereboot=`.** `bluereboot=recovery` (or `bootloader`) with
`bluereboot_after=gpu` (default; or `springboard`, or a number of seconds) flushes the log ring to
userdata synchronously, sets the reboot reason the way Linux does on this phone (PM8998 PON
`SOFT_RB_SPARE` through the SPMI arbiter, plus the IMEM restart_reason cookie) and resets with PSCI.
ABL then goes straight to recovery. A GPU test no longer boots all of iOS, and no buttons are needed.

**3. Recovery with adb and no tap: `tools/recovery-adb.py`.** LineageOS recovery refuses adb until
Advanced > Enable ADB, because its only adb key source is userdata, which holds the iOS root. The tool adds
`ro.adb.secure.recovery=0` to the recovery ramdisk (the cpio entry is edited in place; the AVB footer is
moved, which is fine while unlocked):

```
tools/recovery-adb.py stock/boot.img work/boot_b-adb.img
fastboot flash boot_b work/boot_b-adb.img
fastboot --set-active=b      # a restart then lands in recovery, never in a boot loop
```

**4. One command per test: `tools/phonetest.sh`.**

```
tools/phonetest.sh --quick --name gmu1 bluegpu=3 bluereboot=recovery
```

Quick build, device tree (with the GMU firmware if `work/fw` has it), payload and shim with the extra
boot-args, phone to fastboot (from recovery over adb if needed), `fastboot boot`, wait for recovery, pull
the log ring, print the matching lines (`--grep`), phone back to fastboot. Every file lands in
`work/test/NAME*`. A real run:

```
[  0s] quick kernel build
[ 27s] shim work/test/reboot1-shim.img (3557c02cc67f kernel), args: bluegpu=3 bluereboot=recovery
[ 29s] RAM boot
[ 39s] waiting for recovery (up to 5 min)
[ 70s] pulling the log
BLUELINE GPU: GMU init result 0xbabeface after 366 us: GMU FIRMWARE RUNNING
BLUELINE REBOOT: after GPU probe: to recovery, PON SOFT_RB_SPARE 0x10 -> 0x02 (0), ...
[ 72s] done: work/test/reboot1.txt; phone back to fastboot
```

If the test hangs the phone, the script gives up after `--wait` minutes; hold Power + Volume Down for the
bootloader and run the next test.

## Writing hardware probes that suit this loop

- **Off by default, one boot-arg per stage** (`bluegpu=1,2,3,4`, each running the ones below it). The same
  kernel then serves every test; only the boot-args change between boots.
- **Log before every first access to a block** ("about to read X at 0x..."), so the last line of a hung
  boot names the culprit.
- **Bound every wait**, and on any failure **undo every write in reverse** (an undo log), so a failed stage
  leaves the phone as ABL left it and the rest of the boot carries on.
- **Read-only first.** A new block gets a survey-only mode (for example `bluegpu_smmu_dry=1`) before the
  first write.

## How the work is split (with Claude Code)

- Research and first drafts of each stage are done by background agents, which read the Linux,
  Google (crosshatch KGSL), ios-flame and HackiOS sources and disassemble firmware where needed. They run
  while the previous stage is on the phone, so drafting and testing overlap.
- The phone is the reviewer: drafts go straight into the loop. An independent review is only asked for
  when a result can't be explained.
- Every result goes into [LOG.md](LOG.md), with the numbers from the log.
