#!/bin/bash
# Summarise a Wi-Fi test run's radio log: work/test/NAME.txt. Network names are
# replaced by <named>/<hidden>; BSSIDs are already masked by the kernel.
# Usage: tools/radio-summary.sh NAME [--nets] [--all]
cd "$(dirname "$0")/.."
log=work/test/$1.txt; shift
[ -f "$log" ] || { echo "no $log" >&2; exit 1; }
pat='scan [0-9]+ done|summary|panic|join|teardown|ERR-FATAL|crash reason|wpa|htt tx|keys|ready for|watcher done|FAIL|timed out|wlfw: (chip|stopped)'
for a in "$@"; do
	case $a in --nets) pat="$pat|net +[0-9]+:" ;; --all) pat='.' ;; esac
done
LC_ALL=C grep -a 'BLUELINE WIFI\|panic' "$log" | sed 's/^.*\(BLUELINE WIFI: \|panic\)/\1/; s/^BLUELINE WIFI: //' |
	sed -E "s/'<hidden>'/<hidden>/; s/'[^']*'\$/<named>/" | grep -E "$pat" | cut -c1-220
