#!/bin/bash
# Build WebGLHello.app for the phone's iOS 16 (arm64), ad-hoc signed like Hello.app.
#   tools/apps/webglhello/build.sh   -> tools/apps/webglhello/out/WebGLHello.app
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
A=out/WebGLHello.app
rm -rf "$A"
mkdir -p "$A"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc \
	-framework UIKit -framework Foundation -framework WebKit -o "$A/WebGLHello" main.m
plutil -convert binary1 -o "$A/Info.plist" Info.plist
printf 'APPL????' > "$A/PkgInfo"
codesign -s - -f --entitlements webglhello.ent --generate-entitlement-der "$A"
ls -la "$A"
