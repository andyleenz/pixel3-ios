#!/bin/bash
# build.sh - bluecam capture-device plug-in -> out/H13ISP.mediacapture (install at /System/Library/MediaCapture/)
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -dynamiclib \
	-install_name /System/Library/MediaCapture/H13ISP.mediacapture -fobjc-arc -framework Foundation \
	-o out/H13ISP.mediacapture bluecam.m
codesign -f -s - out/H13ISP.mediacapture
ls -la out/H13ISP.mediacapture
