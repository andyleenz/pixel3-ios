#!/bin/bash
# Put files into the iOS root without an image round trip (patch 0152).
#
#   tools/iosfs-push.sh [--name N] LOCAL:DEVPATH[:MODE[:UID:GID]]... [--rm DEVPATH]...
#   tools/iosfs-push.sh --payload FILE.bin     (one tools/mkpush.py built)
#   tools/iosfs-push.sh --show                 what is on the phone now
#   tools/iosfs-push.sh --clear                invalidate it
#
# Phone in LineageOS recovery with adb (root). Builds a payload with
# tools/mkpush.py (Mach-O files are checked: arm64, iOS, signed; unsigned
# ones are signed ad-hoc), writes it with dd into the 256 MiB of userdata
# right below the screenshot area, reads it back and compares. The next boot
# with bluepush=1 applies it before launchd starts (kernel log: "BLUELINE
# PUSH: ..."); tools/phonetest.sh --push does all of this for you.
#
# The files then live in the root like any other (and stay). The payload
# area is only ever written here and only when the HFS+ volume header on the
# phone says the volume ends before it; nothing outside userdata is touched.
#
# Layout from the end of userdata, 4 KiB blocks:
#   [ HFS+ root ... | payload 65536 | snaps 32768 (0146) | log 1025 (0047) ]
set -euo pipefail
cd "$(dirname "$0")/.."
PART=/dev/block/by-name/userdata
AREA_BLOCKS=65536
TMP=/tmp/bluepush.bin
mkdir -p work

need_recovery() {
	adb devices | grep -q "recovery$" || {
		echo "phone is not in recovery with adb on" >&2
		exit 1
	}
	[ "$(adb shell id -u | tr -d '\r')" = 0 ] || { echo "recovery adb shell is not root" >&2; exit 1; }
}

# Sets start (first block of the area) after checking the HFS+ volume ends before it.
find_area() {
	local size hdr
	size=$(adb shell blockdev --getsize64 "$PART" | tr -d '\r')
	[[ $size =~ ^[0-9]+$ ]] && [ "$size" -gt $(( 2 * (1025 + 32768 + AREA_BLOCKS) * 4096 )) ] ||
		{ echo "userdata size '$size' looks wrong" >&2; exit 1; }
	start=$(( size / 4096 - 1025 - 32768 - AREA_BLOCKS ))
	hdr=work/push-vh.bin
	adb exec-out "dd if=$PART bs=4096 count=1 2>/dev/null" > "$hdr"
	hfs_end=$(python3 - "$hdr" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
sig, = struct.unpack_from('>H', d, 1024) if len(d) >= 1536 else (0,)
if sig not in (0x482b, 0x4858):
    sys.exit('no HFS+ volume header at userdata+1024 (0x%04x); not writing' % sig)
bs, total = struct.unpack_from('>II', d, 1024 + 40)
print((bs * total + 4095) // 4096)
EOF
)
	[ "$hfs_end" -gt 0 ] && [ "$hfs_end" -le "$start" ] ||
		{ echo "HFS+ volume ends at block $hfs_end, past the area at $start; not writing" >&2; exit 1; }
}

write_payload() {
	local file=$1 blocks lmd5 pmd5
	blocks=$(( $(stat -f %z "$file") / 4096 ))
	[ "$blocks" -ge 1 ] && [ "$blocks" -le "$AREA_BLOCKS" ] || { echo "$file: $blocks blocks, area holds $AREA_BLOCKS" >&2; exit 1; }
	python3 tools/mkpush.py --list "$file" > /dev/null || { echo "$file is not a good payload" >&2; exit 1; }
	need_recovery
	find_area
	adb push "$file" "$TMP" > /dev/null
	adb shell "dd if=$TMP of=$PART bs=4096 seek=$start count=$blocks conv=notrunc,fsync 2>/dev/null && sync && rm -f $TMP"
	lmd5=$(md5 -q "$file")
	pmd5=$(adb shell "dd if=$PART bs=4096 skip=$start count=$blocks 2>/dev/null | md5sum" | tr -d '\r' | awk '{print $1}')
	[ "$lmd5" = "$pmd5" ] || { echo "read-back differs ($pmd5, want $lmd5)" >&2; exit 1; }
	echo "payload written: $blocks blocks at userdata block $start (+$(( start * 4 / 1024 )) MiB; HFS+ ends at $(( hfs_end * 4 / 1024 )) MiB), read back ok"
	echo "boot with bluepush=1 to apply it"
}

case ${1:-} in
--show)
	need_recovery
	find_area
	adb exec-out "dd if=$PART bs=4096 skip=$start count=1 2>/dev/null" > work/push-phone.bin
	n=$(python3 -c 'import struct,sys
d = open(sys.argv[1], "rb").read(32)
print((struct.unpack_from("<Q", d, 16)[0] + 4095) // 4096 + 1 if d[:8] == b"BLUEPUSH" else 0)' work/push-phone.bin)
	[ "$n" -gt 0 ] || { echo "no payload on the phone"; exit 0; }
	[ "$n" -le "$AREA_BLOCKS" ] || { echo "payload header says $n blocks: bad"; exit 1; }
	adb exec-out "dd if=$PART bs=4096 skip=$start count=$n 2>/dev/null" > work/push-phone.bin
	python3 tools/mkpush.py --list work/push-phone.bin
	;;
--clear)
	need_recovery
	find_area
	adb shell "dd if=/dev/zero of=$PART bs=4096 seek=$start count=1 conv=notrunc,fsync 2>/dev/null && sync"
	echo "payload header at block $start cleared"
	;;
--payload)
	[ $# -eq 2 ] || { sed -n '2,7p' "$0"; exit 2; }
	write_payload "$2"
	;;
''|-h|--help)
	sed -n '2,23p' "$0"
	exit 2
	;;
*)
	out=work/push-$(date +%Y%m%d-%H%M%S).bin
	python3 tools/mkpush.py "$out" "$@"
	write_payload "$out"
	;;
esac
