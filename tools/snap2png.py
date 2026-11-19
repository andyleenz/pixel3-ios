#!/usr/bin/env python3
"""Screenshots from the iOS kernel (bluesnap=, patch 0146) to PNG files.

  snap2png.py AREA.bin PREFIX      writes PREFIX-snapN.png, prints the paths

AREA.bin is what tools/phone.sh snaps reads: the 128 MiB of userdata right
below the console log (the last 4100 KiB), up to the used blocks. Block 0:
  "BLUESNPS" | u64 boot nonce | u32 version | u32 count | u32 used blocks
  | u32 area blocks
then per snap a header block
  "BLUESNAP" | u64 nonce | u32 version, index, width, height, bpp, scale,
  bytes, ms since start | i32 ms since SpringBoard (-1) | u32 panel w, h, 0
  | char why[32]
and the pixels, rows top down, padded to a block: bpp 16 = RGB565 little
endian, bpp 32 = B, G, R, A. Python standard library only.
"""
import struct
import sys
import zlib

BLOCK = 4096
AREA = struct.Struct('<8sQIIII')
SNAP = struct.Struct('<8sQIIIIIIIIiIII32s')


def png(path, w, h, rgb):
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data +
                struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))
    stride = w * 3
    raw = b''.join(b'\0' + rgb[y * stride:(y + 1) * stride] for y in range(h))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


def to_rgb(pix, bpp, n):
    out = bytearray(n * 3)
    if bpp == 16:
        # 5/6-bit values to 8 bits by bit replication, one table per channel
        r5 = [(v << 3) | (v >> 2) for v in range(32)]
        g6 = [(v << 2) | (v >> 4) for v in range(64)]
        for i, (v,) in enumerate(struct.iter_unpack('<H', pix[:n * 2])):
            o = i * 3
            out[o] = r5[v >> 11]
            out[o + 1] = g6[(v >> 5) & 63]
            out[o + 2] = r5[v & 31]
    else:
        out[0::3] = pix[2:n * 4:4]
        out[1::3] = pix[1:n * 4:4]
        out[2::3] = pix[0:n * 4:4]
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = open(sys.argv[1], 'rb').read()
    prefix = sys.argv[2]
    if len(data) < BLOCK:
        sys.exit('snap area: short read')
    magic, nonce, version, count, used, blocks = AREA.unpack_from(data, 0)
    if magic != b'BLUESNPS':
        sys.exit('no BLUESNPS header: snaps were never armed on this phone')
    sys.stderr.write('snap area: version %d, %d snaps, %d of %d blocks used\n'
                     % (version, count, used, blocks))
    off = BLOCK
    for i in range(count):
        if off + BLOCK > len(data):
            sys.exit('snap %d: area truncated' % i)
        (m, n2, _v, index, w, h, bpp, scale, nbytes, ms, sb_ms,
         sw, sh, _r, why) = SNAP.unpack_from(data, off)
        if m != b'BLUESNAP' or n2 != nonce:
            sys.exit('snap %d: bad header at block %d' % (i, off // BLOCK))
        pix = data[off + BLOCK:off + BLOCK + nbytes]
        if len(pix) < nbytes or nbytes != w * h * bpp // 8:
            sys.exit('snap %d: %d of %d bytes' % (i, len(pix), w * h * bpp // 8))
        path = '%s-snap%d.png' % (prefix, index)
        png(path, w, h, to_rgb(pix, bpp, w * h))
        why = why.split(b'\0')[0].decode('ascii', 'replace')
        sb = ', SpringBoard +%d.%03d s' % (sb_ms // 1000, sb_ms % 1000) if sb_ms >= 0 else ''
        print('%s  (%s, %d.%03d s%s, %dx%d of %dx%d, %d bpp)'
              % (path, why, ms // 1000, ms % 1000, sb, w, h, sw, sh, bpp))
        off += BLOCK * (1 + (nbytes + BLOCK - 1) // BLOCK)


if __name__ == '__main__':
    main()
