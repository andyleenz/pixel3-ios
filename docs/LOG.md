# pixel3-ios

Groundwork for porting [ios-sweet](https://github.com/dipa-studio/ios-sweet)
(Apple's XNU + the iOS 16 userland on a Redmi Note 10 Pro) to the
**Google Pixel 3 (blueline, Snapdragon 845)**.

## Step 1: the probe (`p1-probe/`)

A tiny bare-metal program the Pixel 3 bootloader runs like a Linux kernel.
It touches nothing on the phone's storage. One boot answers:

1. Does the bootloader run our image, and is the framebuffer at `0x9d400000`?
2. Are colours `a8r8g8b8`? (the three bars should read RED, GREEN, BLUE)
3. **Does the command-mode panel keep refreshing by itself?** A yellow bar
   sweeps along the bottom and a `t=Ns` counter counts for 30 s.
4. CPU ID, 16K page support, PSCI version, where the image and DTB landed.
5. The live memory map and reserved carve-outs, to plan where XNU goes.

After 90 more seconds it reboots straight back into fastboot.

### Run it

Phone in fastboot (power off, then hold Power + Volume Down), USB connected:

```sh
fastboot boot p1-probe/out/probe.img
```

`fastboot boot` only loads the image into RAM for one boot; nothing is
flashed. The kernel must be gzip-compressed: the Pixel 3 bootloader
rejects an uncompressed Image with "Error verifying the received
boot.img: Unsupported".

If the auto-reboot lands in LineageOS instead of fastboot, that's fine:
`adb reboot bootloader` gets you back.

### What to report back (a photo of the screen is ideal)

| You see | Meaning |
| --- | --- |
| Probe screen, bar sweeps, counter climbs | Display path works like on the Redmi. Best case. |
| Probe screen appears but frozen (bar/counter stuck) | Panel needs a refresh "kick" per frame (MDP command-mode trigger). Solvable, adds a small display driver. |
| Fastboot screen stays, phone seems hung | Image runs but the display doesn't show our writes, or it crashed early. Hold Power + Vol Down ~10 s to recover. |
| Fastboot rejects the image | Header/DTB format issue: try v2, or rebuild with your stock `boot.img` (below). |
| Blue "EXCEPTION" screen | Photo it; ESR/ELR/FAR say exactly what faulted. |

### Build

```sh
cd p1-probe
./build.sh                      # uses the mainline DTB in ../dtb/
./build.sh /path/to/boot.img    # or reuse a stock (e.g. LineageOS) boot.img's DTBs and addresses
```

Needs LLVM (`clang`, `ld.lld`, `llvm-objcopy`, `llvm-nm`, `llvm-readelf`)
and `python3`. On macOS: `brew install llvm lld` (Homebrew ships `ld.lld`
separately; `build.sh` takes any tool missing from `$LLVM` from `PATH`), then
`PATH=$(brew --prefix lld)/bin:$PATH LLVM=$(brew --prefix llvm)/bin ./build.sh`.

Emulator check (no phone needed): `EXTRA_CFLAGS=-DQEMU ./build.sh`, then run
`out/Image` with `qemu-system-aarch64 -machine virt,gic-version=3 -cpu cortex-a55 -m 4G -kernel out/Image`
and `pmemsave 0x9d400000 9331200 fb.raw` from the QEMU monitor to grab the screen.

`tools/bootimg.py info boot.img` shows any boot image's header, load
addresses and DTBs.

### Result of the first run (2026-10-20, LineageOS bootloader, mainline DTB)

Everything works, including the refresh test: the bootloader leaves the
command-mode panel refreshing from `0x9d400000`, so ios-sweet's
copy-to-framebuffer display path works unchanged.

| Item | Value |
| --- | --- |
| CPU | MIDR `0x517f803c` (Kryo 385 Silver), boot MPIDR `0x81000000` (core number in Aff1, MT set) |
| Pages / PA | 16K granule supported, PARange 40-bit, GIC sysreg interface |
| Firmware | PSCI 1.1, SMCCC 1.2, CNTFRQ 19.2 MHz, EL1 with MMU off |
| Loaded at | image `0x80080000`, DTB `0x84500000`, initrd `0x84700000` |
| RAM | one range `0x80000000`, size `0xfe0a0000` (4064 MiB) |
| Carve-outs | all below `0x9f800000` except rmtfs `0xf2700000`+`0x202000` |
| XNU candidate | `0xf2a00000`..`0x17e0a0000` (~2.2 GiB contiguous); fallback `0x9f800000`..`0xf2700000` (~1.3 GiB) |

### Second run: LineageOS DTB (2026-10-20)

Built with `./build.sh boot.img` from `lineage-22.2-20261005-nightly-blueline`
(sha256 `15b794c4…69b6f5ba`, kept in the gitignored `stock/`). That boot.img is
header v2 with an lz4 kernel and two SoC-only DTBs (SDM845 v2 and v2.1); the
bootloader picked one and applied the Pixel overlay from the `dtbo` partition:
MODEL `Google Inc. MSM sdm845 B1 DVT1.1`, COMPAT `google,b1c1-sdm845`, DTB
487342 bytes. CPU, firmware, load addresses and RAM (one range, 4064 MiB) are
the same as with the mainline DTB; the display and refresh test work as before.

Downstream carve-outs (27, read off the screen photo; names cut to 9 chars):

| Base | Size | Name | | Base | Size | Name |
| --- | --- | --- | --- | --- | --- | --- |
| `0x85700000` | `0x600000` | hyp | | `0x97800000` | `0x500000` | video |
| `0x85e00000` | `0x100000` | xbl | | `0x97d00000` | `0x800000` | cdsp |
| `0x85fc0000` | `0x2f40000` | removed | | `0x98500000` | `0x200000` | mba |
| `0x8ab00000` | `0x1400000` | qseecom | | `0x98700000` | `0x1400000` | slpi |
| `0x8bf00000` | `0x500000` | camera | | `0x99b00000` | `0x100000` | pil_spss |
| `0x8c400000` | `0x10000` | ips_fw | | `0x9d400000` | `0x2400000` | cont_splash |
| `0x8c410000` | `0x5000` | ipa_gsi | | `0xa1800000` | `0x10000` | debug_info |
| `0x8c415000` | `0x2000` | gpu | | `0xa1810000` | `0x200000` | ramoops |
| `0x8c500000` | `0x1a00000` | adsp | | `0xa1a10000` | `0x200000` | alt_ramoops |
| `0x8df00000` | `0x100000` | wlan_fw | | `0xa1c10000` | `0x1000` | ramoops_meta |
| `0x8e000000` | `0x9800000` | modem | | | | |

Dynamic (size only, placed by Linux): adsp `0x1000000`, qseecom_ta
`0x1000000`, secure_sp `0x800000`, secure_display `0x900000`, mem_dump
`0x2400000`, linux,cma `0x2000000`. XNU doesn't need these.

Differences from mainline: the Pixel overlay grows modem to `0x9800000`, which
moves video..pil_spss up by `0x2000000` (node names like
`video_region@0x95800000` are stale), and adds ramoops/debug_info at
`0xa1800000`..`0xa1c11000`. Downstream has no fixed rmtfs; mainline's
`0xf2700000` is a Linux-side choice.

**XNU memory range:** every fixed carve-out in either tree ends by
`0xa1c11000`, apart from mainline's rmtfs. Step 4 uses the range both trees
agree is free, `0xf2a00000`..`0x17e0a0000` (~2.2 GiB). If we need more, or RAM
below 4 GiB for DMA, `0xa2000000`..`0xf2700000` (~1.3 GiB) is also free; rmtfs
only matters once something runs the modem.

## Step 2: XNU to its framebuffer console (`p2-shim/`, `tools/`, `xnu/`)

```
ABL (unlocked, LineageOS bootloader)
  -> fastboot boot p2-shim/out/shim.img     RAM only, nothing flashed
     -> shim: checks the live DTB, copies the payload linked into its own image
        -> XNU (ios-sweet's SWEET kernel + our blueline patch), ADT, boot_args
```

| Piece | What |
| --- | --- |
| `tools/mkadt.py` | Apple Device Tree for blueline: RAM `0xf4000000`+`0x8a000000`, GIC, timer INTID 19, `sweet-fbcon` at `0x9d400000` 1080×2160, one CPU. No storage node, so the kernel cannot touch UFS. `--qemu` swaps in QEMU virt's GIC/timer |
| `tools/mkpayload.py` | Kernel Mach-O + ADT + boot-args into one payload; applies the kernel's chained fixups (nothing else would) |
| `tools/adt.py` | ADT serializer/parser, `adt.py dump X.adt` |
| `p2-shim/` | The loader. The payload is linked into the shim's Image, which ABL unpacks at `0x80080000` with ~68 MiB free below the DTB, so the ramdisk's 16 MiB gap below `hyp` at `0x85700000` does not matter. Before copying, it refuses kernel RAM that is outside `/memory`, overlaps a fixed `/reserved-memory` region, the framebuffer, itself or the DTB. Then a 3 s pause (photo the screen), copy, jump with MMU off, `x0` = boot_args |
| `xnu/patches/` | Our XNU patches, applied after ios-sweet's. `0100-blueline-early-framebuffer.patch`: the early debug console uses the blueline framebuffer (same 32 MiB block at `0x9c000000` as sweet's, so the mappings stay) |
| `.github/workflows/xnu.yml` | Kernel build on GitHub's macOS 14 runners: blacktop/darwin-xnu-build, xnu-8796.141.3, ios-sweet patches 0001-0027 fetched at a pinned commit, then ours. Fails if any patch was skipped |
| `common/` | Entry code, framebuffer console, FDT walker, PSCI/reboot and build steps shared by probe and shim |

Only ios-sweet patches up to 0027 (RAM-disk root) are used. 0028 and later
add the UFS root device and writes to `userdata`, which on this phone is
LineageOS's data; they come in only as a deliberate later step.

### Build and run

```sh
gh workflow run xnu.yml                          # or push a change under xnu/
gh run download RUN_ID -n xnu-kernel -D xnu/out
python3 tools/mkadt.py p2-shim/out/blueline.adt
python3 tools/mkpayload.py xnu/out/kernel.development.sweet p2-shim/out/blueline.adt \
    p2-shim/out/payload.bin --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam'
p2-shim/build.sh p2-shim/out/payload.bin stock/boot.img
fastboot boot p2-shim/out/shim.img
```

QEMU check of the whole loader path with a stand-in kernel
(`p2-shim/test/testkernel.c`, an arm64 Mach-O with chained fixups):
`p2-shim/test/run-qemu.sh` must print `screen: GREEN (pass)`. Status
2026-10-20: passes, and fails as it should with a wrong cmdline.

### First XNU boot on the phone (2026-10-21)

Kernel from CI run 39504429541 (ios-sweet 0001-0027 + our 0100), payload
16.3 MB, `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam`,
`fastboot boot` of `p2-shim/out/shim.img` built with the LineageOS DTBs.

**XNU runs on the Pixel 3 and prints to the framebuffer.** The photo shows
VM bootstrap and zone_init, OSLog/firehose, scheduler setup, "iBoot
version: pixel3-shim" (our ADT), the SWEET PRNG, pthread and AMFI,
"SWEET: platform expert registered", `ml_processor_register` and
`cpu_start() cpu: 0`, the BSD copyright banner, MAC framework, and as the
newest line `SWEET CPU: boot CPU 0 registered, SGI1 verified,
initialization complete` (so the GIC delivers a self-IPI). The early
marker band at the bottom is drawn too.

A later photo shows it kept going exactly as in QEMU: ktriage, SWEET HFS,
mcache/mbinit (64 MB pool), DLIL SUM16 self-tests, Skywalk self-tests (all
PASSED), lo0/gif0/stf0 attached, then `!BSD` and

    Waiting on <dict ...><key>IOProviderClass</key><string>IOMedia</string>
    <key>Content</key><string>Apple_HFS</string></dict>

**Step 2 is done: XNU boots on the Pixel 3 to "waiting for root device".**
Scheduler, timer interrupts (kernel threads get scheduled) and the GIC work;
the display needs nothing beyond copying into ABL's framebuffer. There is
no root disk yet, so this is the expected end. Hold Power + Volume Down to
get back to fastboot.

## Step 3: iOS root on userdata (in progress)

The user approved (2026-10-21) erasing LineageOS's `userdata` for the iOS
root; every flash is still confirmed separately. Nothing else on the phone
is touched.

| What | Value |
| --- | --- |
| `userdata` | `sda21` = UFS LUN 0, `0xCE4FFB000` bytes (51.6 GiB), fastboot type `raw` |
| Kernel | ios-sweet 0001-0059 + ours (CI run 39506022755): UFS root driver (writes only with `ufsrw=1`), AMFI/sandbox/keystore/watchdog stand-ins, IOSurface + framebuffer services, HID services, iPhone identity. 0060+ drive sweet-only keys/touch/regulators/USB and stay out |
| ADT | `mkadt.py --ufs` adds the UFS host; `--iphone DeviceTree.d22ap.im4p` the iPhone X identity and `/product` |

**Read-only UFS test (2026-10-21), passed.** `rd=ufsroot0` without
`ufsrw`: the kernel took over the UFS host ABL left running, found
`userdata` in LUN 0's GPT, attached it as `ufsroot0` and read the HFS+
header block: "unknown Volume Signature : 394f" (LineageOS's encrypted
data), then retried the mount in a loop. No write possible in this mode.

**First flash and boot (2026-10-21).** `fastboot flash userdata` (sparse,
45 x 256 MiB; this ABL's max-download-size is `0x10000000`, so no `-S 512M`)
took 334 s. Boot with `--ufs --iphone`, `rd=ufsroot0 ufsrw=1 rootrw=1
launchd_unsecure_cache=1 ignition_level=1 unentitled_ios_sim_launch=1 ...`:
UFS read-write, persistent log at the last 4100 KiB, **HFS+ root mounted**,
`/sbin/launchd` executed, libignition started, then `cs_invalid_page` on a
launchd page and pid 1 died of SIGSEGV -> "initproc failed to start".
Cause: our `img2simg.py` wrote all-zero blocks as DONT_CARE, so zero blocks
inside files kept LineageOS's old bytes. Fixed (FILL chunks with value 0);
reflash needed.

**Second flash and boot (2026-10-21 00:50): iOS userland runs.** Reflash
with the fixed sparse image: 445 s (zero blocks now written). ABL then hung
receiving the boot image (as on sweet after big flashes); Power + Volume
Down, then `fastboot boot` worked. The Apple logo appeared briefly between
the kernel output, then launchd kept spawning daemons: `exec xpcproxy`,
`exec bluetoothd`, `fairplayd.H2`, ... in a loop (daemons for absent
hardware crash and are relaunched). Waiting to see whether it reaches
backboardd/SpringBoard (sweet: about 4-5 minutes on first boot).

**Log of that boot** (`tools/phone.sh log`, 2212 lines): ~100 daemons start
once and stay up; `bluetoothd` and `fairplayd.H2` crash-loop (no hardware /
no SEP), `driverkitd` was killed once. backboardd opens AppleCLCD
1080x2160, creates IOSurfaces and presents 5 frames (the Apple logo), then
backboardd and SpringBoard sit blocked (process sampler). No data
migration runs (no `migrationpluginwrapper`). Kernel text keeps drawing
over the panel because nothing mutes the console yet.

**SMP: all eight cores (2026-10-21).** Kernel = ios-sweet 0001-0059 + 0065
+ our 0101 (CI 39511860472), ADT `--cpus 8`, `cpus=8`: CPU_ON rc=0 and
"came alive; SGI1 OK" for MPIDR 0x100..0x700, then
`SWEET CPU: 8/8 CPUs initialized, SGI1 verified`. Silver and Gold run as
one homogeneous cluster (the scheduler does not prefer the Gold cores).

**8 cores are slow (display kernel, CI 39512538196, `cpus=8`).** Every
hand-off between processes stalls for minutes: launchd's data-protection
task (`seputil`, 0.16 s on one core) took 16:01:45 -> 16:04:51, the next
gap was to 16:07:03, and the kernel's log thread, which sleeps one second
per flush, flushed only 8 times in ~7 minutes. All 8 cores passed their
SGI test, and each core enables INTID 19 + SGI 1 on its own
redistributor, so suspect: the virtual timer interrupt on secondary cores
not arriving (timed wakeups on those cores lost). Test: same kernel with
`cpus=1` and `cpus=4` (Silver only).

**Hardware is fine; the stall is in software (probe, 2026-10-21).** The
probe now starts all 8 cores: every core's CNTPCT-CNTVCT is 0-1 tick (no
per-core offset from the hypervisor), and with the GIC set up as XNU does,
a 10 ms virtual timer wakes every core from WFI with INTID 19 pending.

**Kernel 0103 (per-CPU stats every 5 s) boots fast to the Apple logo** on
8 cores with the console muted (1125x2436 frames, so 0061 works). The
periodic stats thread seems to mask the lost wakeups. After ~9 min all
cores had taken 25k-107k timer interrupts and 10k-28k IPIs. backboardd
presented 4 frames (the logo). Symbolicated against the root image's
shared cache (`ipsw dyld a2s CACHE ADDR --slide 0x4705c000`), SpringBoard's
main thread waits in `_LSContextInitCommon` (LaunchServices database lock)
from Control Center's `CCSModuleRepository` app lookup: lsd builds the
LaunchServices database on first boot. Next: more time, sample lsd.

**8 cores, migration boot (2026-10-21 02:20): stuck again.** Stopped at
`exec seputil` like the first 8-core boot, and the log ends at t=223 s. The
per-CPU stats show the Gold cores (cpu4-7) never took an IPI or a timer
interrupt after start-up (counts 1/1), while cpu0-3 were busy. In the
earlier 0103 run they did get thousands later, so it is intermittent:
something in how cores hand work to each other. Probe tests so far only
cover self-SGIs, not one core waking another. Back to `cpus=1` for the
migration run (19:36); SMP debugging is a separate track.

Root image tools (ours; which iOS details matter is from ios-sweet's notes):

| Tool | What |
| --- | --- |
| `tools/mkiosroot.sh` | macOS: mounts the IPSW's OS, SystemOS and AppOS APFS images (owners on), builds a raw 16 GiB case-sensitive journaled HFS+ image with `newfs_hfs`, copies them decompressed with `rsync -aH` as root, links the shared cache and cryptex files, creates logd stores and the system keybag, runs the tweaks. Needs `sudo` |
| `tools/iosroot-tweaks.py` | No crash panics, no CommCenter, containers, migration done, Setup skipped, audio/media crash paths off, activation data ark |
| `tools/img2simg.py` | Raw image -> Android sparse image for `fastboot flash userdata` (zero blocks as FILL 0) |
| `tools/simgdiff.py` | Sparse image of only the blocks where a new image differs from the flashed one: a change flashes in seconds |
| `tools/rootimg.sh` | `sudo` mount/umount of a raw root image on the Mac to change files (owners kept) |
| `tools/phone.sh` | From LineageOS recovery (adb root): `log` pulls the kernel's persistent console log, `sync BASE.img` copies the 4 MiB pieces that differ from the phone into BASE so it is a valid diff base again |
| `tools/phonelog.py` | Decodes that log ring ("SWEETLOG" header + 4 MiB ring at the end of userdata) |

Changing the root without a full reflash (iOS writes to the volume when
booted with `rootrw=1`, so the base must be synced from the phone first):

```sh
fastboot reboot recovery                       # then Advanced -> Enable ADB
tools/phone.sh log                             # -> work/phone-log.txt
tools/phone.sh sync work/ios-root.img
cp -c work/ios-root.img work/ios-root-new.img
sudo tools/rootimg.sh mount work/ios-root-new.img   # edit under work/root
sudo tools/rootimg.sh umount
tools/simgdiff.py work/ios-root.img work/ios-root-new.img work/diff.simg
adb reboot bootloader && fastboot flash userdata work/diff.simg
mv work/ios-root-new.img work/ios-root.img
```

## Step 4: input (in progress)

`p3-input/` (probe, read-only on the PMIC), run 2026-10-21:

| What | Result |
| --- | --- |
| SPMI arbiter | v5 (`0x50000000`), 512 APIDs; PON APID `0xac`, GPIO 6 APID `0xbe` |
| Power | PON INT_RT_STS (`0x810`) bit 0: works |
| Volume down | `0x810` bit 1 (RESIN): works |
| Volume up | GPIO 6: input, enabled (`mode 0x00`, `en 0x80`, subtype `0x10`), but STATUS1 stays `0x80` and INT_RT_STS `0x00` when pressed (no pull-up/interrupt configured by ABL); left out for now |
| Touch | `st_fts@49`, `st,fts`, on `i2c@888000` (`qcom,i2c-geni`); IRQ GPIO 125, reset GPIO 99, switch GPIO 136, `vdd`/`avdd` supplies, max 1079x2159. ST FTS protocol as in ios-raphael's 0086 (fts_521) |

Kernel `0104-blueline-keys.patch`: power + volume down, polled every 20 ms,
fed to the HID services (`bluekeys=0` off).

Event stream (probe): 100 WFE take 82 us (Silver) / ~412 us (Gold) on every
core, so it is not the 8-core stall either. lsd (sampled) is blocked in
`__LAUNCH_SERVICES_CLIENTS_ARE_WAITING_FOR_THE_DATABASE_TO_FINISH_SEEDING__`
and `-[_LSInstallProgressService restoreInactiveInstalls]`: the
LaunchServices database is never seeded. Suspect: our tweaks skip the
first-boot data migration from the start (sweet ran it once first).
Fix applied 2026-10-21 02:20: `phone.sh sync` (142/4096 pieces had
changed on the phone), `tools/migration-reset.py` on a clone (markers
removed, `/private/var/datamigrator/migrate` sentinel), `simgdiff` = 101
blocks / 404 KB, flashed in 0.5 s. `iosroot-tweaks.py` no longer skips the
migration.

Touch: `p3-input` now also enables GENI I2C on QUP wrapper 0 / SE2
(`0x888000`; clocks from `gcc-sdm845.c`: vote `0x5200c` bits 6/7/12, SE2
RCG `0x17294` on the 19.2 MHz crystal; SDA/SCL GPIO 27/28 = `qup2`), reads
the FTS chip ID (`0xFA 20 00 00 00`) and shows FIFO events (`0x86`) while
the screen is tapped. Not run yet. Kernel `0105-blueline-touch.patch` is
the same as a polled driver, off unless `bluetouch=1`. Open question: is
the chip powered and sensing (supplies `vdd`/`avdd`, reset GPIO 99, and
`st,switch_gpio` 136, which routes the touch bus to the AP or the SLPI
sensor hub)?

Probe runs (2026-10-21 evening): SE2 clocks on (s2 CBCR `0x4220`, wrapper
core `0x1700c`/`0x17010` on), firmware is I2C (`0x300`), writes stick (SCL
readback = written value), `GENI_CGC_CTRL`/`OUTPUT_CTRL`/`FORCE_DEFAULT`
and `M_IRQ_EN` set, reset GPIO 99 high, switch GPIO 136 low. But an I2C
command never starts: GENI status and M_IRQ_STATUS stay 0 (no done, no
NACK). Next suspect: FIFO interface disabled for this SE
(`SE_GENI_IF_DISABLE_RO` 0x064, as Linux checks), which would mean GPI DMA.
Volume up: GPIO 6 STATUS1 reads `0x81` released and pressed alike.

**SMP hardware fully checked (probe, 2026-10-21):** SGI 1 sent from core 0
with XNU's encoding (`ICC_SGI1R` Aff1 = core, TargetList bit 0) reaches
every core in 4-7 us (Gold included), on top of synchronized counters,
working timer IRQs and the event stream. The 8-core hangs (Gold cores
never take an IPI in XNU) are therefore in XNU's SMP path with MMU and
caches on, not the hardware. iOS boots stay on `cpus=1` meanwhile.

**Migration boot on 1 core hangs at `usermanagerd`:** keybag task done
(`DONE MKB_INIT`), launchd execs `usermanagerd` (16:00:56) and nothing
follows for minutes; no crash. Next boot samples `usermanagerd`.

**Data migration runs (1 core, kernel with 0103-0105, 20:05).** The next
boot passed `usermanagerd` and showed iOS's migration screen (Apple logo +
progress bar); the bar reached ~98% in ~30 min, then crawled. Log after
~1 h 50 min: `migrationpluginwrapper` ran 3x, backboardd had presented
**193,000 frames** (~60 Hz, a full 10 MB copy each, on the only core: the
slowdown sweet also hit), 2x `hfs_clonefile: cluster_write failed - 34`.
**Keys work in iOS**: power and volume down reach the HID services with a
client (`SWEET HID: key 0x30/0xea ... (1 clients)`). Rebooted 21:56 with
`sweetfb_hz=10` (0056's panel-copy throttle) to give the migration the CPU.

### Touch works (probe, 2026-10-22)

The touchscreen is an ST FTM5 (chip id `36 39`) at I2C 0x49. Getting it to report fingers took four findings:

1. **GPI DMA crashes the SoC.** SE2's FIFO interface is disabled (`GENI_IF_DISABLE_RO` = 1), so Linux would use GPI DMA. GPI itself comes up: GPII 1 initializes and both channels start. The SMMU also accepts a stream entry for SID 0x16, whether routed through a bypass context bank (plain bypass is turned into "fault", as Linux expects on SDM845) or through the firmware's UFS context bank. Even so, the first descriptor fetch freezes the SoC within 1 ms and the firmware resets it seconds later. Likely cause: no interconnect vote for the QUP-to-DDR path. Parked.
2. **Bit-banged I2C works.** Following HackiOS, which drives its panel's SPI by hand, the probe uses GPIO 27/28 as open-drain GPIOs at about 100 kHz. The chip ACKs only when `st,switch_gpio` (GPIO 136) is high, which routes the bus to the apps processor instead of the sensor hub.
3. **Start-up as Google's driver does it** (`stm/fts.c`): system reset (`FA 20 00 00 24 80`), then "controller ready", interrupt enable at 0x20000029 (`... 29 41`), then `A0 00 FF` (scan mode active). I first wrote the interrupt enable to 0x2C by mistake.
4. **avdd was off.** `avdd-supply` is PM8998 LDO19 (3.3 V). It is owned by the AOP (SPMI owner 4), so a direct PMIC write is not possible, and it is off after ABL. The chip answered and scanned, but never saw a finger. The probe asks the AOP for it over RPMh, as Linux's regulator driver does: `ldoa19` from cmd-db (0x41a00, cmd-db at 0x85fe0000), then 3300 mV, HPM and enable in active TCS 0 of the apps RSC (DRV 2, 0x179e0d00). All three commands completed.

After that, touching and dragging produced live motion events (`23 01 ...`, x=508 y=1600). `0113-blueline-touch-bitbang.patch` puts the same sequence in the kernel, on by default (`bluetouch=0` turns it off). It reads the FIFO when the IRQ line (GPIO 125) is low, and every 100 ms regardless.

### Touch in iOS (2026-10-22 23:07)

`0113` + `0114` (cmd-db mapped at a fixed 128 KiB: the second word of the locator is not a size, and with the old check the RPMh vote never went out) on 4 cores (`cpus=4 wfi=0`, `shim-touch4b.img`): **touch works in iOS**. Swiping on the lock screen opened the Focus menu. Two layout issues: the canvas was cropped (the presented 1125x2436 cut to 1080x2160, which lost 138 rows top and bottom), and it is slow on the 4 Silver cores. `0115-blueline-display-fit.patch` scales the canvas to the panel's height instead (nearest neighbour, 997x2160 with 41-column black bars) and maps touch the same way. `bluefb_fit=0` brings back the crop. Confirmed on the phone (8 cores, 23:18): the whole screen is visible and touch lines up. In the last few boots, 8 cores (`cpus=8`, real WFI) stalled at the "SWEET SMP" lines 3 times out of 6.

### 8 cores, SMP stall, panel rate (2026-10-22, late)

`0116-blueline-smp-diag.patch` adds a second stats line per CPU: IPIs sent, `cpu_signal`, the scheduler's state, priority and thread, and the GICR SGI pending/enable bits and WAKER. A stall captured with it (`work/log-diag8.txt`): the Gold cores' IPIs and timers work. cpu4 later took 4,415 timer interrupts and 100 IPIs, and cpu5-7 fired their armed timers. Boot stopped right after `exec init_featureflags` (in an older stall: `exec seputil`), with the same user thread (priority 31) running on cpu0 in every sample. So an early boot-task process spins forever, and only with 8 cores. Next stall: `sweetsample=init_featureflags,seputil,launchd` shows its user stack. Three boots of the sampling image went through. In good boots all 8 cores carry load (Gold at 2649 MHz, Silver at 1766 MHz).

The panel copy rate goes from `sweetfb_hz=10` (chosen for 4 slow cores) to 30 on 8 cores (`shim-hz30.img`), against the jitter.

GPU, the next big step: HackiOS's staged Adreno 642L bring-up (`redwood_adreno.c`: GX/CX power, GMU firmware and HFI, zap shader through TrustZone, SQE microcode, a test picture) is the template for our Adreno 630 (same A6xx family, also with a GMU). On the user side: Mesa freedreno (a630 is well supported) behind an EAGL bridge in backboardd.

### SMP stall found: stale table-walk entries (2026-10-23)

The sampler caught the stalled process: `seputil` spinning inside dyld (`lsl::PersistentAllocator` constructor, called from `start`) on one store into memory it had just allocated. The fault is "handled" and the store faults again, forever. `0117-blueline-fault-loop.patch` reports a thread that faults on the same address 10,000 times in a row, then invalidates that VA in every TLB (`TLBI VAAE1IS`). In one boot (`work/log-flt8.txt`) it fired 11 times. Every time: ESR `0x92000047` (level-3 translation fault on a write), PAR `0x80f` (the hardware walk also faults, although the page is mapped), and the loop ended after the invalidate. So the cores were holding stale table-walk cache entries, and each of these would have been a boot stall. The invalidate works as a fix (0117 stays in). A proper one would invalidate non-leaf entries when XNU frees page tables. `0118-blueline-touch-edge.patch` flags touches that start at an edge with the edge-tip flag (as ios-sweet 0071), for the home and app-switcher gestures.

**Booting without fastboot:** `shim-edge8.img` (8 cores, 30 Hz, everything above) is flashed to `boot_a` and slot A is active (the old `boot_a` is in `backup/boot/boot_a.img`). Slot B still has LineageOS with recovery: from fastboot, `fastboot --set-active=b` then `fastboot reboot recovery`. To return to iOS: `--set-active=a`.

### Bold Text hangs the respring (2026-10-23)

Turning on Settings > Accessibility > Bold Text made SpringBoard respring and hang on the loader, and every later boot hung too. Fix from recovery: `tools/phone.sh sync`, then `tools/prefs-fix.sh com.apple.Accessibility EnhancedTextLegibilityEnabled false` (sets or removes one key in `/private/var/mobile/Library/Preferences`, then builds `work/diff.simg`), then flash the 0.4 MiB diff. Leave Bold Text off until there is a GPU. Recovery from slot B: `fastboot reboot recovery` is not supported by this bootloader. Use `--set-active=b`, then choose Recovery mode in the bootloader menu.

### ios-flame (Pixel 4): the closest port, and the roadmap from here (2026-10-23)

[ios-flame](https://github.com/NWylynko/ios-flame) (MIT, dipa-studio) has the same base as ours: ios-sweet's XNU 8796 patches and the iPhone X 16.7.16 userland, Google ABL with `fastboot boot`, and the root on `userdata`. Its SM8150 / Adreno 640 is the same A6xx family as our Adreno 630, and its Wi-Fi is a **WCN3990, our chip**. Worth taking, in this order:
1. **USB Ethernet** (0088-0091): the live kernel log, a UDP command server and a TCP file server. Their USB DMA goes "through the apps SMMU the way ABL does it (own context bank, translation off)". That is the likely cause of our DWC3 SETEPCONFIG timeout.
2. **RTC** (0099, PM8150; ours is PM8998, the same SPMI RTC type).
3. Generic fixes:
   - 0084: the early framebuffer mapped Device-GRE
   - 0098: panic logs into the ring
   - 0100: the clonefile fallback (our `hfs_clonefile` errors)
   - 0103, 0114: AMFI answers
   - 0104: planar IOSurfaces (blank Safari pages)
   - 0121: the vsync period for CoreAnimation
4. **Wi-Fi** (0123/0124 plus `wland` in userland).
5. **GPU / Metal** (0095-0122: the A640 core, present, Turnip + metal2vulkan).

From ios-sailfish: `0121-blueline-touch-irq.patch` takes their GIC SPI support (0181), puts touch on the TLMM summary interrupt (INTID 240, GPIO 125 level low), and coalesces moves to 60/s (0182). `bluetouchirq=0` brings back polling. Also on the way: data migration again (`tools/remigrate.sh`: the removable system apps and the wallpapers/posters it sets up), `mobileassetd` back, and `0119`/`0120` a static battery named AppleSmartBattery (as ios-raphael 0101).

### Other ports worth following

- **ios-sailfish** (Pixel 1, Snapdragon 821; owner known to us): GPU
  acceleration on the Adreno 530. Own kernel GPU driver (power, clocks,
  SMMU, CP microcode, zap shader via TrustZone, buffer objects + command
  submission), Mesa freedreno (GLES 3.1) injected into backboardd as
  `sweetgl.dylib` behind an EAGL shim, so CoreAnimation's GLES renderer
  runs on the GPU (no Metal). MDP double-buffered flips instead of a CPU
  copy, 15-35 fps UI. For our Adreno 630 (A6xx) the user-space side
  (freedreno a6xx) exists, but the kernel side needs the GMU (A6xx's GPU
  management unit: its firmware, HFI messaging, RPMh votes), which A5xx
  does not have; Linux's `drm/msm/adreno/a6xx_gmu.c` is the map. A large but
  well-documented project, after touch/SMP.
- Also from sailfish (credited to ios-topaz): IOKit never quiesces on iOS
  (no `kernelmanagerd` to drop the IOKit-daemon busy hold), and QuartzCore
  polls `IOAcceleratorES` 300x/100 ms per process. Our
  `0107-iokit-quiet-ioacceleratores.patch` removes the hold and registers an
  empty `IOAcceleratorES` (`sweetaccel=0` off). Candidate for the
  `usermanagerd`/LaunchServices waits.

- **HackiOS** ([hackios-xnu-kernel](https://github.com/oosexgang/hackios-xnu-kernel),
  [hackios-xnu-userland](https://github.com/oosexgang/hackios-xnu-userland);
  POCO X5 Pro, SM7325): lock screen in ~20 s on 8 cores, Adreno via Mesa,
  Wi-Fi, sound, camera. A different foundation from ours: xnu-8796.121.2
  built on Linux with stock clang, their own platform expert/GIC/PSCI SMP,
  APFS and ramfs drivers, MiniIOSurface/framebuffer/keystore, AMFI/Sandbox
  MAC stand-ins, an EFI loader started from Mu-Silicium UEFI, and an iOS 16.5
  root (we run 16.7.16). Their `docs/PORTING.md` starts with a UEFI port;
  Mu-Silicium has SDM845 devices (polaris, equuleus) but no Pixel 3.
  Taken so far: `0112-blueline-idle-no-setway-flush.patch`. XNU's
  `cpu_idle()` on non-Apple cores cleans the whole D-cache by set/way on
  every WFI, which is unsafe with other cores running and traps to
  Qualcomm's hypervisor. That is the likely cause of our `wfi=0` workaround
  and the 8-core stalls. Next candidates: their small-core scheduler pairing
  (A55s run only when the big cores are busy), the memorystatus thresholds
  fix, and their keystore.

### 8 cores + keychain fix (2026-10-22)

`shim-aks8.img` (`cpus=8 wfi=0`, 0111): all 8 cores ran the whole session (cores 5-7
about 1 M IPIs each), securityd's `aks_wrap_key` now returns 0. The run was stopped at
68,000 frames, before the ~193,000 where the bar used to stall, so the migration
question is still open; bluetoothd (106) and fairplayd (70) restarted all along. Next:
`shim-idle8.img` (0112, `cpus=8` with real WFI), booted 21:24.

### HackiOS userland changes (flashed 2026-10-22)

`tools/iosroot-tweaks.py` now does what HackiOS's userland does. It marks the
data migration done for 20H392 (`LastSystemVersion` plus
`DMLastMigrationResults = {success, buildVersion}` in `com.apple.migration`;
our earlier skip lacked the second key). It removes datamigrator's sentinel
and drops the launchd jobs on their deny list (syncdefaultsd, routined,
homed, duetexpertd, datamigrator, keybagd, ReportCrash, mobileassetd and
others that crash or restart forever here). It also sets
`FBLaunchWatchdogScale = 20`, `ForceNoBuddy` and battery percentage. To be
tested: whether lsd builds LaunchServices from /Applications without the
migration, as it does for them. Cycle: `tools/phone.sh sync
work/ios-root.img` (recovery), `tools/tweak-diff.sh`, then flash
`work/diff.simg` (with approval).
Flashed as a 2.6 MiB diff: 52 launchd jobs removed (all Bluetooth, the Wi-Fi
daemons, routined, syncdefaultsd, homed, keybagd, watchdogd, ...). No job label contains
"datamigrator", so only the done-records skip the migration. fairplayd is not on the
list. `shim-idle8.img` booted on it at 21:58. The run before it (idle8 on the old root)
had 8 cores with real WFI, all handling timers and IPIs.

**Lock screen (2026-10-22 22:01).** The second boot of `shim-idle8.img` on this root reached the iOS
lock screen: 8 cores with real WFI, no migration bar. Together, these got it there:
0111 (keychain wrap), 0112 (no set/way flush on idle) and HackiOS's migration-done
records and job deny list. The first boot of the same image stopped on an "SMP timing"
error (log overwritten, not yet diagnosed), so 8 cores are not fully reliable yet.
Next: touch (GPI DMA), so the lock screen can be swiped away.

### Migration stuck at the end of the bar: keychain (2026-10-22)

Overnight 4-core run with 0107: the bar stopped at the same point (the last
frame at ~193,000 swaps, then static all night). Behind it, routined,
mobiletimerd, liveactivitiesd, fitnesscoachingd, remotepairingdeviced,
calaccessd (~49 launches each), healthd and tccd (~25) kept restarting
without crashing, and `securityd` called AppleKeyStore selector 10
(`aks_wrap_key`) 20 times, which the keystore stand-in refused
(`0xe00002c7`): no keychain item can be written. sweet never hit this
because its migration had completed before the stand-in mattered.
`0111-aks-wrap-unwrap.patch`: wrap = 8-byte marker + key (the size AES key
wrap adds), unwrap checks and strips it (self-consistent, no secrecy, like
the rest of the stand-in). Also: with `wfi=0` and no charger driver the
battery ran flat overnight; let it charge in fastboot/recovery between runs.

### USB networking and live log (not working yet; see "USB on the second phone")

ios-sweet's USB driver (0072-0077, 0081: DWC3 device mode, CDC-ECM network
adapter, console streamed as UDP) uses only addresses the Pixel 3 shares
with sweet: DWC3 `0xa600000`, qscratch `0xa6f8800`, QUSB2 v2 PHY `0x88e2000`
(`qcom,sdm845-qusb2-phy`), GCC `usb30_prim_gdsc` `0xf004`; both ABLs leave
the controller and PHY initialized from fastboot. CI builds `sweet_usb.c`
with `xnu/patches/0108-stage-sweet-usb.sh` (fetches ios-sweet at the pinned
commit, applies only that file) and `0108-blueline-usb-hooks.patch` (build
entry, start call, log helpers). Boot-args: `sweetusb=1` (default) reports
the controller state only, `sweetusb=2` starts the USB device; then on the
Mac `tools/usblog.sh` finds the adapter (host MAC `02:00:5e:77:ee:01`), sets
`192.168.7.1/24` (sudo) and prints/saves the console (UDP 5140) live.

First run (2026-10-22, `sweetusb=2`): controller found and powered, `ue0
192.168.7.2/24` up, soft reset fine, then `ep0 cmd 0x1 timeout` (SETEPCONFIG)
-> no enumeration. ABL had run fastboot at **SuperSpeed** (`DSTS` speed 4,
QMP USB3 PHY; sweet's ABL used USB 2), and the driver's clock table has
SM7150 offsets (SDM845: master `0xf00c`, sleep `0xf010`, mock UTMI `0xf014`,
aux `0xf04c`). `0110-blueline-usb-superspeed-phy.patch`: let the USB3 PHY
suspend (`GUSB3PIPECTL` bit 17, as Linux does for a high-speed-only DWC3;
`blueusb3susp=0` skips), optional `blueusbreset=0` (no soft reset), 20 ms
command timeout, SDM845 clock/PHY diagnostics.
Also from that log: 0106 found the Silver cluster already at its top level
(17 = 1766 MHz); the Gold cluster's cpufreq controller reports "not enabled".

### Volume up (2026-10-22)

GPIO 6 STATUS1 bit 0 follows the key (`0x81` released, `0x80` pressed); the
pull-up (`DIG_PULL_CTL` `0xc542` = 0) was already set. `0109-blueline-volume-up.patch`
reads it as key 1 (`bluevolup=0` skips).

### Wi-Fi

See the 2026-11-19 section below. The full plan (stages 2-5, about 45-100 h to
Settings) lives with the drafts, outside the repo, as `wifi-plan.md`.

### A second phone from scratch, kernel built locally (2026-11-18)

A second Pixel 3 (stock `SP1A.210812.016.C1`, unlocked) set up from the README
on an M1 Mac running macOS 26.6, without CI: GitHub has retired the `macos-14`
runner image, and the newer ones only have Xcode 16+.

- **LineageOS 22.2** `20261116` (sha256 checked against the download API):
  `fastboot flash dtbo_b` / `boot_b`, Recovery mode from the bootloader menu
  (`fastboot reboot recovery` is refused), Format data, `adb sideload` twice so
  both slots have it. `adb` stopping at ~47% with `failed to read command` is
  normal for A/B sideload.
- **Backup**: `tools/backup-phone.sh`, 62 MB, kept off git.
- **Kernel on the Mac**: Xcode 15.4 installed beside Xcode 27 (`xcodes`); its
  command-line tools run on macOS 26 (only harmless duplicate-class warnings
  from DVTDownloads). Built through `DEVELOPER_DIR`, not `xcode-select`.
  darwin-xnu-build wants `sudo installer` for the Kernel Debug Kit; instead
  `pkgutil --expand-full` of `KernelDebugKit.pkg` and `KDKROOT=<Payload dir>`.
  All 95 listed patches applied. The workflow's patch loop must run in bash
  (zsh rejects `[ "$num" \> ... ]`).
- **Shim**: `p2-shim/build.sh` needs Homebrew's keg-only LLVM on PATH
  (`/opt/homebrew/opt/llvm/bin`, `.../lld/bin`); without it `llvm-readelf` /
  `llvm-objcopy` are "command not found" and no `shim.img` is written.
- **Root**: `mkiosroot.sh` on the iPhone X 16.7.16 images, sparse 11 GB,
  `fastboot flash userdata` in 399 s. ABL then hung on the next command, as
  before; Power + Volume Down cleared it.

**A fresh root stops at the Apple logo.** Two boots (`cpus=4 wfi=0`, then
`cpus=8` real WFI, 30 Hz): launchd, backboardd and SpringBoard start, nothing
crashes, backboardd presents 4-7 frames (the logo) and then nothing for 10+
minutes; no DataMigrator. Cause: `iosroot-tweaks.py` writes the
migration-done records (HackiOS's change), so a root that has never migrated
never seeds the LaunchServices database (the `lsd` wait found on 2026-10-21).
The first phone had migrated before those records were added, so it did not
show this. Fix: `tools/phone.sh sync`, `tools/remigrate.sh` (needs the IPSW's
original `System/Library/xpc/launchd.plist` in `work/orig`; copied from the
mounted OS image), 4.4 MB diff. The next boot (8 cores) shows the migration
progress bar.

**Lock screen on the second phone (2026-11-18 23:26).** `cpus=8` (real WFI),
`sweetfb_hz=30`, `sweetfb_noconsole=1`, RAM boot (`fastboot boot`) at 23:08:
the migration bar ran steadily (20% at ~8 min, 80% at ~15 min, no stall near
the end with 0111 in the kernel) and the lock screen followed after about
18 minutes. The 8-core SMP stall did not appear in either 8-core boot.

**Software rendering on the lock screen and home screen.** Laggy (CPU
compositing, 30 Hz copy). The dock, widget backgrounds and Control Center
panels draw as flat white (blur/backdrop materials without a GPU), widgets
stay at "Waiting...", and some Control Center glyphs are garbled. Reduce
Transparency is the first thing to try; not yet checked.

**Screen off on lock (0123, draft).** ios-sweet's 0079 rebased onto 0115:
on the framebuffer's power-off request the vsync timer stops copying frames
and blacks the panel memory (AMOLED: black is off). Tested on the phone
2026-11-18: the power button now blanks the screen and wakes it again. 0079
halves the frame over 7 vsyncs; each pass rewrites ~9 MB on the CPU, so the
fade took visibly long. Changed to one dimmed pass then black: visibly
quicker. DCS sleep (`bluefb_dcs=2`) not tried.

**USB on the second phone (0122 + 0124 draft, `sweetusb=2`).** Nothing
enumerates on the Mac. Log: every GCC clock and the GDSC on, DWC3
GSNPSID 0x5533300a, ABL's SMMU state as on the first phone, controller soft
reset completes in 1 ms, then the first endpoint command (DEPSTARTCFG,
`ep0 cmd 0x1`) times out after 20 ms with the PIPE clock switched to UTMI as
well; DCFG/DSTS after the timeout `00480800`/`00520000`, QUSB2 PLL_STATUS
`0x64`. So the SMMU fix in 0122 is not the blocker and neither is the PIPE
clock; next suspects are the QUSB2/QMP PHY power and reset sequence.

**GPU stage 1: the GMU answers (0125, 2026-11-19).** A boot-arg-gated probe
(`bluegpu=1`) after Linux's a6xx_gmu.c, gpucc-sdm845.c and Google's
crosshatch kernel, cross-checked with ios-flame's and HackiOS's stage 1.
The A6xx has no chip-id register (Linux takes it from the device tree), so
the proof of life is the GMU's always-on counter. On the phone, first try:
ABL leaves `gcc_gpu_cfg_ahb` on and CX/GX collapsed (`0x222001`); cmd-db
gives gfx.lvl `0x30050`, cx.lvl `0x30000`, mx.lvl `0x30010`; the CX GDSC
comes on, memnoc_gfx/ddrss_gpu_axi/cx_gmu/cxo run with the GMU RCG on XO;
the always-on counter reads 19195615 Hz; CM3 held in reset
(`sysreset 0x1`), init result 0, RPMh power state `0xf`, RSCC TCS0-3 `0x1`.
GX left off, RBBM not read; everything restored afterwards, boot unaffected.
Next: GMU firmware (`a630_gmu.bin`) through an Adreno SMMU context, RSCC/PDC.

**GPU stage 2a: GMU firmware running (0126, 2026-11-19).** `bluegpu=3`.
linux-firmware's `qcom/a630_gmu.bin` (88ea23e7, 32 KiB raw Cortex-M3 image:
16 KiB ITCM then DTCM) goes in the Apple device tree (`tools/mkadt.py
--gpu-fw`, `/blueline-gpu` `gmu-firmware`; fetched by
`tools/fetch-gpu-fw.sh`, never committed). Disassembly showed the firmware
reports init before it touches system memory, so no SMMU or HFI is needed
for this step. Sequence after Linux's a6xx_gmu_rpmh_init/fw_start: RSCC
sequencer, GPU PDC (was all 0 as ABL left it), firmware into TCM (9 ms,
read back: 0 bad words), start-up registers, CM3 out of reset. On the
phone: **init result 0xbabeface after 364 us**, fault counters 0, GX
still off, RSCC idle; CM3 back in reset and 66 registers restored; iOS
then booted to the lock screen as usual. The GMU ran at 19.2 MHz from XO.
Next (2b): an Adreno SMMU context for the GMU stream and the HFI queues.

**Faster test loop.** `tools/build-xnu.sh --quick`: after one full build,
only our changed patches are taken out and put back and make relinks:
about 25 s instead of about 25 min.

**Hands-off test loop (2026-11-19).** Three pieces:
- LineageOS recovery in `boot_b` repacked with `ro.adb.secure.recovery=0`
  (`tools/recovery-adb.py`): adb works in recovery without the Enable ADB
  tap (recovery's only adb key source is userdata, which holds iOS).
- 0127 `bluereboot=recovery|bootloader` (`bluereboot_after=gpu|springboard|N`):
  final synchronous flush of the log ring, PM8998 PON `SOFT_RB_SPARE`
  (`0x88f`, reason << 1, through the SPMI arbiter shared with the key
  driver) plus the IMEM restart_reason cookie (`0x146bf65c`), then PSCI
  SYSTEM_RESET. ABL honours it: PON `0x10 -> 0x02`, straight to recovery.
- `tools/phonetest.sh [--quick] ARGS`: build, shim, RAM boot, wait for
  recovery, pull the log, print, back to fastboot.
First run (`bluegpu=3 bluereboot=recovery`): 72 s from the quick build to
the log, nobody touching the phone; GMU init 0xbabeface after 366 us again.

## Pixel 3 facts used here

| What | Value | Source |
| --- | --- | --- |
| Framebuffer | `0x9d400000`, 1080×2160, a8r8g8b8, stride 4320 | mainline `sdm845-google-blueline.dts`, downstream `cont_splash_region` |
| Panel | LG SW43408, DSC, **command mode** (`dsi_cmd_mode`, TE on GPIO 12) | downstream `dsi-panel-sw43408-dsc-fhd-cmd.dtsi` |
| Reboot reason | IMEM `0x146bf65c` = `0x77665500` → fastboot | downstream `sdm845.dtsi` `restart_reason@65c` |
| PS_HOLD | `0x0c264000` | downstream `sdm845.dtsi` |
| GIC | GICD `0x17a00000`, GICR `0x17a60000` (same as SM7150) | mainline `sdm845.dtsi` |
| UFS | `0x1d84000` (same as SM7150) | mainline `sdm845.dtsi` |
| Image header | `text_offset = 0x80000` (recent Pixel 3 bootloaders need it) | mainline Pixel 3 series cover letter |

`dtb/sdm845-google-blueline.dtb` is built from Linux master (2026-10-19).

## Licensing note (historical)

ios-sweet has no license file, so its code isn't copied here. The probe,
shim, ADT and payload tools are written from scratch (the ADT and boot_args
layouts are Apple's formats; the payload/ADT values follow from the
hardware). The kernel build fetches ios-sweet's XNU patches from their
repository at build time and never stores them here; `xnu/patches/` holds
only our own changes on top. Ask the author before publishing kernels or a
fork that reuses their patches.

## 2026-11-19: GPU on screen, hands-off testing, battery, modem

All on the `display-usb` branch, each tested through `tools/phonetest.sh` (see `docs/TESTING.md`).

### GPU
- **0128/0136/0137, stages 2b-4.** The GMU runs through the Adreno SMMU (EL1 can program it), with legacy HFI v1. GX powers on through the GMU. The phone's own `a630_sqe.fw` loads, and CP_MEM_WRITE lands in memory. The PDC gfx address is cmd-db's `gfx.lvl` 0x30050; the 0x30080 that Linux hard-codes is `xo.lvl` here.
- **0144 zap.** TrustZone PAS id 13 loads the zap into `0x8c415000`; then `CP_SET_SECURE_MODE 0`. Before this, the GPU ran in secure mode: every fence landed but no pixels changed. 0138's CP_BLIT fills now draw.
- **0147 resident GPU (`bluegpu=8`).** The GPU stays up and presents iOS: a 2D-engine bilinear blit of the 1125x2436 surface to 997x2160, centred. At 257 MHz the blit takes 6-7 ms, plus about 2 ms of CPU, mostly the cache clean.
- **0151 interrupts, recovery, clocks.**
  - Fences wake on GPU INTID 332.
  - A forced hang (a garbage packet) is caught by RBBM hang detect and recovered by a soft reset plus CP re-init in 1.3 ms; presents carry on, and the home screen is reachable afterwards.
  - `bluegpu_mhz=710` measures 709 MHz, and the blit drops to 1.4 ms.
  - DCVS (`bluegpu_dcvs=1`) and clean mode 2 are not yet tested.
- **Frame rate.** iOS itself renders on the CPU at most about 21 fps. Speeding up the copy doesn't change that; only CoreAnimation on the GPU (stage 6f) will.
- **0153 user client (6d).** IOService `BlueGPU` speaks the msm ABI 1.9; selectors equal the ioctl's low byte. A 32 MiB pool at pa 0xc0000000 maps at GPU VA 0x80000000 (imports at 0xc0000000), with page tables in WCOMB memory. The self-test passes 32/32. Two fixes on the way: a 256 MiB pool doesn't fit the 64 MiB io_map, and the SMMU needs TCR2.SEP=7, or VA bit 31 selects the disabled TTBR1 (a translation fault at 0x80410000).
- **Mesa (6e).** Mesa 26.3.1 freedreno builds for iOS as `bluegl.dylib` (18 MB). Run with `FD_MESA_DEBUG=noubwc,sysmem`. `gles-triangle` passes: FD630, ES 3.2, 0 wrong pixels.
- **EAGL shim (6f).** `blueeagl.dylib` injects into backboardd (`sweetenv=backboardd:DYLD_INSERT_LIBRARIES=/usr/lib/blueeagl.dylib cs_enforcement_disable=1`) and puts EAGL on top of bluegl. Kill switches: `blueeagl=0`, `/var/mobile/blueeagl.off`, and a crash counter that gives up after 3 starts. `eagl-test` passes every pixel check on the CA path. In backboardd, all 5 hooks take and CoreAnimation renders about 80 frames on the GPU (0.7-1.3 ms each), but the screen stays black and backboardd crashes (SIGSEGV near 0x18 in our dylibs); after 3 crashes it falls back to the software renderer. Debugging now.
- **6f in backboardd works (boots eaglbb2-9).** Fixes: `CAEnableDeepFramebuffer=NO` (the window server's framebuffers were 2-plane `'b3a8'`, which the shim can't render into: black screen); bluedrm falls back to USERPTR BOs of its own memory when the 32 MiB pool is full (Mesa crashed on a NULL BO); `BLUE_GPU_SUBMIT_BO_NOSYNC` makes the kernel clean those once instead of at every submit (48 MiB a frame). Frames drop from 30-57 ms to 16-31 ms; SpringBoard, the swipe to the App Library and labels draw on the GPU with no crashes. **0154** fixes the blank app icons: CoreAnimation's GL renderer asks for surfaces around memory it already holds, by selector 6 (refused by sailfish 0206) and by creates carrying `IOSurfaceAddress` (which got fresh zeroed memory). SweetSurface now wraps the caller's range (approach and request layout from HackiOS's MiniIOSurface, APSL); `bluesurf_wrap=0` turns it off.
- **Zero-copy flip (0145, `bluedpu_flip=1`) works.** The display pipes scan out backboardd's surface directly (QSEED3 scales 1125x2436 to 997x2160). With 6f and `bluegpu_mhz=710`: 132 flips and 0 copies in 5 s of swiping, animations at 56 fps, clean 0.7 ms and latch about 7 ms per flip, no underruns or SMMU faults. Without the flip, the copy to the panel capped what you see at 14-22 fps however fast backboardd drew. **0155**: `bluesnap` samples the flipped surface through the same fit geometry, so screenshots show what the panel shows. **0156**: `blueui=1` stands for `bluegpu=8 bluegpu_mhz=710 bluedpu_flip=1 cs_enforcement_disable=1 sweetenv=backboardd:DYLD_INSERT_LIBRARIES=/usr/lib/blueeagl.dylib` (explicit args still win); boot ui1 with just `blueui=1` plus the three dylib pushes: 55–61 fps, flipped snap with icons.

Apps on the GPU path: Settings opens by a scripted tap, scrolls (blurred nav bar) and opens sub-pages, and the home gesture goes back, all drawn correctly (`docs/screenshots/`). Scrolling ran at 41–46 fps: each flip waited ~7.4 ms for the DPU latch, after ~15 ms of drawing. **0157**: a flip returns after the flush. backboardd alternates two pool buffers (slots 0/1, never 2), so its next frame would draw into the buffer still fetched. Instead, a GPU submit that writes an IOSurface waits for the pending latch (`blue_dpu_flip_settle`), overlapping CoreAnimation's CPU work. Waits fell to ~2.5 ms on average, scrolling now runs at 47–58 fps, and snaps show no tearing. `bluedpu_flip_sync=1` restores the old wait. **0158** makes the display hold IOSurface uses (`IOSurfaceIsInUse` reads a u64 at +0x18 of the state page), so 0157's GPU wait applies only to a surface still shown. It didn't change the buffer count. **0159** is the root fix. CoreAnimation (`IOMFBDisplay::can_update_`) polls `SwapWait` (IOMFB selector 6, flags bit 31 = poll) before reusing a swap's buffer and takes another buffer while it answers `0xe00002d5`. SwapWait returned success at once. Now, as in IOMFB, a swap is complete once a later swap's flip has latched. backboardd now cycles 3 pool buffers (slots 0→2→1), and the GPU waited for a latch once in a whole run (was ~70% of frames). Home screen runs at 57–62 fps. Scrolling Settings runs at 44–54 fps, now limited by drawing, not the display. A 10-minute hands-on demo (demo4) averaged 58.5 fps over 752 frames in motion (median run 59 fps), with no panics or flush faults.

Workflow: ABL falls back to slot A after repeated RAM boots, and slot A's LineageOS recovery needed the Enable ADB tap. boot_a now carries the same `tools/recovery-adb.py` image as boot_b (the old boot_a, identical to `stock/boot.img`, is backed up outside git). Slot A recovery was checked: adb comes up with no tap.

**0160**: blueeagl ended every frame with `glFinish`, so CoreAnimation's CPU work and the GPU's drawing ran in series. SwapEnd now queues the swap and returns at once. A kernel flip thread waits for the last GPU submit that wrote each layer surface (`gpuWriteFence`, set at submit), then flips. SwapWait keeps the swap pending until its flip latches. The display publishes `HakiosWaitsForGPU`, and blueeagl drops the `glFinish` when it sees it ("a frame is waited for by the display's driver, not here"). fthr1: every motion run, scroll included, ran at 56.5–60.7 fps. The GPU never waited for a latch, no GPU wait ran late, and the snaps are complete (Safari's start page, `docs/screenshots/`). `sweetfb_flipthread=0` restores the synchronous path.

**Independent (2026-11-19).** The repo left GitHub's fork network and is maintained here on its own. `master` is the main line (display-usb merged as PR #1), and the GPU userland moved into the repo under `gpu/`. The README header credits the original port.

**0161**: `bluetest=1` stands for phonetest's board arguments (battery, LMh, watchdog, framebuffer), the same way `blueui=1` does for the GPU set. That frees about 100 bytes of the 607-byte boot line for `bluetouchscript`.

**Apps (apps1/apps2).** Settings and Safari open and scroll at 55–62 fps on the GPU path. backboardd adds a 4th frame buffer under load; the 3-buffer scanout pool then has none left ("scanout pool empty"), but the extra buffer was hardly used (0 panel copies). The 32 MiB GPU BO pool also fills up after a few apps, and new BOs then come from process memory; fps didn't change.

**Photos** opened to a black screen on both the GPU and CPU paths. The sampler (`sweetsample=MobileSlideShow`) showed the main thread in `MCCopyCheckpointValue`, waiting on checkpointd. checkpointd (FairPlay code) was itself blocked in a MIG call to fairplayd, which restarts forever without a Secure Enclave. With fairplayd dropped from launchd (`iosroot-tweaks.py` DENY; tested by pushing a rebuilt `launchd.plist`), the call fails at once. Photos then throws `NSInternalInconsistencyException: assetsDataSourceManager.dataSource.numberOfSections == 1`: it finds no photo library and never contacts assetsd. The reason is still open. `tools/blueexc` (DYLD-inserted with `sweetenv`, output via `sweetnull`) logs every thrown ObjC exception with its reason and stack.

**Hitches.** Frames of 100–160 ms when an app or effect first appears are shader compiles (frame 6: 101 ms handing 5 draws to Mesa). Mesa was built with `-Dshader-cache=disabled`. The disk cache is now on (`-Dshader-cache=enabled`, zlib; blueeagl sets `MESA_SHADER_CACHE_DIR=/var/mobile/Library/Caches/bluegl`). It barely helped: 8 frames over 30 ms with a warm cache, 10 without. Compiles were not the main hitch.

**Wrapped images read in place.** `glslow=` showed `glBindTexture` taking 8.7 ms per frame for ~30 frames in a row. That was blueeagl hashing an 11 MB picture each frame to see whether it changed (`surface_changed`, until 120 unchanged looks). The picture was copied rather than shared because CoreAnimation wraps its own image memory (0154, rows of 4500 bytes), and Mesa and bluegl required 64-byte rows. The A6xx texture descriptor's PITCH is a plain byte count, so Mesa patch 0005 lets a one-level linear import keep its own pitch. bluegl also rounds the import size to the 4 KiB pages the kernel maps, because a wrapped picture ends at its last pixel. Surfaces used in place went from 12 to 60, copies from 112 to 79, with no faults and identical screenshots.

**What's left of the hitches.** 7–9 frames per app script still take 30–100 ms, at app launches. In the worst of them no single GL call is over 4 ms: the time goes to CoreAnimation's CPU work. `glprof` (now dumping every 1000 samples) puts the GPU submit ioctl at 12–14% of the drawing thread. That submit time is CPU cache maintenance of imported surfaces. 0162 adds it to the 5 s GPU stats line (70–100 ms per 5 s). `bluegpu_lazyclean=1` (clean only on a seed change, and re-clean only wrapped surfaces) didn't change it measurably, so it stays off. GMEM rendering is still untried.

**Home screen.** The "Waiting..." labels are two app placeholders whose install never finished, not widgets. The removable system apps (`/private/var/staged_system_apps`: Weather, Calendar, Maps, ...) are missing, and so is the wallpaper. Remigrated on 2026-11-19 with `remigrate.sh`, which now also applies the current DENY list (fairplayd) via `iosroot-tweaks.py --only launchd`. The 2 MB diff was flashed and the migration boot is `migr1`.

**Why the apps never installed: clonefile.** `migr1` changed nothing. iOS's own log, read with the new `tools/phonelog.sh` (7-Zip pulls `/var/db/diagnostics` out of the image without sudo; mandiant's unifiedlog_iterator decodes it, because `log show` prints nothing for a log clock that starts at 1970), shows SystemAppMigrator starting all ~35 installs. Every one is cancelled: `MIInstallerErrorDomain Code=107 "Failed to stage ..."`, underneath `Code=4 "Failed to clonefile .../Wallet.app/Icon.png"`. installd's staging copies with `copyfile(COPYFILE_CLONE_FORCE)` (`-[MIFileManager _copyItemAtURL:...alwaysClone:...]` passes flags `0x020c800f`), and CLONE_FORCE has no copy fallback. APFS clones; our HFS+ root returns ENOTSUP. The migrator then hands each app to appstored, which can't install offline. The two "Waiting..." icons are left over from that. FairPlay was not involved. 0163 makes `clonefileat` copy instead where `VNOP_CLONEFILE` says ENOTSUP: regular files get a new file with the data copied in the kernel, symlinks are re-made. Remigrated again; the migration boot on 0163 is `migr2`.

**Staged apps used up.** `migr2` gave FaceTime, Contacts, Files, Freeform and a Utilities folder, but only as App Store placeholders (cloud badges). The log has no clonefile errors now; instead "Did not have a staged app" for each. A migration moves each app out of `/private/var/staged_system_apps` into installd's staging, and `migr1`'s failed installs deleted them. `remigrate.sh` now puts the IPSW's 32 apps (305 MB, owner mobile) back from `work/OS.dmg`, extracted with 7-Zip. The migration boot with them is `migr3`.

**migr3: past clonefile, now signatures and extension points.** With 0163 and the staged apps back, installd gets further: no clonefile errors. Contacts and Files show "Waiting..."; FaceTime and Freeform stay placeholders. Two new failures:
- `MIInstallerErrorDomain Code=13 "Failed to verify code signature of .../Contacts.app : 0xe8008001"` (from `+[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:...]`, libmis), 104 times. Apple-signed system apps are normally trusted via the static trust cache; next is checking whether ours is loaded and what libmis asks the kernel/amfid.
- `Code=59 "Appex bundle ... specifies a value (com.apple.usernotifications.content-extension) for NSExtensionPointIdentifier ... that does not correspond to a known extension point"`, from `Code=142 "Extension cache does not have an entry for ..."` (also `com.apple.intents-service`). installd's extension-point cache is missing entries.

The PosterBoard assertion text still isn't in the log.

**Signatures: 0164.** The removable system apps are ad-hoc signed (Calculator: `Signature=adhoc`, no certificate) and trusted only through the static trust cache. `tools/bluerun/mistest` runs installd's checks on the phone. `SecStaticCodeCheckValidity` returns -66996 ("signature is valid but signer is not trusted") for any ad-hoc code, Safari included, as on a real iPhone: Security only marks code trusted after a CMS certificate chain. libmis accepts that with `AllowAdHocSigning`, and with `TrustCacheOnly` it then asks the **AppleMobileFileIntegrity IOService** (selector 6, the cdhash as structure input; 0 = in a trust cache, kIOReturnNotFound = not). We had no such service, so every install failed with 0xe8008001. 0164 adds it (`BlueAMFI.cpp`) and also answers `__mac_syscall("AMFI", 0x5f)`, Security's own trust-cache query for code requirements. Both say yes: there is no trust cache, and every root binary already runs as a platform binary. mistest with installd's options now returns 0 for Calculator (signer type 1). lsd asks the service too; online-auth-agent asks selector 9 (unsupported).

The remigrations had also dropped the test runner's launchd job; `remigrate.sh` now keeps it.

**Extension points: same cause.** migr3's second failure ("Extension cache does not have an entry for com.apple.usernotifications.content-extension", Code=142/59) came from installd logging `Failed to read extension point cache ... Unable to find AMFI`. ExtensionFoundation reads `/System/Library/xpc/extensions.plist` (the 138 extension points the OS frameworks declare) only after checking `extensions.plist.sig` through the AppleMobileFileIntegrity service, selector 6. 0164 answers it. `tools/bluerun/miinstall` installs bundles through installd as the migration does, on a normal boot: on 0164, Calculator, Wallet (with its notification extension), Weather and Reminders all install.
- **QuartzCore research.** QuartzCore 16.7.16 falls back to its GL renderer when Metal returns nil, and its GL function table matches HackiOS's 16.5 table exactly.

### Display
- **0140 display probe (`bluedpu`).** ABL leaves CTL_0 in command mode -> INTF_1/DSI0, with VIG0/VIG1 fed from the two 540-column halves of `0x9d400000` (stride 4320), DSC, and autorefresh on PP_0. The panel measures 60.9 Hz. FSR 0x400 is the format field, not a fault.
- **`sweetfb_hz=60`** is now the default.
- **0145 flip** (zero-copy scanout of iOS buffers) is drafted and untested.

### Hands-off testing (no hands on the phone)
- **0146 screenshots and scripted touches.** `bluesnap=sb+N,...` saves 540x1080 shots to userdata below the log ring; `phonetest.sh` pulls them as PNGs. `bluetouchscript=sb+60:swipe,540,2150,540,700,250` unlocks the phone. A swipe at sb+30 is too early to unlock.
- **0148 watchdog** (APSS WDT, on by default): a hang bites into recovery.
- **0152 push and run.** `phonetest.sh --push LOCAL:/path` copies files into the iOS root before launchd (`bluepush=1`, 3 files in 21 ms). `--run /path,args` runs a program after SpringBoard; its output lands in the log as `BLUERUN:` lines. Ad-hoc signed arm64 binaries run as platform binaries. The runner's launchd job was installed by pushing a modified `System/Library/xpc/launchd.plist`, with no image flash.
- **`tools/patch-check.sh`** checks a draft patch in a clone of the built tree: apply, then compile with the build's own clang line. `docs/AGENTS.md` is the shared brief for drafting agents.
- **Build fix.** A hand-fixed `patch-list.txt` had silently dropped the pinned sailfish patches 0200-0208 (sweetenv, AMFI dyld policy, IOSurface) from quick builds. `build-xnu.sh --quick` now always keeps them. A full rebuild takes 3 minutes.
- **Workflow notes.**
  - ABL counts each RAM boot as a failed slot-B boot, so `phonetest.sh` runs `fastboot --set-active=b` first.
  - If fastboot can't see the phone for 60 s, it stops and asks for a replug.
  - `bluereboot_after` takes only `gpu`, `springboard` or N seconds; add `bluereboot_delay=S` for a delay.

### Other hardware
- **Battery (0130 + 0141).** The MAX17201 gauge reports real numbers (99%, 4335 mV, 476 cycles, 2445/2944 mAh). Open: after unplugging, it still shows charging (PMI8998 USBIN stays 0x10). The plug test is deferred.
- **0129 RTC.** The time is right. A wrong time before was iOS using the Cupertino time zone; set it in Settings.
- **0139 CPU clocks / 0143 LMh.** Gold runs at 2649 MHz. TrustZone accepts every LMh call, so the hardware throttles on heat.
- **0135 rotation.** A fake accelerometer: pressing both volume buttons together, or `bluefakeaccel_cycle`, rotates the screen; seen working in Safari.
- **0150 brightness and haptics.**
  - Brightness: DCS 0x51 writes work (a 17-step ramp, 0 failures). backboardd calls IOMFB selectors 50 and 68.
  - Haptics: the vibrator is a Cirrus CS40L20, not the DRV2624. With `bluehaptic=2` its firmware (vendor `cs40l20.wmfw`/`.bin`, embedded in the ADT) loads, the DSP runs with 24 waveforms, and `/dev/bluehaptic` takes `click N` and `vibe MS`.
  - The buzz itself hasn't been felt yet.
- **0149 modem (Wi-Fi stage 2).** The phone's DTB says MBA self-auth, not PAS. Firmware is read only from `modem_b`. AOP and RPMh votes work, MP_ASSIGN works, the MBA boots, and the 64 MiB MPSS image authenticates. SMP2P reports READY. 40 s later the modem goes ERR-FATAL as expected: there is no rmtfs yet (stage 3). No partition is written.

**migr4: the system apps install.** On the 0164 kernel the first-boot migration installed all 32 removable system apps, extensions included: Weather, Stocks, Find My, Home, Books, Contacts, Translate, Files, Shortcuts, Freeform, Tips, Wallet, Reminders and the rest, with their own icons (`docs/screenshots/2026-11-20-system-apps.png`). Still open: the wallpaper is black and the two default widgets show only their titles.

**migr5: wallpaper.** The LaunchServices database was built on the very first boot, before 0164, when `extensions.plist` could not be read, so it had no records for the system's own extensions (lsd: "could not find extension record", 57 times). PosterBoard then found only Weather's poster extension and failed to set up the system providers (`com.apple.WallpaperKit.CollectionsPoster`, `com.apple.PaperBoard.LegacyPoster`: PBFPosterExtensionDataStoreErrorDomain -2220), so the wallpaper was black and the widgets were empty. Removing the database alone leaves SpringBoard at the Apple logo (lsd waits for a seed), so migr5 removed it and ran the migration again, with `tools/remigrate-push.sh` (no sudo, no flash: the apps go in over two short boots, the reset with the migration boot). Result: the stock iOS 16 wallpaper on the lock and home screens, the Weather and Photos widgets drawn, all apps installed and launching (`docs/screenshots/2026-11-20-home-wallpaper.png`).

Still wrong (seen by hand): the App Library blurs the wallpaper and then shows black; Control Center's pull-down glitches; the lock screen's shortcut buttons don't draw; the Photos widget is black (empty library?); Weather has no data (no network). The first three all use wallpaper-derived materials. Thin black bars show at the left and right edges (1125-wide iOS scaled to the panel).


## 2026-11-20: blurs, Wi-Fi up to the WLAN firmware service

**Blurs (e9c38e8).** The black App Library and Control Center backgrounds were the display's colour gamut. The ADT said nothing, so iOS took the D22's P3 panel and asked CoreAnimation for wide-gamut (`b3a8`, 10-bit) blur surfaces, which our GL path can't draw: they came out black. `tools/mkadt.py` now says `artwork-display-gamut = sRGB`. MobileGestalt caches the answer, so its cache has to go once (`--rm` of `com.apple.MobileGestalt.plist` under the mobilegestaltcache system group). Afterwards the App Library and Control Center blur the wallpaper as they should, and the weather widget draws.

**Wi-Fi stage 3a/3b (0165, 0166).** The modem boots (stage 2), then stays up:
- 0165: GLINK over SMEM with the modem (items 478-480, APCS IPC bit 12), the IPCRTR channel open 5-16 ms after the modem is ready, and QRTR on top (HELLO, server announcements).
- 0166: rmtfs (service 14), serving the EFS partitions on UFS LUN 5 (modemst1/2, fsg, fsc) **read only**. The modem's writes are acknowledged and dropped; nothing is ever written to flash. Also pd-mapper (0x40), with mainline's sdm845 table.
- Result (wifi4a): the modem reads its EFS (4 reads, 4224 sectors), announces 36 services and stays up for the whole 200 s watch, instead of ERR-FATAL at 40 s.

**Wi-Fi stage 3c (0167).** TFTP over QRTR (service 4096) serves `wlanmdsp.mbn` from the device tree (`mkadt --wlan-fw`, from the vendor image's `/firmware`; the blobs stay out of git). The `/readwrite/` files the modem writes stay in RAM for the boot. Result (wifi4c): the modem reads the 3 MB image (2965 blocks of 1 KiB), starts its WLAN domain, and **WLFW (service 0x45), the WLAN firmware's control service, comes up**. 

**Wi-Fi stage 3d (0168, `bluewifi=5`): the WLAN chip is up.** The kernel votes the WCN3990's rails on through RPMh (L5a 0.8 V, L7a 1.8 V, L17a 1.304 V, L25a 3.104 V, RF_CLK2), then drives WLFW as ath10k does on SDM845. Result (wifi5a):
- The modem reports two MSA regions (16 KiB secure, then the rest of the 1 MiB at 0x8df00000), and both are handed to the modem and the WLAN VMs (MP_ASSIGN ok).
- MSA READY comes back after 54 ms.
- Capabilities: chip 0x30214 (WCN3990), soc 0x40030001, firmware `WLAN.HL.2.2.3-00526-QCAHLSWMTPLZ-1`.
- The board data goes over (26328 bytes, 5 segments), with the cal report.
- The pin-connect result arrives, then **FW READY 3.3 s after the start**, then the copy-engine config and mission mode.
- The modem stays up for the whole watch.

Next is stage 4: ath10k's data path (the copy engines and HTC/WMI over the WCN3990's register space) and a scan.

**Control Center glyphs (0169).** The striped icons (airplane, cellular, flashlight, calculator, camera, the lock screen's buttons) were sheared pictures, not a bad draw. blueeagl's ASCII dumps of the `LA08` glyph surfaces showed diagonal bands in the surface memory itself. The CPU code that draws them asks for its own row (e.g. 105 px in 224 bytes) and keeps drawing with it. Sailfish's 0207 rounds every explicit row up to 64 bytes (256) for the GPU's pitch, so each row drifted by 32 bytes. Surfaces that aren't BGRA are always copied into a texture, never shared with the GPU, so 0169 lets them keep the row they ask for (`bluesurf_exactrow=0` turns that off). Result (rows1): every Control Center glyph and the lock screen's camera button draw cleanly (`docs/screenshots/2026-11-20-control-center.png`). The brightness slider then didn't take a drag (by hand or scripted); the drag dismissed Control Center instead.

**Brightness slider (0170).** Without a backlight service, CoreBrightness treats the display as fixed, so the slider is inert. 0150's `bluebl=2` publishes `AppleARMBacklight` (`backlight-control`). backboardd then drives it: slider moves arrive as `brightness` requests (raw 0..65536) and go to the panel as DCS 0x51 writes (bl2a: `raw 7369 -> level 101`, then 109, 115 ..., every write ok in ~7 ms). Confirmed by hand. 0170 makes it the default; `bluebl=1` leaves the service out.

**Control Center blink (open).** By hand: while the brightness module expands, Now Playing and other cards blink out for a frame, and animations sometimes step back and forward. Burst snaps (sub-second `bluesnap=` times work) caught it once in six automated runs (flick1): with Control Center sitting open, consecutive snaps cycled through three pictures (the finished panel, the panel mid-way through opening, and the lock screen from seconds before), one per pool buffer. So each display buffer held the last full frame it was given, and only small redraws landed after. What is ruled out:
- The display side. 0171 (`bluefb_swaplog=N`) logs each swap as shown: every one was a single-layer flip of one of backboardd's three pool buffers, never a snapshot surface. The flip thread never timed out on the GPU wait and never dropped a queued swap.
- blueeagl's every-8-frames check of still pictures (`glstill=0` still blinks).
What is left is blueeagl's mirrored display targets: CoreAnimation draws into a texture of blueeagl's, which is copied whole into the surface at each frame end and never reloaded from the surface. A partial redraw into a stale texture would put an old frame on screen around the redrawn box. blueeagl now reloads a display texture whose surface's seed moved since its own copy (`glresync=0` turns that off). It never fired in the clean runs; the failure seems timing-dependent (both failing runs had rate-limited logging, all four clean ones `blueeagl_lograte=0`). Next: a demo boot filmed in slow motion, matched against the frame log.

**The filmed blink, and target_carry.** A slow-motion video of the glitch showed the same cycling by hand: frames from earlier states flash in for one refresh. The resync never fired in that boot either, so the surfaces were not changed behind blueeagl's back. Instead CoreAnimation redraws only the damaged area into whichever pool buffer comes next, assuming the buffer already holds the previous frame. That is true for a real swap chain only when a buffer is "preserved" from the last frame, and with three pool buffers each one is two frames old. blueeagl now starts each frame's first draw into a pool target by copying the texture sent out last into it (`target_carry`, a full-size `glBlitFramebuffer`; `glcarry=0` turns it off). It fires as designed (demo6); confirmation by hand is pending.

## 2026-11-20: Wi-Fi stage 4, the first scan

**Copy engines, HTC, WMI (0172).** Ported from ios-topaz's 0123 and ios-flame's HTT setup, checked against ath10k. The WLAN stream (0x40) gets an identity context bank in the apps SMMU, and a 16 MiB DMA pool holds the rings and buffers. Then the copy engines at 0x18A40000 come up, and so do HTC (READY, two 2184-byte credits), the HTT (endpoint 1) and WMI (endpoint 2) services, WMI SERVICE_READY → INIT → READY, and HTT version 3.92 with its RX ring. The firmware's MAC is set over WLFW (0x33) to a locally administered address.

**The silent scan.** START_SCAN was accepted (its credit came back) but no scan event ever arrived. To find out why:
- A WMI ECHO sent during the stall came back in 6 ms, so the firmware was still taking commands.
- The firmware's own log (WLFW INI 0x2f, `enablefwlog`; `bluewifi_fwlog=0` turns it off) arrives as WMI DIAG events, 1.5 KB every ~7 s. Decoding it needs Qualcomm's message tables.
- `bluewifi_scanmode` (bit 1: no host channel list, 2: no scan channels, 4: no regdomain) split the problem. Without the channel list, scans start and finish at once, empty. With it, they never start.
- `bluewifi_nch=N` (only the first N channels): 1 channel found a network, and the 13 2.4 GHz channels found 15 networks, -40 to -92 dBm, in three scans in a row (wifi6i). So the radio works, and the stall is in 5 GHz.

**5 GHz (open).** A single 5 GHz channel (36) in the scan is enough to stall it; a channel list holding 5 GHz entries is fine, since 2.4 GHz scans with it (`bluewifi_nscan=13`). No STARTED event, and every WMI credit comes back. Tried without effect: `WMI_CHAN_FLAG_DFS` on radar channels (as ath10k), no VHT flag, regdomain 0x3a (FCC3_FCCA, the firmware's own), L25a at 3.312 V, and hardware mode 0. SERVICE_READY_EXT lists two modes, single-PHY with both bands and DBS (5 GHz on phy 0, 2.4 GHz on phy 1). PDEV_SET_HW_MODE 0 was answered with status 0 and no transition, so it was already in mode 0. ios-topaz scanned the same 37 channels the same way. The default scan is the 13 2.4 GHz channels (`bluewifi_nch=37` for all) while the next stages go on.

L25a is now 3.312 V, as in the Pixel 3's upstream device tree (`bluewifi_ch0mv`); it was 3.104 V.

### Wi-Fi in iOS, and a live channel over USB (2026-11-20)

**Station (0172, after ios-topaz 0125-0130).** Auth, association and the WPA2 4-way handshake in the kernel; HTT TX of data frames and the in-order RX indications (0x12) into `en0`. A firmware assert on teardown (`wlan_vdev.c:_wlan_vdev_down:3785`, VDEV_DOWN with the peer still there) went away with Linux's order: deauth, PEER_DELETE, VDEV_DOWN, VDEV_STOP (`bluewifi_td`).

**en0 and Apple80211 (0173, ios-topaz 0900 from HackiOS).** Two things kept wifid from starting: launchd only starts it with a `/arm-io/wlan` device-tree node (`mkadt.py` adds it), and the iosroot tweaks had removed its job (`tools/launchd-build.py` builds a launchd.plist that keeps chosen jobs). Then wifid scanned and joined from Settings (the PMK comes from wifid, typed on the phone), but no frame was ever sent: the migrated root's configd `preferences.plist` held only `__VERSION__`, so `en0` (named fine by InterfaceNamer) had no network service and IPConfiguration never brought it up. `tools/configd-prefs.py` writes one set with a DHCP Wi-Fi service. Last, the radio's poll loop is the watcher thread, which ended after at most 600 s: scans then timed out (error 60) and the list in Settings spun. `bluewifi_watch=0` keeps it for good. **Result: joined from Settings, DHCP address and router, Safari loaded google.com** (14 MB in, 0.5 MB out, nothing dropped).

**USB (0176).** The DWC3 timed out on SETEPCONFIG because ABL leaves the QUSB2 PHY powered down (`PWR_CTRL1 0x23`, PLL not ready): clearing the power-down gives CORE_READY at once, and the Mac enumerates "Sweet iOS (USB Ethernet)". The Mac's service is set once to 192.168.7.1 (`networksetup -setmanual`, no sudo); then `tools/usb-live.py` has the kernel log live and `tools/bluesh.py` (with `tools/bluerun/bluesh.c` on the phone) runs programs, copies files and ends the session (`kern.bluedone`, 0175). First use: backboardd crashed in Safari (a texture described bigger than its IOSurface, read past its end in `surface_changed`); fixed, pushed, and backboardd restarted on the new library in about two minutes, without a reboot.

**Test-loop tooling.** Shim pause off by default (`bluepause=N`); `wifi-patch.sh` rebuilds the one file (55 s -> 23 s); frame fingerprints (`print,N` in `bluetouchscript`, 0174) with `tools/fpblink.py` to find blinks without a camera; `bluerun_end=reboot`.

**Control Center blink.** `glwait=1` (a full GPU wait every frame) did not stop it, so it is not a GPU/display race. The carry pool (blueeagl) kept its first three display buffers for good, while CoreAnimation replaces its display buffers over time (textures 1 and 4 attached again to new surfaces); later ones were never carried into and showed old pictures where not redrawn. Pool places are now freed when a display buffer goes. To be confirmed by hand and with fingerprints.

**Native panel size (`sweetfb_native=1`, native1).** The framebuffer reports 1080x2160 and the DPU flips 1080x2160 pool buffers, but iOS still makes its canvas at the iPhone X's 1125x2436 (from MobileGestalt, not the display): backboardd drew 30 frames and stopped; the screen stayed black through power and swipe. Filling the panel needs iOS itself told another screen size (MobileGestalt main-screen keys), or a scale that fills the width (crops 90 px at top and bottom), or a slight stretch. Default stays fit (997x2160, 41 px bars).

**Live control (0177).** `tools/bluesh.py snap` and `touch` drive the running phone: unlock, open Settings, tap a network, all from the Mac. Found: the saved Wi-Fi password does not survive a reboot (Settings asks again), so no auto-join; the stand-in keystore is the suspect.

**Filling the panel (0178).** `bluefb_fit=N` picks how iOS's 1125x2436 picture lands on the 1080x2160 panel, in the DPU flip (QSEED3), touch mapping and snaps alike: 1 fit to height (default; 41-px bars), 2 fill the width (rows 93-2342 of 2436: status bar and home indicator cut), 3 stretch (whole picture, 8% squashed vertically). Tested remotely (fill2, stretch3): unlock, a tap on Settings lands, the home gesture works in both. The CPU-copy path (before the first flip) still draws fit-to-height. Screenshot: docs/screenshots/2026-11-20-display-fit-fill-stretch.png.

**Wi-Fi password forgotten at reboot.** All 18 keychain items were created in the current boot (keychain-2.db pulled over bluesh): the keychain is emptied at every start, not just the Wi-Fi item. Unwraps through the stand-in keystore succeed, so the suspect is how securityd sees the keybag at start (its identity or state from SweetKeyStore), next to trace.
