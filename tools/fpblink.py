#!/usr/bin/env python3
"""Find blinks in a test boot's frame fingerprints (patch 0174).

  tools/fpblink.py work/test/NAME.txt [--show]

The kernel logs "SWEET FP: SWAP MS SURFACE SAME HEX" for each frame shown after a
bluetouchscript step print,N: a 6 x 12 grid of mean greens, one byte a cell.
A frame is a blink when, in some cells, it differs from both its neighbours
while they agree with each other (it came and went: a one-frame flash), or
when it is closer to the frame two before than to the one just before in
the cells that changed (it stepped back to an older picture).
"""
import re
import sys

GX, GY = 6, 12
TH = 12   # a cell "changed" when its mean moves by this much


def frames(path):
    out = []
    pat = re.compile(rb'SWEET FP: (\d+) (\d+) (\d+) \d+ ([0-9a-f]{%d})' % (2 * GX * GY))
    with open(path, 'rb') as f:
        for line in f:
            m = pat.search(line)
            if m:
                out.append((int(m[1]), int(m[2]), int(m[3]), bytes.fromhex(m[4].decode())))
    return out


def main():
    path = sys.argv[1]
    show = '--show' in sys.argv
    fs = frames(path)
    if not fs:
        print('no SWEET FP lines (needs bluetouchscript ...:print,N and patch 0174)')
        return 1
    blinks = 0
    for k in range(1, len(fs) - 1):
        a, b, c = fs[k - 1][3], fs[k][3], fs[k + 1][3]
        flash = [i for i in range(GX * GY)
                 if abs(b[i] - a[i]) >= TH and abs(b[i] - c[i]) >= TH and abs(a[i] - c[i]) < TH // 2]
        back = []
        if k >= 2:
            z = fs[k - 2][3]
            back = [i for i in range(GX * GY)
                    if abs(b[i] - a[i]) >= TH and abs(b[i] - z[i]) < TH // 2 and abs(a[i] - z[i]) >= TH]
        if len(flash) >= 2 or len(back) >= 2:
            blinks += 1
            cells = sorted(set(flash) | set(back))
            where = ' '.join(f'({i % GX},{i // GX})' for i in cells[:12])
            print(f'blink: swap {fs[k][0]} at {fs[k][1]} ms (surface {fs[k][2]}): '
                  f'{len(flash)} cells flash, {len(back)} step back; cells {where}')
            if show:
                for name, fr in (('before', fs[k - 1]), ('this', fs[k]), ('after', fs[k + 1])):
                    print(f'  {name:6} surface {fr[2]}:')
                    for y in range(GY):
                        print('   ', ' '.join(f'{fr[3][y * GX + x]:02x}' for x in range(GX)))
    ms = fs[-1][1] - fs[0][1]
    surfaces = sorted({f[2] for f in fs})
    print(f'{len(fs)} frames over {ms} ms, surfaces {surfaces}: {blinks} blinks')
    return 0


if __name__ == '__main__':
    sys.exit(main())
