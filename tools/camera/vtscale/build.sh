#!/bin/sh
# vtscale for the phone (arm64, iOS 16), ad-hoc signed.
cd "$(dirname "$0")" && mkdir -p out &&
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -framework CoreFoundation -framework CoreVideo \
    -framework VideoToolbox -o out/vtscale vtscale.c && codesign -s - -f out/vtscale
