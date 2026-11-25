#!/bin/bash
# Build SpriteHello.app for the phone's iOS 16 (arm64), ad-hoc signed like Hello.app.
#   tools/apps/spritehello/build.sh   -> tools/apps/spritehello/out/SpriteHello.app
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
A=out/SpriteHello.app
rm -rf "$A"
mkdir -p "$A"
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc \
	-framework UIKit -framework Foundation -framework SpriteKit -framework Metal -framework QuartzCore -o "$A/SpriteHello" main.m
plutil -convert binary1 -o "$A/Info.plist" Info.plist
printf 'APPL????' > "$A/PkgInfo"
codesign -s - -f --entitlements spritehello.ent --generate-entitlement-der "$A"
ls -la "$A"
