#!/bin/bash
# build.sh - camtest (reads /dev/blueline-camera, kernel patch 0233) -> out/camtest
# Install at /usr/local/bin/camtest, e.g.:
#   tools/phonetest.sh --name camdev1 --push tools/camera/camtest/out/camtest:/usr/local/bin/camtest \
#     --run /usr/local/bin/camtest,60 --run-timeout 30 --grep 'BLUE CAM|SAY camtest|BLUERUN'
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-15.4.0.app/Contents/Developer}
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O2 -Wall -Wextra -o out/camtest camtest.c
codesign -f -s - out/camtest
ls -la out/camtest
