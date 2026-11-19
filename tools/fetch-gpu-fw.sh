#!/bin/bash
# Download the Adreno 630 GMU and SQE firmware for mkadt.py --gpu-fw (xnu 0126, 0137).
#
#   tools/fetch-gpu-fw.sh   -> work/fw/a630_gmu.bin, work/fw/a630_sqe.fw (+ LICENSE.qcom)
#
# From linux-firmware, each pinned:
#  - qcom/a630_gmu.bin at the commit that added it (88ea23e7, 2019-09-09;
#    byte-identical on main as of 747bdda2);
#  - qcom/a630_sqe.fw v2.07 at 75f16899 (2024-01-11, current main). Older
#    copies (88ea23e7: version 0x176) fail Linux's a630 check (>= 0x190).
# The phone's own vendor SQE (work/fw/vendor/a630_sqe.fw, pulled from the
# LineageOS vendor image by hand) is preferred by mkadt.py when present.
# Qualcomm's licence (WHENCE / LICENSE.qcom) allows redistribution only with
# the licence, so the files live in work/ (ignored by git) and are never
# committed. mkadt.py checks the same SHA-256s again.
set -euo pipefail
cd "$(dirname "$0")/.."
base=https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain
mkdir -p work/fw

fetch() {	# fetch NAME COMMIT SHA256
	local name=$1 commit=$2 sha=$3 out=work/fw/$1
	if [ -f "$out" ] && [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
		echo "$out: present, sha256 ok"
		return 0
	fi
	curl -fsSL --max-time 120 -o "$out.tmp" "$base/qcom/$name?id=$commit"
	local got
	got=$(shasum -a 256 "$out.tmp" | cut -d' ' -f1)
	if [ "$got" != "$sha" ]; then
		rm -f "$out.tmp"
		echo "$name: sha256 $got, expected $sha" >&2
		exit 1
	fi
	mv "$out.tmp" "$out"
	echo "$out: $(wc -c < "$out" | tr -d ' ') bytes, sha256 ok (linux-firmware $commit)"
}

fetch a630_gmu.bin 88ea23e7eed04e78111013df9b81dd851037e4da \
	da8d9b1b1f5c1a0b311f32567093b4828f3c80031dd8435f91ac13c664e173a6
fetch a630_sqe.fw 75f16899bd8e2137635091b766122e984c6e0a65 \
	1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c
[ -f work/fw/LICENSE.qcom ] ||
	curl -fsSL --max-time 120 -o work/fw/LICENSE.qcom "$base/LICENSE.qcom?id=75f16899bd8e2137635091b766122e984c6e0a65" || true
