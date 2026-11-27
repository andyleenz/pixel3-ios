#!/bin/bash
# Build heictest for the phone (arm64, iOS 16), ad-hoc signed: tools/camera/heictest/out/heictest
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc \
	-framework Foundation -framework ImageIO -framework CoreGraphics -o out/heictest heictest.m
codesign -s - -f out/heictest
