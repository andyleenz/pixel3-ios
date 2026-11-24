#!/bin/bash
# Build Hello.app for the phone's iOS 16 (arm64), ad-hoc signed with hello.ent.
#   tools/apps/hello/build.sh   -> tools/apps/hello/out/Hello.app
# The kernel's AMFI stand-in (sweet_amfi.c) takes any ad-hoc signature; the team ID in
# hello.ent is a placeholder (no certificate is checked).
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
rm -rf out/Hello.app
mkdir -p out/Hello.app
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -fobjc-arc \
	-framework UIKit -framework Foundation -o out/Hello.app/Hello main.m
plutil -convert binary1 -o out/Hello.app/Info.plist Info.plist
printf 'APPL????' > out/Hello.app/PkgInfo
codesign -s - -f --entitlements hello.ent --generate-entitlement-der out/Hello.app
codesign -d -v out/Hello.app 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature)'
if otool -l out/Hello.app/Hello | grep -q 'cryptid 1'; then echo "encrypted?"; exit 1; fi
ls -la out/Hello.app
