#!/bin/bash
# build.sh - CamHello.app (tools/apps/camhello), ad-hoc signed, into out/
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
A=out/CamHello.app
rm -rf "$A"
mkdir -p "$A"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc \
	-framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo \
	-framework QuartzCore -o "$A/CamHello" main.m
plutil -convert binary1 -o "$A/Info.plist" Info.plist
printf 'APPL????' > "$A/PkgInfo"
codesign -s - -f --entitlements camhello.ent --generate-entitlement-der "$A"
ls -la "$A"
