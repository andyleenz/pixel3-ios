#!/bin/bash
# Build the kernel locally on a Mac, the way .github/workflows/xnu.yml does.
#
#   tools/build-xnu.sh [WORKDIR]          (default work/kbuild)
#     -> WORKDIR/out/kernel.development.sweet, patch-list.txt, SHA256SUMS
#   tools/build-xnu.sh --quick [WORKDIR]
#     after one full build: only our xnu/patches that changed (or are new or
#     gone) are taken back out of the tree and put in again, then make
#     recompiles what they touch and relinks (minutes, not a full build).
#     Same pins only; anything else changed needs a full build.
#
# For when CI is not an option: GitHub retired the macos-14 runner image and
# the newer images only have Xcode 16+, whose iig emits IORPC.kernelContent,
# a field xnu-8796 does not have. Xcode 15.x is needed.
#
# Needs:
# - Xcode 15.x installed next to your normal Xcode (`xcodes install 15.4`).
#   Found as /Applications/Xcode-15*.app or Xcode_15*.app, or set
#   DEVELOPER_DIR. Only this build uses it; xcode-select is left alone.
#   Tested on macOS 26.6 with Xcode 15.4: its command-line tools run there
#   even though the app does not.
# - brew install jq gum xcodes bash cmake ninja
#
# The pins (repos, commits, patch selection, MACOS_VERSION) are read from
# xnu.yml so there is one place to change them. No sudo: the Kernel Debug
# Kit is unpacked into WORKDIR and passed to build.sh as KDKROOT instead of
# being installed into /Library/Developer/KDKs.
set -euo pipefail
# bash 4+ (mapfile; build.sh needs it too); macOS's /bin/bash is 3.2
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
	for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && exec "$b" "$0" "$@"; done
	echo "brew install bash" >&2; exit 1
fi
cd "$(dirname "$0")/.."
repo=$(pwd)
wf=.github/workflows/xnu.yml
quick=0
[ "${1:-}" = --quick ] && { quick=1; shift; }
work=${1:-work/kbuild}
mkdir -p "$work"
work=$(cd "$work" && pwd)

pin() {	# NAME: the value of NAME from xnu.yml's env block
	sed -nE "s/^  $1: *\"?([^\"#]*)\"?.*/\1/p" "$wf" | sed 's/[[:space:]]*$//' | head -1
}
DXB_REPO=$(pin DXB_REPO) DXB_SHA=$(pin DXB_SHA)
SWEET_REPO=$(pin SWEET_REPO) SWEET_SHA=$(pin SWEET_SHA)
SWEET_LAST=$(pin SWEET_LAST) SWEET_EXTRA=$(pin SWEET_EXTRA)
SAILFISH_REPO=$(pin SAILFISH_REPO) SAILFISH_SHA=$(pin SAILFISH_SHA)
SAILFISH_PATCHES=$(pin SAILFISH_PATCHES)
MACOS_VERSION=$(pin MACOS_VERSION)
for v in DXB_SHA SWEET_SHA SWEET_LAST SAILFISH_SHA MACOS_VERSION; do
	[ -n "${!v}" ] || { echo "could not read $v from $wf" >&2; exit 1; }
done

# Xcode 15
if [ -z "${DEVELOPER_DIR:-}" ]; then
	xc=$(ls -d /Applications/Xcode-15*.app /Applications/Xcode_15*.app 2>/dev/null | sort -V | tail -1 || true)
	[ -n "$xc" ] || { echo "no Xcode 15 in /Applications (xcodes install 15.4), or set DEVELOPER_DIR" >&2; exit 1; }
	DEVELOPER_DIR=$xc/Contents/Developer
fi
export DEVELOPER_DIR
ver=$(DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -version 2>/dev/null | sed -n 's/^Xcode //p')
case $ver in 15.*) echo "Xcode $ver at $DEVELOPER_DIR" ;; *) echo "need Xcode 15.x, $DEVELOPER_DIR is '$ver'" >&2; exit 1 ;; esac

BASH4=$(command -v /opt/homebrew/bin/bash /usr/local/bin/bash | head -1)
[ -n "$BASH4" ] || { echo "brew install bash" >&2; exit 1; }

