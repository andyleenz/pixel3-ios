#!/bin/bash
# remigrate.sh without sudo, a mount or a flash: puts the same changes on the
# phone with phonetest --push and runs the migration in that boot.
#
#   tools/remigrate-push.sh NAME [phonetest options and boot-args]...
#
# The phone starts in recovery (or fastboot). Needs the IPSW's original
# launchd.plist in work/orig and its OS volume as work/OS.dmg (see
# remigrate.sh). The staged apps (about 500 MiB) are larger than one push
# payload, so short boots (NAME-apps1, 2...) put most of them in; the
# migration boot (NAME) puts in the rest, with the reset and launchd.plist.
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
for k in [k for k, j in jobs.items() if t.denied(k, j)]:
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

# pack the apps into boots: a push holds 255 MiB, and the migration boot
# keeps room for its own files and the test's (GPU libraries etc.)
mig_kib=$((150 * 1024)) boot_kib=$((235 * 1024))
rest=() rest_k=0 boots=() cur=() cur_k=0
while IFS=$'\t' read -r k a; do
	if (( rest_k + k <= mig_kib )); then rest+=("$a"); rest_k=$((rest_k + k)); continue; fi
	if (( cur_k + k > boot_kib )); then boots+=("${cur[*]}"); cur=() cur_k=0; fi
	cur+=("$a"); cur_k=$((cur_k + k))
done < <(cd "$apps" && du -skA -- *.app | sort -rn)
(( ${#cur[@]} )) && boots+=("${cur[*]}")
echo "staged apps: $(ls "$apps" | wc -l | tr -d ' ') (${#boots[@]} app boots, ${#rest[@]} with the migration)"
push() { for a in "$@"; do printf -- '--push\0%s\0' "$apps/$a:/private/var/staged_system_apps/$a:755:501:501"; done; }

# (a migration moves the apps out, so the folder must be mobile's. The pushes
# are applied as the kernel starts; reboot on a timer, since SpringBoard may
# never come up, e.g. while lsd waits for a database seed)
n=0
for b in "${boots[@]}"; do
	n=$((n + 1)) a=()
	read -r -a list <<< "$b"
	while IFS= read -r -d '' x; do a+=("$x"); done < <(push "${list[@]}")
	tools/phonetest.sh --name "$name-apps$n" --wait 6 --grep panic --end recovery \
		--mkdir /private/var/staged_system_apps:755:501:501 "${a[@]}" \
		bluereboot=recovery bluereboot_after=120 | tail -1
done

a=()
while IFS= read -r -d '' x; do a+=("$x"); done < <(push "${rest[@]}")
tools/phonetest.sh --name "$name" --end recovery "${a[@]}" \
	--push "$tmp/launchd.plist:/System/Library/xpc/launchd.plist:644:0:0" \
	--push "$tmp/migration.plist:/private/var/mobile/Library/Preferences/com.apple.migration.plist:600:501:501" \
	--mkdir /private/var/datamigrator:755:501:501 \
	--push "$tmp/migrate:/private/var/datamigrator/migrate:644:501:501" \
	--mkdir /private/var/preferences/FeatureFlags/Domain:755:0:0 \
	--push tools/featureflags/SpringBoard.plist:/private/var/preferences/FeatureFlags/Domain/SpringBoard.plist:644:0:0 \
	"$@"
