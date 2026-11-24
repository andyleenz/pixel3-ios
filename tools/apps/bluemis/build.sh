#!/bin/bash
# Builds out/bluemis.dylib (installd: accept ad-hoc signed apps). See bluemis.c.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xxd -i apple-iphone-os-application-signing.der > out/cert.h
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -dynamiclib \
	-install_name /usr/lib/bluemis.dylib -framework CoreFoundation -lobjc \
	-Wl,-U,_MISValidateSignatureAndCopyInfoWithProgress -Wl,-U,_MISValidateSignatureAndCopyInfo -Wl,-not_for_dyld_shared_cache \
	-o out/bluemis.dylib bluemis.c
codesign -s - -f out/bluemis.dylib
ls -l out/bluemis.dylib
