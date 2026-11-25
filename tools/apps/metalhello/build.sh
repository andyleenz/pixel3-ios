#!/bin/bash
# Build MetalHello.app for the phone's iOS 16 (arm64), ad-hoc signed like Hello.app.
#   tools/apps/metalhello/build.sh   -> tools/apps/metalhello/out/MetalHello.app
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
A=out/MetalHello.app
rm -rf "$A"
mkdir -p "$A"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc \
	-framework UIKit -framework Foundation -framework Metal -framework QuartzCore -framework IOSurface -o "$A/MetalHello" main.m
xcrun -sdk iphoneos metal -std=ios-metal2.4 -mios-version-min=16.0 shaders.metal -o "$A/default.metallib"
plutil -convert binary1 -o "$A/Info.plist" Info.plist
printf 'APPL????' > "$A/PkgInfo"
codesign -s - -f --entitlements metalhello.ent --generate-entitlement-der "$A"
ls -la "$A"
