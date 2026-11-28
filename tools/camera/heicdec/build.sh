#!/bin/bash
# Build heicdec for the phone (arm64, iOS 16), ad-hoc signed: tools/camera/heicdec/out/heicdec
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc -framework Foundation \
	-framework ImageIO -framework CoreGraphics -framework VideoToolbox -framework CoreMedia -o out/heicdec heicdec.m
codesign -s - -f out/heicdec
