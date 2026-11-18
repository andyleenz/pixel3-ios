#!/bin/bash
# Download the Adreno 630 GMU firmware for mkadt.py --gpu-fw (xnu 0126).
#
#   tools/fetch-gpu-fw.sh            -> work/fw/a630_gmu.bin (+ LICENSE.qcom)
#
# qcom/a630_gmu.bin from linux-firmware, pinned to the commit that added it
# (88ea23e7, 2019-09-09; byte-identical on main as of 747bdda2). Qualcomm's
# licence (WHENCE / LICENSE.qcom) allows redistribution only with the
# licence, so the file lives in work/ (ignored by git) and is never
# committed. mkadt.py checks the same SHA-256 again.
set -euo pipefail
cd "$(dirname "$0")/.."
commit=88ea23e7eed04e78111013df9b81dd851037e4da
sha=da8d9b1b1f5c1a0b311f32567093b4828f3c80031dd8435f91ac13c664e173a6
base=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
mkdir -p work/fw
out=work/fw/a630_gmu.bin
if [ -f "$out" ] && [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
	echo "$out: present, sha256 ok"
	exit 0
fi
curl -fsSL --max-time 120 -o "$out.tmp" "$base/qcom/a630_gmu.bin?id=$commit"
got=$(shasum -a 256 "$out.tmp" | cut -d' ' -f1)
if [ "$got" != "$sha" ]; then
	rm -f "$out.tmp"
	echo "a630_gmu.bin: sha256 $got, expected $sha" >&2
	exit 1
fi
mv "$out.tmp" "$out"
curl -fsSL --max-time 120 -o work/fw/LICENSE.qcom "$base/LICENSE.qcom?id=$commit" || true
echo "$out: $(wc -c < "$out" | tr -d ' ') bytes, sha256 ok (linux-firmware $commit)"
