#!/bin/bash
# One hardware test, start to finish, with no hands on the phone:
#
#   tools/phonetest.sh [--quick] [--name NAME] [--grep REGEX] [--wait MIN] [BOOT-ARGS...]
#
#   --quick   rebuild the kernel first (tools/build-xnu.sh --quick)
#   --name    names the files in work/test/ (default: a timestamp)
#   --grep    lines of the log to print (default 'BLUELINE')
#   --wait    minutes to wait for recovery (default 5; 30 without bluereboot=)
#   BOOT-ARGS are added to the usual ones, e.g. bluegpu=3 bluereboot=recovery
#
# Builds the device tree (with the GMU firmware when work/fw has it), the
# payload and a shim, gets the phone into fastboot (from recovery over adb
# if it is there), RAM-boots it, waits for LineageOS recovery (the kernel's
# bluereboot= sends it there; otherwise do it by hand), pulls the log ring,
# prints the matching lines and sends the phone back to fastboot.
#
# Needs: recovery with adb on and no tap (tools/recovery-adb.py, boot_b,
# slot B active), stock/boot.img, work/DeviceTree.d22ap.im4p, a built kernel.
set -euo pipefail
cd "$(dirname "$0")/.."
quick=0 name=$(date +%Y%m%d-%H%M%S) grep=BLUELINE wait=
while [ $# -gt 0 ]; do
	case $1 in
	--quick) quick=1; shift ;;
	--name) name=$2; shift 2 ;;
	--grep) grep=$2; shift 2 ;;
	--wait) wait=$2; shift 2 ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
extra="$*"
base='debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30'
# real time of day: work/rtc-offset = Mac time minus the raw PM8998 RTC count (see rtc*-rtc.txt)
[ -s work/rtc-offset ] && base="$base bluertc=2 bluertc_offset=$(cat work/rtc-offset)"
case " $extra " in *" bluereboot="*) : "${wait:=5}" ;; *) : "${wait:=30}" ;; esac
out=work/test; mkdir -p "$out"
t0=$(date +%s)
say() { printf '[%3ds] %s\n' $(( $(date +%s) - t0 )) "$*"; }

if [ "$quick" = 1 ]; then
	say "quick kernel build"
	tools/build-xnu.sh --quick work/kbuild > "$out/$name-build.txt" 2>&1 || { tail -20 "$out/$name-build.txt"; exit 1; }
fi
kernel=work/kbuild/out/kernel.development.sweet
fw=(); [ -f work/fw/a630_gmu.bin ] && fw=(--gpu-fw work/fw/a630_gmu.bin)
python3 tools/mkadt.py --ufs --cpus 8 --iphone work/DeviceTree.d22ap.im4p "${fw[@]}" "$out/$name.adt" > /dev/null
python3 tools/mkpayload.py "$kernel" "$out/$name.adt" "$out/$name-payload.bin" --cmdline "$base $extra" > /dev/null
PATH=/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:$PATH p2-shim/build.sh "$out/$name-payload.bin" stock/boot.img > "$out/$name-shim.txt" 2>&1
mv p2-shim/out/shim.img "$out/$name-shim.img"
say "shim $out/$name-shim.img ($(shasum -a 256 "$kernel" | cut -c1-12) kernel), args: $extra"

if adb devices | grep -q 'recovery$'; then
	say "phone in recovery: rebooting it to fastboot"
	adb reboot bootloader
fi
# ABL counts each RAM boot as a failed slot-B boot and eventually falls back to
# slot A (no tap-free adb there); re-marking B active resets its retry count.
for _ in $(seq 1 60); do fastboot devices | grep -q fastboot && break; sleep 1; done
fastboot --set-active=b > "$out/$name-slot.txt" 2>&1 || say "warning: set-active=b failed (see $out/$name-slot.txt)"
say "RAM boot"
tools/fbboot.sh "$out/$name-shim.img" 3 > "$out/$name-fastboot.txt" 2>&1 || { cat "$out/$name-fastboot.txt"; exit 1; }

say "waiting for recovery (up to $wait min)"
end=$(( $(date +%s) + wait * 60 ))
until adb devices | grep -q 'recovery$'; do
	[ "$(date +%s)" -lt "$end" ] || { say "no recovery after $wait min (hung, or still in iOS)"; exit 1; }
	sleep 3
done
# raw PM8998 RTC count as recovery's kernel sees it, with the Mac's clock, for bluertc_offset
{ echo "mac $(date +%s)"; adb shell 'cat /sys/class/rtc/rtc0/name /sys/class/rtc/rtc0/since_epoch' 2>&1; } > "$out/$name-rtc.txt" || true
say "pulling the log"
tools/phone.sh log "$out/$name.txt" > /dev/null
grep -a -E "$grep" "$out/$name.txt" || say "no lines match '$grep'"
adb reboot bootloader
say "done: $out/$name.txt; phone back to fastboot"
