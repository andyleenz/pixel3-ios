#!/bin/sh
# Builds out/blueexc.dylib (arm64, iOS 16, ad-hoc signed). See blueexc.m.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
mkdir -p out
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -O2 -fobjc-arc -dynamiclib \
	-framework Foundation -o out/blueexc.dylib blueexc.m
codesign -f -s - out/blueexc.dylib
echo out/blueexc.dylib
