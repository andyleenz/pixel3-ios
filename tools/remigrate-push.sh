#!/bin/bash
# remigrate.sh without sudo, a mount or a flash: puts the same changes on the
# phone with phonetest --push and runs the migration in that boot.
#
#   tools/remigrate-push.sh NAME [phonetest options and boot-args]...
#
# The phone starts in recovery (or fastboot). Needs the IPSW's original
# launchd.plist in work/orig and its OS volume as work/OS.dmg (see
# remigrate.sh). The staged apps are larger than one push payload, so a
# short first boot (NAME-apps) puts in the first half; the migration boot
# (NAME) puts in the rest, with the migration reset and launchd.plist.
# Options and boot-args after NAME go to the migration boot, e.g.
#   tools/remigrate-push.sh migr5 --wait 40 --grep 'panic|BLUELINE: snap' blueui=1 ...
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -ge 1 ]] || { sed -n '2,13p' "$0"; exit 2; }
name=$1; shift
orig=$(find work/orig/ -path '*System/Library/xpc/launchd.plist' | head -1)
[ -n "$orig" ] || { echo "no original launchd.plist in work/orig" >&2; exit 1; }
[ -f work/OS.dmg ] || { echo "no work/OS.dmg (the IPSW's OS volume)" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/remigrate.XXXXXX")
trap 'rm -rf "${tmp:?}"' EXIT

7zz x -o"$tmp/os" work/OS.dmg 'private/var/staged_system_apps/*' -r >/dev/null
find "$tmp/os" -name '*:com.apple.*' -delete	# 7-Zip writes xattrs as files
apps=$tmp/os/private/var/staged_system_apps

# launchd.plist as remigrate.sh leaves it: the DENY list, mobileassetd back
# for the migration, and the test runner's job
python3 - "$orig" "$tmp/launchd.plist" "$tmp/migration.plist" <<'EOF'
import importlib.util, plistlib, sys
spec = importlib.util.spec_from_file_location('tweaks', 'tools/iosroot-tweaks.py')
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
orig, out, mig = sys.argv[1:]
data = plistlib.load(open(orig, 'rb'))
jobs = data['LaunchDaemons']
keep = {k: dict(j) for k, j in jobs.items() if j.get('Label') == 'com.apple.mobileassetd'}
for k in [k for k, j in jobs.items() if any(w in j.get('Label', '') for w in t.DENY)]:
    del jobs[k]
for j in jobs.values():
    if '_PanicOnCrash' in j:
        j['_PanicOnCrasX'] = j.pop('_PanicOnCrash')
for k, j in keep.items():
    if '_PanicOnCrash' in j:
        j['_PanicOnCrasX'] = j.pop('_PanicOnCrash')
    jobs[k] = j
jobs[t.BLUERUN_KEY] = dict(t.BLUERUN_JOB)
plistlib.dump(data, open(out, 'wb'), fmt=plistlib.FMT_BINARY)
print('launchd.plist: %d jobs (mobileassetd %s, bluerun added)' % (len(jobs), 'back' if keep else 'MISSING'))
# what migration-reset.py leaves: no "migration done" keys
plistlib.dump({}, open(mig, 'wb'), fmt=plistlib.FMT_BINARY)
EOF
: > "$tmp/migrate"

# split the apps in two halves by size
all=() first=() rest=() half=0 total=0
while IFS= read -r a; do all+=("$a"); done < <(ls "$apps")
total=$(du -skA "$apps" | cut -f1)
for a in "${all[@]}"; do
	k=$(du -skA "$apps/$a" | cut -f1)
	if (( half + k <= total / 2 )); then first+=("$a"); half=$((half + k)); else rest+=("$a"); fi
done
echo "staged apps: ${#all[@]} (${#first[@]} in the first boot, ${#rest[@]} with the migration)"
push() { for a in "$@"; do printf -- '--push\0%s\0' "$apps/$a:/private/var/staged_system_apps/$a:755:501:501"; done; }

a=()
while IFS= read -r -d '' x; do a+=("$x"); done < <(push "${first[@]}")
# (a migration moves the apps out, so the folder must be mobile's)
tools/phonetest.sh --name "$name-apps" --wait 6 --grep panic --end recovery \
	--mkdir /private/var/staged_system_apps:755:501:501 "${a[@]}" | tail -2

a=()
while IFS= read -r -d '' x; do a+=("$x"); done < <(push "${rest[@]}")
tools/phonetest.sh --name "$name" --end recovery "${a[@]}" \
	--push "$tmp/launchd.plist:/System/Library/xpc/launchd.plist:644:0:0" \
	--push "$tmp/migration.plist:/private/var/mobile/Library/Preferences/com.apple.migration.plist:600:501:501" \
	--mkdir /private/var/datamigrator:755:501:501 \
	--push "$tmp/migrate:/private/var/datamigrator/migrate:644:501:501" \
	"$@"
