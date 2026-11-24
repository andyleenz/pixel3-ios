#!/bin/bash
# build-mtl-draw.sh - the native Metal frontend (UniXNU's AdrenoMetal, MIT) for iOS 16 on our Turnip, as the test program
# gpu/metal/out/mtl-draw (test/mtl-draw.mm).
#
#   gpu/metal/build-mtl-draw.sh [--reuse-bridge]
#
# Needs, under work/ref (not in git):
#   UniXNU/                                   github.com/UniXNU/UniXNU (its scripts and pins)
#   UniXNU/drivers/AdrenoMetal                AdrenoMetal at UniXNU's submodule pin (a worktree of work/ref/AdrenoMetal)
#   UniXNU/.cache/gpu-reference/metal2vulkan  metal2vulkan at UniXNU's pin (scripts/data/gpu-metal-vulkan-inputs.json)
# and rustup's toolchain 1.98.0 with aarch64-apple-ios (brew install rustup; rustup toolchain install 1.98.0
# --target aarch64-apple-ios), Python 3.11+.
#
# The bridge (metal2vulkan's runtime behind a C ABI, libadreno_metal_bridge.a) is built by UniXNU's own script with
# our patches in patches/ added to its list: m2v-0001 gives read_pages an iOS fallback (the pinned runtime defines it
# on Linux, macOS and Windows only). The frontend is compiled from a copy with am-*.patch: am-0001 takes iOS 16's
# _MTLDevice (the check held to iPadOS 17's 536 bytes; the subclass uses none of its ivars).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
U=$REPO/work/ref/UniXNU
A=$U/drivers/AdrenoMetal
OUT=$REPO/gpu/metal/out
PY=$(command -v python3.11 || command -v python3.14 || command -v python3)
export PATH="$(brew --prefix rustup)/bin:$PATH"
[ -f "$A/NativeBridgeMetalFrontend.mm" ] || { echo "no AdrenoMetal at $A"; exit 1; }

BRIDGE=$U/build/adreno-metal-bridge/ios/libadreno_metal_bridge.a
if [ "${1:-}" != --reuse-bridge ] || [ ! -f "$BRIDGE" ]; then
	S=$(grep -o "m2v-0001[^']*" "$U/scripts/build-adreno-metal-bridge.py" || true)
	if [ -z "$S" ]; then
		# add our patches after UniXNU's recorded ones
		"$PY" - "$U/scripts/build-adreno-metal-bridge.py" "$REPO/gpu/metal/patches" <<'E'
import sys, re
p, d = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r"(PATCHES = \[.*?\]\])", lambda m: m.group(1) + " + sorted(Path('%s').glob('m2v-*.patch'))" % d, s, count=1, flags=re.S)
open(p, 'w').write(s)
E
	fi
	(cd "$U" && "$PY" scripts/build-adreno-metal-bridge.py --target ios)
fi

mkdir -p "$OUT"
# the frontend from a copy with our patches (am-*.patch), the AdrenoMetal checkout stays clean
SRC=$OUT/am-src
rm -rf "$SRC"; mkdir -p "$SRC"
cp "$A"/*.h "$A"/*.mm "$SRC"/; mkdir -p "$SRC/bridge"; cp "$A"/bridge/*.h "$SRC/bridge/"
for p in "$REPO"/gpu/metal/patches/am-*.patch; do patch -s -d "$SRC" -p1 < "$p"; done
MI=$(ls -d "$REPO"/gpu/mesa-ios/build/mesa-*/include | head -1)
xcrun clang++ -target arm64-apple-ios16.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" -O2 -g -std=c++17 -fobjc-arc \
	-Wno-deprecated-declarations -Wno-unguarded-availability-new -DNATIVE_METAL_BUILD_ID='"pixel3"' -DNMB_ANY_MTLDEVICE_SIZE \
	-I "$SRC" -I "$U/drivers/Adreno740" -I "$U/kits/AdrenoPM4" -I "$MI" \
	-x objective-c++ "$REPO/gpu/metal/test/mtl-draw.mm" "$SRC/NativeBridgeMetalFrontend.mm" -x none "$BRIDGE" \
	-Wl,-dead_strip -lobjc -framework Foundation -framework Metal -framework IOSurface -o "$OUT/mtl-draw"
codesign -f -s - "$OUT/mtl-draw" 2>/dev/null
xcrun -sdk iphoneos metal -std=ios-metal2.4 -mios-version-min=16.0 "$REPO/gpu/metal/test/tri.metal" -o "$OUT/tri.metallib"
echo "built $OUT/mtl-draw ($(stat -f %z "$OUT/mtl-draw") bytes)"
