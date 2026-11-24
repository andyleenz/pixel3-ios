#!/bin/bash
# qc-spv.sh - translate the QuartzCore pipelines that the GPU tests draw, from the iOS 16.7
# root, into SPIR-V for Turnip on the A630 (metal2vulkan, profile turnip-a630).
#
#   gpu/metal/qc-spv.sh [ROOT] [OUT]
#
# ROOT: the mounted iOS root (default: the mounted OS.dmg, /Volumes/*D22D221OS).
# OUT:  default gpu/metal/out/qc. The .spv files are derived from Apple's shaders, so they stay
#       out of git (gpu/metal/out is ignored); run this script to make them.
#
# Writes OUT/NAME.vert.spv, OUT/NAME.frag.spv and OUT/NAME.json (metal2vulkan --emit-meta).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=${1:-$(ls -d /Volumes/*D22D221OS 2>/dev/null | head -1)}
OUT=${2:-gpu/metal/out/qc}
R=work/ref/metal2vulkan
B=$R/target/release/metal2vulkan
P=$R/crates/metal2vulkan-validation/profiles/turnip-a630.json
LIB=$ROOT/System/Library/Frameworks/QuartzCore.framework/default.metallib
[ -f "$LIB" ] || { echo "no QuartzCore metallib under '$ROOT' (mount work/OS.dmg)"; exit 1; }
[ -x "$B" ] || { echo "build metal2vulkan in $R first (cargo build --release)"; exit 1; }
[ -f "$P" ] || { echo "no turnip-a630 profile in $R (apply gpu/metal/m2v-regen-turnip-a630.patch, regen)"; exit 1; }
mkdir -p "$OUT"

# vertex function, fragment function
PIPES=(
	"stroke_line_vert_lpf stroke_line_frag_lpf"
)
for p in "${PIPES[@]}"; do
	read -r v f <<< "$p"
	"$B" "$LIB" "$OUT/$f.spv" --profile "$P" --function "$v" --fragment "$f" \
		--color-format 0:BGRA8Unorm --emit-meta "$OUT/$f.json" 2>&1 | grep -v 'wrote meta'
done
