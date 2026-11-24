#!/bin/bash
# One power measurement, start to finish (patch 0197's bluebatt_usb_off):
#
#   tools/pwr.sh [--quick] [--on S] [--off S] NAME [BOOT-ARGS...]
#
# Boots with the USB input suspended (the battery gauge then reads the phone's
# own draw with the cable in), leaves SpringBoard on for --on seconds (default
# 120), presses power, leaves the screen off for --off seconds (default 300),
# presses power again, waits another --on, reboots to recovery and prints
# tools/pwrsum.py's table: mA, flips/s and timer/IPI rates per phase.
# BOOT-ARGS are added (e.g. bluegpu_dcvs=1). Files: work/test/NAME*.
set -euo pipefail
cd "$(dirname "$0")/.."
quick= on=120 off=300
while [ $# -gt 0 ]; do
	case $1 in
	--quick) quick=--quick; shift ;;
	--on) on=$2; shift 2 ;;
	--off) off=$2; shift 2 ;;
	-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
name=${1:?NAME}; shift
t1=$on t2=$(( on + off )) end=$(( 2 * on + off ))
tools/phonetest.sh $quick --name "$name" --wait $(( end / 60 + 8 )) \
	--grep 'BLUELINE (BATTERY: USB|SCRIPT: step|REBOOT)' \
	bluetest=1 bluebatt_secs=10 bluebatt_log=200 bluebatt_usb_off=$(( end + 60 )) \
	"bluetouchscript=sb+$t1:key,power/sb+$t2:key,power" \
	bluereboot=recovery bluereboot_after=springboard bluereboot_delay=$end "$@"
tools/pwrsum.py "work/test/$name.txt"
