#!/bin/bash
# oslog-pull.sh - the phone's iOS unified log (os_log) as JSON lines on the Mac, over bluesh (no reboot).
#
#   tools/oslog-pull.sh OUT.jsonl [N] [UUID-PATH...]
#
# Copies the newest N (default 2) tracev3 files of Persist and Special, the timesync files and the
# given uuidtext files (format strings: /private/var/db/uuidtext/XX/REST, XX/REST being the binary's
# UUID without dashes, e.g. 1B/5B4AA32EF13306A4D94088A36F52B3 for thermalmonitord, from
# dwarfdump --uuid) into a logarchive, and parses it with mandiant/macos-UnifiedLogs (Apache-2.0,
# built once into work/ul-src). Apple's log show refuses the partial archive.
# Needs a bluesh session (bluerun=/usr/local/bin/bluesh, sweetusb=2) with bluels pushed.
# Read it with e.g.:
#   python3 -c 'import json,sys; [print(e["process"], e["message"]) for e in map(json.loads, open(sys.argv[1]))]' OUT.jsonl
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; n=${2:-2}; shift $(( $# > 1 ? 2 : 1 ))
ul=work/ul-src/examples/target/release/unifiedlog_iterator
if [ ! -x "$ul" ]; then
	[ -d work/ul-src ] || git clone -q --depth 1 https://github.com/mandiant/macos-UnifiedLogs work/ul-src
	cargo build -q --release --manifest-path work/ul-src/examples/unifiedlog_iterator/Cargo.toml
fi
a=$(mktemp -d)/phone.logarchive
mkdir -p "$a"
D=/private/var/db/diagnostics
for sub in Persist Special timesync; do
	mkdir -p "$a/$sub"
	k=$n; [ $sub = timesync ] && k=4
	for f in $(python3 tools/bluesh.py run -t 20 /usr/local/bin/bluels $D/$sub | awk '$5 ~ /\.(tracev3|timesync)$/ {print $5}' | sort | tail -n $k); do
		python3 tools/bluesh.py get "$D/$sub/$f" "$a/$sub/$f" > /dev/null
	done
done
python3 tools/bluesh.py get $D/version.plist "$a/version.plist" > /dev/null
for u in "$@"; do
	mkdir -p "$a/$(dirname "$u")"
	python3 tools/bluesh.py get "/private/var/db/uuidtext/$u" "$a/$u" > /dev/null
done
"$ul" -m log-archive -i "$a" -o "$out" > /dev/null 2>&1
echo "$out: $(wc -l < "$out") entries from $(ls "$a"/Persist "$a"/Special | grep -c tracev3) tracev3 files"
rm -rf "${a:?}"
