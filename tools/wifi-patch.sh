#!/bin/bash
# Rebuild xnu/patches/0172-blueline-wifi-radio.patch from the working copy in
# work/wifi (head.txt = patch header, base.c = file before 0172, new.c = the
# edited file), then quick-build the kernel. Usage: tools/wifi-patch.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
W=work/wifi P=xnu/patches/0172-blueline-wifi-radio.patch F=bsd/dev/blueline_wifi.c
for f in head.txt base.c new.c; do [ -f "$W/$f" ] || { echo "missing $W/$f" >&2; exit 1; }; done
{ cat "$W/head.txt"; diff -u --label "a/$F" --label "b/$F" "$W/base.c" "$W/new.c" || true; } > "$P.tmp"
mv "$P.tmp" "$P"
echo "0172: $(grep -c '^[+-]' "$P") changed lines"
[ "${1:-}" = --no-build ] && exit 0
if ! tools/build-xnu.sh --quick > /dev/null 2>&1; then
	grep -E 'blueline_wifi.c:[0-9]+:[0-9]+: error' work/kbuild/build-quick.log | sed 's|.*/blueline_wifi.c:|new.c:|' | sort -u | head -20
	echo "build FAILED (work/kbuild/build-quick.log)"; exit 1
fi
grep -E 'blueline_wifi.c:[0-9]+:[0-9]+: warning' work/kbuild/build-quick.log |
	grep -v 'declaration-after-statement\|cast-align' | sed 's|.*/blueline_wifi.c:|new.c:|' | sort -u | head -10 || true
echo "build ok"
