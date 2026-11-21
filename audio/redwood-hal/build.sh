#!/bin/bash
# build.sh - RedwoodAudio.driver, the CoreAudio HAL plug-in that gives iOS its speaker (HackiOS, MIT;
# see LICENSE). mediaserverd loads it from /System/Library/Audio/Plug-Ins/HAL and writes the mixed
# output, 48 kHz 16-bit stereo, to /dev/redwood-audio (kernel: bluesnd=4, patch 0190).
#
#   ./build.sh   ->  out/RedwoodAudio.driver/{RedwoodAudio,Info.plist}  (arm64, minos 16.0, ad-hoc signed)
#
# Push: --push audio/redwood-hal/out/RedwoodAudio.driver:/System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
D=$H/out/RedwoodAudio.driver
rm -rf "$D" && mkdir -p "$D"
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -O2 -g -Wall -Wextra -Wno-unused-parameter \
	-I"$H/src" -bundle -o "$D/RedwoodAudio" "$H/src/audio_plugin.c" -framework CoreFoundation
cp "$H/src/audio_plugin.plist" "$D/Info.plist"
plutil -lint -s "$D/Info.plist"
codesign -f -s - "$D/RedwoodAudio" 2>/dev/null
echo "build: $D"
