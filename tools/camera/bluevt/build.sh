#!/bin/bash
# Builds out/bluevt.dylib (VideoToolbox rotate-and-scale in software). See bluevt.c.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -dynamiclib \
	-install_name /usr/lib/bluevt.dylib -framework CoreFoundation -framework CoreVideo -framework VideoToolbox \
	-Wl,-not_for_dyld_shared_cache -o out/bluevt.dylib bluevt.c
codesign -s - -f out/bluevt.dylib
ls -l out/bluevt.dylib
