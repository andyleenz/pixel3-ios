#!/bin/bash
# Build the test runner and the hello-world test for the phone's iOS 16
# (iPhone 8 userland: plain arm64, no arm64e), ad-hoc signed.
#
#   tools/bluerun/build.sh            -> tools/bluerun/out/bluerun, out/hello
#   tools/bluerun/build.sh FILE.c...  also builds each FILE.c to out/FILE
#
# Any Xcode with an iPhoneOS SDK works (xcrun --sdk iphoneos). Set
# ENTITLEMENTS=plist to sign with entitlements (the kernel's AMFI stand-in
# reads the XML entitlements blob; sweet 0035).
#
# Signing: the kernel refuses code pages without a valid signature, so an
# unsigned arm64 binary dies at exec. Ad-hoc is enough: there is no trust
# cache or certificate check here, and a binary on the root volume is a
# platform binary (sweet_amfi.c). codesign -s - (or ldid -S) does it.
set -euo pipefail
extra=()
for f in "$@"; do extra+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"); done
cd "$(dirname "$0")"
mkdir -p out
cc=(xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter -framework CoreFoundation)
sign() {
	if [ -n "${ENTITLEMENTS:-}" ]; then
		codesign -s - -f --entitlements "$ENTITLEMENTS" "$1"
	else
		codesign -s - -f "$1"
	fi
	codesign -d -v "$1" 2>&1 | grep -E '^(Format|CodeDirectory|Signature)' | tr '\n' ' '; echo
}
for src in bluerun.c hello.c ${extra[@]+"${extra[@]}"}; do
	name=$(basename "$src" .c)
	"${cc[@]}" -o "out/$name" "$src"
	sign "out/$name"
	echo "out/$name: $(file -b "out/$name")"
done
# apptest (Objective-C): install, launch and check apps (tools/bluerun/apptest.m)
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc \
	-framework Foundation -framework MobileCoreServices -lsqlite3 -o out/apptest apptest.m
ENTITLEMENTS=apptest.ent sign out/apptest
