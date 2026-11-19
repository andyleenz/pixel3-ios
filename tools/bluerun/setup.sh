#!/bin/bash
# One time: add the launchd job that starts the test runner, as a diff flash.
#
#   tools/bluerun/setup.sh [BASE.img]     (default work/ios-root.img; asks for sudo once)
#
# The usual root-change cycle with only this change in it (tools/rootimg.sh):
# phone in recovery -> base synced from the phone -> job added to
# System/Library/xpc/launchd.plist (tools/iosroot-tweaks.py --only bluerun)
# -> work/diff.simg. Then, with the phone in fastboot:
#   fastboot flash userdata work/diff.simg
#   mv work/ios-root-new.img BASE.img                (new base)
# After that, the runner binary itself comes with each test
# (tools/phonetest.sh --run pushes tools/bluerun/out/bluerun).
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:-work/ios-root.img}
new=${base%.img}-new.img
[ -f "$base" ] || { echo "no $base (the Mac's copy of the phone's root)" >&2; exit 1; }
tools/phone.sh sync "$base"
rm -f "$new" work/diff.simg
cp -c "$base" "$new"
sudo tools/rootimg.sh mount "$new"
trap 'sudo tools/rootimg.sh umount' EXIT
sudo python3 tools/iosroot-tweaks.py --only bluerun work/root
sudo tools/rootimg.sh umount
trap - EXIT
python3 tools/simgdiff.py "$base" "$new" work/diff.simg
echo "next: adb reboot bootloader; fastboot flash userdata work/diff.simg; mv $new $base"
