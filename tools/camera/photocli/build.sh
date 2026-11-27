#!/bin/bash
# build.sh - photocli (one AVCapturePhotoOutput photograph from the command line), ad-hoc signed, into out/
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc -framework Foundation \
	-framework AVFoundation -o out/photocli photocli.m
codesign -s - -f --entitlements photocli.ent --generate-entitlement-der out/photocli
ls -la out/photocli
