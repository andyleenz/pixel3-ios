#!/bin/bash
# Build oslog for the phone (arm64, iOS 16): tools/oslog/out/oslog, push to /usr/local/bin/oslog.
#
#   oslog [--info|--debug] [-p PID] [--noLevelInfo] [--noSubsystemInfo]
#
# Streams every process's os_log, decoded on the phone (libsystem_trace's activity stream SPI, as `log stream`).
# The Mac cannot decode the persisted log well: the shared cache's string tables change each boot.
# From Elias Limneos's oslog (https://github.com/fpillet/oslog, University of Illinois/NCSA licence, LICENSE.TXT).
# Changed for iOS 16: Foundation import; log_message.format, subsystem and category are not always pointers in
# the iOS 16 entry layout (they faulted), so format is not used and the other two are checked.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xcrun --sdk iphoneos clang++ -arch arm64 -mios-version-min=16.0 -O2 -fobjc-arc -framework Foundation -o out/oslog main.mm
codesign -s - -f --entitlements ents.plist out/oslog
