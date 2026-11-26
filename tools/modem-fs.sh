#!/bin/bash
# modem-fs.sh [hw|all] - work/fw/modem/ro: the modem's MCFG files from the OTA's vendor.img
# (/rfs/msm/mpss/readonly/vendor), for mkadt --modem-fs (kernel 0241 serves them over TFTP).
#   hw  (default) mcfg.version and mbn/mcfg_hw (mbn_hw.dig, mbn_hw.txt, the SDM845 hardware MBNs)
#   all also mbn/mcfg_sw (the carrier MBNs, ~10 MB)
# Vendor blobs: work/ is not tracked.
set -euo pipefail
cd "$(dirname "$0")/.."
what=${1:-hw}
D=/opt/homebrew/opt/e2fsprogs/sbin/debugfs
V=work/fw/ota/vendor.img
[ -x "$D" ] || { echo "needs e2fsprogs (brew install e2fsprogs)" >&2; exit 1; }
[ -f "$V" ] || { echo "$V missing" >&2; exit 1; }
t=work/fw/modem/vendor
rm -rf "${t:?}" work/fw/modem/ro
mkdir -p "$t" work/fw/modem/ro/mbn
"$D" -R "rdump /rfs/msm/mpss/readonly/vendor/mbn $t" "$V" 2>/dev/null || true	# (ownership errors only)
[ -f "$t/mbn/mcfg_hw/mbn_hw.dig" ] || { echo "rdump failed" >&2; exit 1; }
cp "$t/mbn/mcfg.version" work/fw/modem/ro/mbn/
cp -R "$t/mbn/mcfg_hw" work/fw/modem/ro/mbn/
# only the hardware MBNs mbn_hw.txt lists
find work/fw/modem/ro/mbn/mcfg_hw -name mcfg_hw.mbn | while read -r f; do
	grep -q -F "${f#work/fw/modem/ro/mbn/}" "$t/mbn/mcfg_hw/mbn_hw.txt" || rm -f "$f"
done
[ "$what" = all ] && cp -R "$t/mbn/mcfg_sw" work/fw/modem/ro/mbn/
find work/fw/modem/ro -type f | sort
du -sh work/fw/modem/ro
