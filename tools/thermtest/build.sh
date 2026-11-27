#!/bin/bash
# build.sh - thermtest (temperature HID services, kernel patch 0235) -> out/thermtest, burn (CPU load) -> out/burn;
# install at /usr/local/bin
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc -framework Foundation -o out/thermtest thermtest.m
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -o out/burn burn.c
codesign -f -s - out/thermtest out/burn
ls -la out/thermtest out/burn
