#!/usr/bin/env bash
# Check one or more draft XNU patches without touching the real build:
#   tools/patch-check.sh [--replace N-name.patch]... DRAFT.patch...
# 1. clones work/kbuild/dxb/xnu (APFS clone, instant) into a scratch dir,
# 2. with --replace, takes out the named patch (its applied copy in
#    work/kbuild/dxb/patches) and every later one, then puts the later ones back
#    after the drafts (as build-xnu.sh --quick would),
# 3. git apply --check, then applies each draft,
# 4. compiles every .c/.cpp file the drafts touch with -fsyntax-only, using the
#    exact clang command line of a sibling file from work/kbuild/build.log,
#    with -o/-MD/-MF/-MP/-MT stripped (nothing is written into the real build).
# Exit 0 only if everything applies and compiles. Prints warnings in touched files.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
kb=$repo/work/kbuild
src=$kb/dxb/xnu
log=$kb/build.log
replace=()
while [ $# -gt 0 ]; do
	case $1 in
	--replace) replace+=("$2"); shift 2 ;;
	-h|--help) sed -n '2,13p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
[ $# -gt 0 ] || { echo "usage: $0 [--replace NAME.patch] DRAFT.patch..." >&2; exit 2; }
drafts=(); for p in "$@"; do drafts+=("$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"); done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/patch-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp -c -R "$src" "$tmp/xnu"
x=$tmp/xnu

later=()
if [ ${#replace[@]} -gt 0 ]; then
	mapfile -t applied < "$kb/patch-list.txt"
	first=-1
	for i in "${!applied[@]}"; do for r in "${replace[@]}"; do [ "${applied[i]}" = "$r" ] && { [ $first -lt 0 ] || [ $i -lt $first ]; } && first=$i; done; done
	[ $first -ge 0 ] || { echo "--replace: ${replace[*]} not in patch-list.txt" >&2; exit 2; }
	for ((i = ${#applied[@]} - 1; i >= first; i--)); do
		git -C "$x" apply -R "$kb/dxb/patches/${applied[i]}" || { echo "could not take out ${applied[i]}" >&2; exit 1; }
	done
	for ((i = first; i < ${#applied[@]}; i++)); do
		skip=0; for r in "${replace[@]}"; do [ "${applied[i]}" = "$r" ] && skip=1; done
		[ $skip = 1 ] || later+=("$kb/dxb/patches/${applied[i]}")
	done
fi

files=()
for p in "${drafts[@]}"; do
	git -C "$x" apply --check "$p" || { echo "FAIL apply --check: $(basename "$p")" >&2; exit 1; }
	git -C "$x" apply "$p"
	while read -r f; do files+=("$f"); done < <(grep -E '^\+\+\+ b/' "$p" | sed 's|^+++ b/||')
	echo "ok apply: $(basename "$p")"
done
for p in "${later[@]+"${later[@]}"}"; do
	git -C "$x" apply "$p" || { echo "FAIL: later patch $(basename "$p") no longer applies on top" >&2; exit 1; }
	echo "ok re-apply: $(basename "$p")"
done

# One compile line per language from the build log, retargeted at the scratch tree.
line_for() {	# FILE -> the clang line of the same file, or of a file in the same directory, or any of that language
	local f=$1 base dir lang l
	base=$(basename "$f"); dir=$(dirname "$f")
	case $f in *.cpp) lang='clang\+\+' ;; *) lang='clang' ;; esac
	l=$(grep -E "/$lang( .*)? -c .*[ /]$dir/$base( |$)" "$log" | tail -1 || true)
	[ -n "$l" ] || l=$(grep -E "/$lang( .*)? -c .*[ /]$dir/[^ ]+\.(c|cpp)( |$)" "$log" | tail -1 || true)
	[ -n "$l" ] || l=$(grep -E "/$lang( .*)? -c " "$log" | grep -E '\.(c|cpp)( |$)' | tail -1 || true)
	printf '%s' "$l"
}
status=0
for f in $(printf '%s\n' "${files[@]}" | sort -u); do
	case $f in *.c|*.cpp) ;; *) continue ;; esac
	l=$(line_for "$f")
	[ -n "$l" ] || { echo "no compile line for $f" >&2; status=1; continue; }
	# drop the source operand and output/dependency flags; point -I paths at the clone
	cmd=$(printf '%s' "$l" | sed -E 's/ -o [^ ]+//; s/ -M[DP]//g; s/ -M[FT] [^ ]+//g; s/ [^ ]+\.(c|cpp)( |$)/ /' | sed "s|$src|$x|g")
	comp=${f%%/*}; wd=$kb/dxb/build/xnu.obj/DEVELOPMENT_ARM64_SWEET/$comp/DEVELOPMENT	# compiles run in the component's object dir
	[ -d "$wd" ] || wd=$kb/dxb/build/xnu.obj/DEVELOPMENT_ARM64_SWEET/osfmk/DEVELOPMENT
	out=$(cd "$wd"; eval "$cmd -fsyntax-only -o /dev/null $x/$f" 2>&1) && rc=0 || rc=$?
	errs=$(printf '%s\n' "$out" | grep -c ' error:' || true)
	mine=$(printf '%s\n' "$out" | grep -F "$x/$f:" | grep ' warning:' | grep -v 'declaration-after-statement\|mixing declarations' || true)	# warnings in the touched file only
	warns=$(printf '%s' "$mine" | grep -c . || true)
	if [ "$rc" != 0 ] || [ "$errs" != 0 ]; then
		echo "FAIL compile: $f ($errs errors)"; printf '%s\n' "$out" | grep -E ' error:' | head -20; status=1
	else
		[ "$warns" = 0 ] && echo "ok compile: $f" || echo "ok compile: $f ($warns warnings)"
		[ "$warns" = 0 ] || printf '%s\n' "$mine" | sed "s|$x/||" | head -10
	fi
done
[ $status = 0 ] && echo "ALL OK" || echo "PROBLEMS (see above)"
exit $status
