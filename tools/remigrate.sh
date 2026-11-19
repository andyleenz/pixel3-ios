#!/bin/bash
# Let iOS run its first-boot data migration again (it registers the
# removable system apps and sets up wallpapers/posters) and put
# mobileassetd back, as one diff flash.
#
#   tools/remigrate.sh            (asks for the sudo password once)
#
# First, in recovery: tools/phone.sh sync work/ios-root.img. Needs the
# IPSW's original launchd.plist in work/orig (see tools/launchd-restore.py),
# and the IPSW's OS volume as work/OS.dmg plus 7-Zip, to put back the
# removable system apps a failed migration used up (/var/staged_system_apps).
# Then flash work/diff.simg to userdata and mv work/ios-root-new.img
# work/ios-root.img. Undo if the migration hangs: tools/prefs-fix.sh
# com.apple.migration ... (or rerun tools/iosroot-tweaks.py).
set -euo pipefail
cd "$(dirname "$0")/.."
orig=$(find work/orig/ -path '*System/Library/xpc/launchd.plist' | head -1)
[ -n "$orig" ] || { echo "no original launchd.plist in work/orig" >&2; exit 1; }
[ -f work/OS.dmg ] || { echo "no work/OS.dmg (the IPSW's OS volume)" >&2; exit 1; }
rm -f work/ios-root-new.img work/diff.simg
staged=$(mktemp -d "${TMPDIR:-/tmp}/staged.XXXXXX")
7zz x -o"$staged" work/OS.dmg 'private/var/staged_system_apps/*' -r >/dev/null
cp -c work/ios-root.img work/ios-root-new.img
sudo tools/rootimg.sh mount work/ios-root-new.img
trap 'sudo tools/rootimg.sh umount' EXIT
sudo python3 tools/migration-reset.py work/root
# a migration moves each staged app into installd's staging, and a failed
# install (e.g. before 0163, clonefile on HFS+) deletes it; with none left
# the apps only get App Store placeholders, so put the IPSW's set back
sudo rm -rf work/root/private/var/staged_system_apps
sudo ditto --noextattr --noacl "$staged/private/var/staged_system_apps" work/root/private/var/staged_system_apps
sudo chown -R 501:501 work/root/private/var/staged_system_apps
rm -rf "${staged:?}"
echo "staged apps: $(ls work/root/private/var/staged_system_apps | wc -l)"
# the current DENY list (e.g. fairplayd, which hangs app installs and Photos without a SEP);
# mobileassetd, which it also removes, is put back next for the migration
sudo python3 tools/iosroot-tweaks.py --only launchd work/root
sudo python3 tools/launchd-restore.py work/root "$orig" com.apple.mobileassetd
# keep the test runner job (tools/bluerun), which migr1-3 lost
sudo python3 tools/iosroot-tweaks.py --only bluerun work/root
sudo tools/rootimg.sh umount
trap - EXIT
python3 tools/simgdiff.py work/ios-root.img work/ios-root-new.img work/diff.simg
ls -la work/diff.simg