copy_out() {
	rm -rf "$work/out" && mkdir "$work/out"
	cp -R "$work/dxb/fakeroot/System/Library/Kernels/." "$work/out/"
	cp "$work/patch-list.txt" "$work/out/"
	(cd "$work/out" && shasum -a 256 kernel.*.sweet > SHA256SUMS && cat SHA256SUMS)
	echo "kernel: $work/out/kernel.$(echo "${KERNEL_CONFIG:-DEVELOPMENT}" | tr '[:upper:]' '[:lower:]').sweet"
}

if [ "$quick" = 1 ]; then
	x=$work/dxb/xnu
	[ -f "$work/patch-list.txt" ] && [ -d "$x/.git" ] && [ -d "$work/dxb/build/xnu.obj" ] ||
		{ echo "no earlier full build in $work; run without --quick first" >&2; exit 1; }
	# The applied stack (patch-list order) and, for our own patches, what the repo has now
	mapfile -t old < "$work/patch-list.txt"
	new=()
	for n in "${old[@]}"; do
		case $n in 01[0-9][0-9]-*) [ -e "$repo/xnu/patches/$n" ] && new+=("$n") ;; *) new+=("$n") ;; esac
	done
	for f in "$repo"/xnu/patches/*.patch; do
		n=$(basename "$f"); printf '%s\n' "${old[@]}" | grep -qx "$n" || new+=("$n")
	done
	mapfile -t new < <(printf '%s\n' "${new[@]}" | LC_ALL=C sort)
	first=-1	# first position where the stack differs
	for ((i = 0; i < ${#old[@]} || i < ${#new[@]}; i++)); do
		o=${old[i]:-} n=${new[i]:-}
		if [ "$o" != "$n" ] || { case $n in 01[0-9][0-9]-*) ! cmp -s "$repo/xnu/patches/$n" "$work/dxb/patches/$n" ;; *) false ;; esac; }; then
			first=$i; break
		fi
	done
	[ "$first" -ge 0 ] || echo "no patch changed; relinking only"
	if [ "$first" -ge 0 ]; then
		for ((i = ${#old[@]} - 1; i >= first; i--)); do
			echo "take out ${old[i]}"
			git -C "$x" apply -R "$work/dxb/patches/${old[i]}" || { echo "could not take out ${old[i]}; tree left as is" >&2; exit 1; }
			printf '%s\n' "${old[@]:0:i}" > "$work/patch-list.txt"	# the list always matches the tree
			awk '/^--- \/dev\/null/{n=1;next} n&&/^\+\+\+ b\//{print substr($0,7)} {n=0}' "$work/dxb/patches/${old[i]}" |
				while read -r f; do if [ -f "$x/$f" ] && [ ! -s "$x/$f" ]; then rm -f "$x/$f"; fi; done	# git apply -R can leave a created file behind, empty
		done
		for ((i = first; i < ${#new[@]}; i++)); do
			n=${new[i]}
			case $n in 01[0-9][0-9]-*) cp "$repo/xnu/patches/$n" "$work/dxb/patches/" ;; esac
			echo "put in  $n"
			git -C "$x" apply "$work/dxb/patches/$n" || { echo "could not put in $n; tree has the patches before it" >&2; exit 1; }
			printf '%s\n' "${new[@]:0:i+1}" > "$work/patch-list.txt"
		done
		for n in "${old[@]}"; do printf '%s\n' "${new[@]}" | grep -qx "$n" || rm -f "$work/dxb/patches/$n"; done
		printf '%s\n' "${new[@]}" > "$work/patch-list.txt"
	fi
	kdk=$(ls -d "$work"/KDK_*.kdk | head -1)
	rm -f "$work/dxb/build/xnu.obj/kernel.$(echo "${KERNEL_CONFIG:-DEVELOPMENT}" | tr "[:upper:]" "[:lower:]").sweet"	# build.sh skips make while this exists
	status=0
	(cd "$work/dxb" && KDKROOT=$kdk MACOS_VERSION=$MACOS_VERSION KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} MACHINE_CONFIG=SWEET \
		"$BASH4" -c 'source <(sed "\$d" build.sh); setup_xcode_toolchain; choose_xnu; venv; build_xnu') > "$work/build-quick.log" 2>&1 || status=$?
	[ "$status" = 0 ] || { tail -20 "$work/build-quick.log"; echo "quick build failed ($status); see $work/build-quick.log" >&2; exit "$status"; }
	copy_out
	exit 0
fi

fetch() {	# DIR REPO SHA
	if [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
		rm -rf "$1"
		git init -q "$1"
		git -C "$1" fetch -q --depth 1 "$2" "$3"
		git -C "$1" checkout -q FETCH_HEAD
	fi
	git -C "$1" reset -q --hard && git -C "$1" clean -ffdxq	# a clean tree each run (also the ignored, already patched xnu/ source)
}
cd "$work"
fetch dxb "$DXB_REPO" "$DXB_SHA"
fetch sweet "$SWEET_REPO" "$SWEET_SHA"
fetch sailfish "$SAILFISH_REPO" "$SAILFISH_SHA"

# Patches, in the same order as the workflow
: > patch-list.txt
for f in sweet/xnu/patches/*; do
	n=$(basename "$f"); num=${n%%-*}
	if [[ $num > $SWEET_LAST ]] && ! echo " $SWEET_EXTRA " | grep -q " $num "; then continue; fi
	cp "$f" dxb/patches/
	case $n in *.patch) echo "$n" >> patch-list.txt ;; esac
done
for f in "$repo"/xnu/patches/*.sh; do [ -e "$f" ] && cp "$f" dxb/patches/; done
for f in "$repo"/xnu/patches/*.patch; do
	cp "$f" dxb/patches/
	basename "$f" >> patch-list.txt
done
i=200
for n in $SAILFISH_PATCHES; do
	f=$(ls sailfish/xnu/patches/$n-*.patch)
	dst="0${i}-sf-$(basename "$f")"
	cp "$f" "dxb/patches/$dst"
	echo "$dst" >> patch-list.txt
	i=$((i + 1))
done
# libfirehose_kernel is built arm64e-only; the SWEET kernel is plain arm64
sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' dxb/build.sh
grep -q 'VALID_ARCHS="x86_64 arm64e arm64"' dxb/build.sh || { echo "build.sh arm64 edit did not apply" >&2; exit 1; }
echo "$(wc -l < patch-list.txt | tr -d ' ') patches listed"

# Kernel Debug Kit, unpacked here (build.sh would sudo-install it)
kdk_name=$(sed -n "/'$MACOS_VERSION')/,/;;/s/.*KDK_NAME='\(.*\)'/\1/p" dxb/build.sh)
kdk_dir=$(sed -n "/'$MACOS_VERSION')/,/;;/s/.*KDKROOT='.*\/\(KDK_[^']*\)'/\1/p" dxb/build.sh)
[ -n "$kdk_name" ] && [ -n "$kdk_dir" ] || { echo "no KDK for macOS $MACOS_VERSION in build.sh" >&2; exit 1; }
if [ ! -d "$kdk_dir/System/Library/Kernels" ]; then
	url=$(curl -fsSL https://raw.githubusercontent.com/dortania/KdkSupportPkg/gh-pages/manifest.json |
		jq -r --arg n "$kdk_name" '.[] | select(.name==$n) | .url')
	[ -n "$url" ] || { echo "no download for '$kdk_name'" >&2; exit 1; }
	echo "downloading $kdk_name"
	curl -fL --progress-bar -o KDK.dmg "$url"
	mnt=$(mktemp -d)
	hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mnt" KDK.dmg
	rm -rf kdkpkg
	pkgutil --expand-full "$mnt/KernelDebugKit.pkg" kdkpkg
	hdiutil detach -quiet "$mnt"
	rm -rf "$kdk_dir"
	mv kdkpkg/KDK.pkg/Payload "$kdk_dir"
	rm -rf kdkpkg KDK.dmg
fi
export KDKROOT=$work/$kdk_dir MACOS_VERSION
export KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT} MACHINE_CONFIG=SWEET

# Build (build.sh wants bash 4+; macOS's /bin/bash is 3.2)
status=0
(cd dxb && "$BASH4" build.sh) 2>&1 | tee build.log || status=$?
[ "$status" = 0 ] || { echo "build.sh failed ($status); see $work/build.log" >&2; exit "$status"; }

# build.sh skips a patch that does not apply, with only a warning
missing=0
while read -r p; do
	grep -q "Applying patch: .*/$p" build.log || { echo "NOT APPLIED: $p"; missing=1; }
done < patch-list.txt
[ "$missing" = 0 ] || exit 1

copy_out
