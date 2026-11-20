#!/bin/bash
# A lean Wi-Fi boot test: no UI, radio up, 30 s of watching, then back to
# recovery; prints tools/radio-summary.sh and removes the test images.
# Usage: tools/wifitest.sh NAME [--nets] [extra boot-args...]
set -uo pipefail
cd "$(dirname "$0")/.."
name=$1; shift
sumargs=() args=()
for a in "$@"; do case $a in --nets|--all) sumargs+=("$a") ;; *) args+=("$a") ;; esac; done
watch=30
for a in "${args[@]:-}"; do case $a in bluewifi_watch=*) watch=${a#*=} ;; esac; done
tools/phonetest.sh --name "$name" --wait 8 --grep 'panic|radio:|watcher done' --end recovery \
	bluewifi=6 bluewifi_step=4 bluewifi_watch="$watch" bluereboot=recovery bluereboot_after=$(( watch + 25 )) \
	"${args[@]:-}" > "work/test/$name-run.txt" 2>&1
rc=$?
tools/radio-summary.sh "$name" "${sumargs[@]:-}"
find work/test -maxdepth 1 \( -name '*.bin' -o -name '*-shim.img' \) -type f -delete
exit $rc
