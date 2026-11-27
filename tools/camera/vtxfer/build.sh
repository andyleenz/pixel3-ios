#!/bin/bash
# Build vtxfer for the phone (arm64, iOS 16), ad-hoc signed: tools/camera/vtxfer/out/vtxfer
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc -framework Foundation \
	-framework CoreVideo -framework VideoToolbox -framework CoreMedia -framework Metal -o out/vtxfer vtxfer.m
codesign -s - -f out/vtxfer
