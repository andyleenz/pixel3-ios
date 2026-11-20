#!/bin/bash
# Read iOS's own log (os_log, what `log show` gives on a real device) from the
# root image, without sudo or a mount.
#
#   tools/phonelog.sh [-i IMG] REGEX        lines whose JSON matches REGEX
#
# IMG defaults to work/ios-root.img; sync it first (tools/phone.sh sync IMG).
# Needs 7-Zip (brew install sevenzip) and mandiant's unifiedlog_iterator
# (github.com/mandiant/macos-UnifiedLogs, examples/unifiedlog_iterator, built
# with cargo) on PATH or in $UNIFIEDLOG. macOS's own `log show` prints nothing
# for these logs: the phone's log clock starts at 1970.
#
# Output: one line per entry, "boot time process | message". The full log is
# several GB as JSON, so it is filtered as it is parsed and never written out.
set -euo pipefail
cd "$(dirname "$0")/.."
img=work/ios-root.img
[[ ${1:-} == -i ]] && { img=$2; shift 2; }
[[ $# == 1 ]] || { sed -n '2,14p' "$0"; exit 2; }
ul=${UNIFIEDLOG:-$(command -v unifiedlog_iterator || true)}
[[ -x $ul ]] || { echo "unifiedlog_iterator not found (set UNIFIEDLOG)" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/phonelog.XXXXXX")
trap 'rm -rf "${tmp:?}"' EXIT
# a file still being written when the phone went down can be unreadable; skip it
7zz x -o"$tmp/x" "$img" '*/private/var/db/diagnostics/*' '*/private/var/db/uuidtext/*' -r >/dev/null 2>&1 ||
	echo "phonelog: some log files could not be read (skipped)" >&2
a=$tmp/phone.logarchive
mkdir "$a"
db=$(echo "$tmp"/x/*/private/var/db)
find "$db" -name '*:com.apple.*' -delete       # 7-Zip writes xattrs as files
mv "$db"/diagnostics/* "$db"/uuidtext/* "$a"/
# (run in $tmp: the parser drops an issues.jsonl of warnings in the current folder)
(cd "$tmp" && "$ul" -m log-archive -i "$a" -o /dev/stdout 2>/dev/null) | grep -E -- "$1" | python3 -c '
import sys, json
for l in sys.stdin:
    try:
        j = json.loads(l)
    except ValueError:
        continue
    print(j["boot_uuid"][:6], j["timestamp"][11:23], j["process"].rsplit("/", 1)[-1], "|",
          j["message"].replace("\n", " "))
'
