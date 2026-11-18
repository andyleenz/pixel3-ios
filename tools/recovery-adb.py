#!/usr/bin/env python3
"""LineageOS recovery with adb on, no "Enable ADB" tap.

  tools/recovery-adb.py stock/boot.img work/boot_b-adb.img
  fastboot flash boot_b work/boot_b-adb.img      (slot B = LineageOS recovery)

LineageOS recovery starts adbd on an unlocked phone but refuses the host
until Advanced > Enable ADB, which sets ro.adb.secure.recovery=0 (adbd needs
ro.adb.secure && ro.adb.secure.recovery). Its only key source is
/data/misc/adb/adb_keys, and userdata holds the iOS root, so this adds
ro.adb.secure.recovery=0 to the ramdisk's prop.default. The cpio entry is
edited in place (owners, modes and device nodes untouched); the AVB footer
is moved to match (its hash no longer matches: fine while unlocked).
Header v2 boot images only.
"""
import gzip, struct, sys, hashlib
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
hv = struct.unpack('<I', d[40:44])[0]; assert hv == 2
ks, ka, rs, ra, ss, sa, ta, ps = struct.unpack('<8I', d[8:40])
pg = lambda n: ((n + ps - 1) // ps) * ps
roff = ps + pg(ks)
cpio = gzip.decompress(d[roff:roff + rs])
out = bytearray(); i = 0; done = 0
while True:
    h = cpio[i:i + 110]; assert h[:6] == b'070701', h[:6]
    f = [int(h[6 + 8 * k:14 + 8 * k], 16) for k in range(13)]
    mode, fsize, nsize = f[1], f[6], f[11]
    name = cpio[i + 110:i + 110 + nsize - 1].decode()
    a = (i + 110 + nsize + 3) & ~3
    data = cpio[a:a + fsize]
    nxt = (a + fsize + 3) & ~3
    if name == 'prop.default' and (mode & 0o170000) == 0o100000:
        assert b'ro.adb.secure.recovery' not in data
        data = data.rstrip(b'\n') + b'\n# pixel3-ios: adb in recovery without the Enable ADB tap\nro.adb.secure.recovery=0\n'
        f[6] = len(data); done += 1
        h = b'070701' + b''.join(b'%08X' % v for v in f)
    out += h + cpio[i + 110:i + 110 + nsize]
    out += b'\0' * ((-len(out)) % 4)
    out += data
    out += b'\0' * ((-len(out)) % 4)
    i = nxt
    if name == 'TRAILER!!!':
        break
out += cpio[i:]
assert done == 1, done
rd = gzip.compress(bytes(out), 9, mtime=0)
hdr = bytearray(d[:ps])
struct.pack_into('<I', hdr, 16, len(rd))
# the rest after the ramdisk (second, recovery dtbo, dtb) is kept as is
rest = d[roff + pg(rs):]
img = bytes(hdr) + d[ps:roff] + rd + b'\0' * (pg(len(rd)) - len(rd)) + rest
# the AVB footer sits in the last 64 bytes of the partition: move it there
# and point it at the (moved) vbmeta blob
assert d[-64:-60] == b'AVBf'
mag, maj, mnr, orig, voff, vsz = struct.unpack('>4sIIQQQ', d[-64:-28])
delta = len(d) - len(img)
assert img[voff - delta:voff - delta + 4] == b'AVB0'
body = img[:-64] if img[-64:-60] == b'AVBf' else img
img = body + b'\0' * (len(d) - 64 - len(body)) + struct.pack('>4sIIQQQ', b'AVBf', maj, mnr, orig - delta, voff - delta, vsz) + d[-28:]
assert len(img) == len(d)
open(dst, 'wb').write(img)
print('ramdisk', rs, '->', len(rd), 'image', len(d), '->', len(img))
