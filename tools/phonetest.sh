#!/bin/bash
# One hardware test, start to finish, with no hands on the phone:
#
#   tools/phonetest.sh [--quick] [--name NAME] [--grep REGEX] [--wait MIN]
#                      [--push LOCAL:DEVPATH[:MODE[:UID:GID]]]... [--rm DEVPATH]...
#                      [--run 'DEVPATH[,ARG...]'] [--run-timeout S] [--end recovery|fastboot]
#                      [BOOT-ARGS...]
#
#   --quick   rebuild the kernel first (tools/build-xnu.sh --quick)
#   --name    names the files in work/test/ (default: a timestamp)
#   --grep    lines of the log to print (default 'BLUELINE')
#   --wait    minutes to wait for recovery (default 5; 30 without bluereboot=)
#   --push    put a file (or a directory) into the iOS root before this boot,
#             no image round trip (patch 0152; tools/iosfs-push.sh): written
#             from recovery into userdata's payload area, applied by the kernel
#             with bluepush=1 before launchd starts. Repeatable. --rm removes.
#   --run     run that program once SpringBoard is up (tools/bluerun, launchd
#             job from tools/bluerun/setup.sh, once) with a timeout (default
#             60 s); its stdout/stderr come out as "BLUERUN: ..." lines in the
#             log. Pushes tools/bluerun/out/bluerun too, and unless BOOT-ARGS
#             have bluereboot=, reboots to recovery after SpringBoard + timeout.
#   --end     where the phone is left (default fastboot; recovery with --push,
#             so the next --push test starts there)
#   BOOT-ARGS are added to the usual ones, e.g. bluegpu=3 bluereboot=recovery
#
# A userland test, start to finish (tools/bluerun/build.sh builds hello):
#   tools/phonetest.sh --name hello1 --push tools/bluerun/out/hello:/usr/local/bin/hello \
#     --run /usr/local/bin/hello,one,two --run-timeout 20
#
# With bluesnap=, bluesnap_on_reboot=1 or bluetouchscript= in BOOT-ARGS the
# kernel's screenshots are pulled too, as work/test/NAME-snapN.png (patch
# 0146), e.g. to look at SpringBoard and swipe up from the bottom edge:
#   tools/phonetest.sh --name home1 --grep 'BLUELINE (SNAP|SCRIPT|REBOOT)' \
#     bluesnap=sb+20,sb+40 bluesnap_on_reboot=1 \
#     'bluetouchscript=sb+25:swipe,540,2150,540,900,300' \
#     bluereboot=recovery bluereboot_after=springboard bluereboot_delay=50
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
pushes=() run= run_timeout=60 end_in=
while [ $# -gt 0 ]; do
	case $1 in
	--quick) quick=1; shift ;;
	--name) name=$2; shift 2 ;;
	--grep) grep=$2; shift 2 ;;
	--wait) wait=$2; shift 2 ;;
	--push) pushes+=("$2"); shift 2 ;;
	--rm) pushes+=(--rm "$2"); shift 2 ;;
	--run) run=$2; shift 2 ;;
	--run-timeout) run_timeout=$2; shift 2 ;;
	--end) end_in=$2; shift 2 ;;
	-h|--help) sed -n '2,50p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
extra="$*"
if [ -n "$run" ]; then
	[ -x tools/bluerun/out/bluerun ] || tools/bluerun/build.sh > /dev/null
	pushes+=(tools/bluerun/out/bluerun:/usr/local/bin/bluerun)
	extra="$extra bluerun=$run bluerun_timeout=$run_timeout"
	case " $extra " in *" bluereboot="*) ;; *)
		extra="$extra bluereboot=recovery bluereboot_after=springboard bluereboot_delay=$(( run_timeout + 20 ))" ;;
	esac
	grep="$grep|BLUERUN"
	: "${wait:=$(( (run_timeout + 20) / 60 + 6 ))}"	# boot to SpringBoard, then the test
fi
[ ${#pushes[@]} -gt 0 ] && extra="$extra bluepush=1" && : "${end_in:=recovery}"
: "${end_in:=fastboot}"
base='debug=0xc serial=3 cpus=8 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=60'
# real time of day: work/rtc-offset = Mac time minus the raw PM8998 RTC count (see rtc*-rtc.txt)
base="$base bluebatt=1 bluemax=2 bluelmh=1 bluewdt=30 bluewdt_recovery=1"
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
[ -f work/fw/vendor/cs40l20.wmfw ] && [ -f work/fw/vendor/cs40l20.bin ] && fw+=(--haptic-fw work/fw/vendor)	# 0150
python3 tools/mkadt.py --ufs --cpus 8 --iphone work/DeviceTree.d22ap.im4p "${fw[@]}" "$out/$name.adt" > /dev/null
python3 tools/mkpayload.py "$kernel" "$out/$name.adt" "$out/$name-payload.bin" --cmdline "$base $extra" > /dev/null
PATH=/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:$PATH p2-shim/build.sh "$out/$name-payload.bin" stock/boot.img > "$out/$name-shim.txt" 2>&1
mv p2-shim/out/shim.img "$out/$name-shim.img"
say "shim $out/$name-shim.img ($(shasum -a 256 "$kernel" | cut -c1-12) kernel), args: $extra"

if [ ${#pushes[@]} -gt 0 ]; then
	python3 tools/mkpush.py "$out/$name-push.bin" --name "$name" "${pushes[@]}" > "$out/$name-push.txt" ||
		{ cat "$out/$name-push.txt"; exit 1; }
	if ! adb devices | grep -q 'recovery$'; then
		# slot B's boot is LineageOS recovery: a plain restart lands there (docs/TESTING.md)
		say "getting the phone to recovery for the push"
		fastboot devices | grep -q fastboot || { say "phone is neither in recovery nor in fastboot"; exit 1; }
		fastboot --set-active=b > /dev/null 2>&1 || true
		fastboot reboot > /dev/null 2>&1
		for _ in $(seq 1 60); do adb devices | grep -q 'recovery$' && break; sleep 3; done
		adb devices | grep -q 'recovery$' || { say "no recovery after 3 min"; exit 1; }
	fi
	say "pushing $(grep -c '^  ' "$out/$name-push.txt") entries ($(( $(stat -f %z "$out/$name-push.bin") >> 10 )) KiB)"
	tools/iosfs-push.sh --payload "$out/$name-push.bin" >> "$out/$name-push.txt" 2>&1 ||
		{ cat "$out/$name-push.txt"; exit 1; }
fi

if adb devices | grep -q 'recovery$'; then
	say "phone in recovery: rebooting it to fastboot"
	adb reboot bootloader
fi
# ABL counts each RAM boot as a failed slot-B boot and eventually falls back to
# slot A (no tap-free adb there); re-marking B active resets its retry count.
for _ in $(seq 1 60); do fastboot devices | grep -q fastboot && break; sleep 1; done
if ! fastboot devices | grep -q fastboot; then	# fastboot would otherwise wait forever, silently
	say "phone not visible to fastboot after 60 s; if its screen shows fastboot, replug the USB cable (or hold Power + Volume Down)"
	exit 1
fi
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
case " $extra " in
*" bluesnap="*|*" bluesnap_on_reboot="*|*" bluetouchscript="*)
	say "pulling the screenshots"
	tools/phone.sh snaps "$out/$name" || say "no screenshots"
	;;
esac
if [ "$end_in" = recovery ]; then
	say "done: $out/$name.txt; phone left in recovery"
else
	adb reboot bootloader
	say "done: $out/$name.txt; phone back to fastboot"
fi
