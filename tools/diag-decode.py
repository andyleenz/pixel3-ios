#!/usr/bin/env python3
"""diag-decode.py LOG [QDB] - decode the modem's F3 messages from a phonetest log (kernel 0244, bluediag=1).

Reads "BLUELINE DIAG: < N HEX" lines; QDB (default work/fw/modem/img/image/qdsp6m.qdb, from the radio image) is
the QShrink 4 hash database: 64-byte header ("\\x7fQDB", GUID), then zlib text with a <Content> section of
"hash:subsys_mask:ssid:line:file:format" lines.

Packets (layouts as in fgsect/scat's qualcommparser.py):
  0x79 EXT_MSG       B cmd, B ts_type, B nargs, B drop, Q ts, H line, H ssid, L mask, L args[nargs], fmt\\0 file\\0
  0x92 QSR_EXT_MSG   the same header, L hash, L args[nargs]
  0x99 QSR4_EXT_MSG  B cmd, B ts_type, B nargs (high nibble: count, low: bytes each), B drop, Q ts, L hash, H ?, args
"""
import re
import struct
import sys
import zlib


def load_qdb(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fQDB':
        sys.exit('%s: not a QShrink 4 database' % path)
    text = zlib.decompress(d[64:]).decode('latin1')
    table, on = {}, False
    for line in text.split('\n'):
        s = line.strip()
        if s.startswith('<Content>'):
            on = True
        elif s.startswith('<\\Content>') or s.startswith('</Content>'):
            on = False
        elif on and s and not s.startswith('#'):
            f = line.rstrip('\r').split(':', 5)
            if len(f) == 6 and f[0].isdigit():
                table[int(f[0])] = (int(f[2]), int(f[3]), f[4], f[5])  # ssid, line, file, format
    return table


SPEC = re.compile(r'%[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|z|t|j)?([diouxXcsp%])')


def fmt(f, args):
    out, i = [], 0

    def one(m):
        nonlocal i
        c = m.group(1)
        if c == '%':
            return '%'
        if i >= len(args):
            return m.group(0)
        v = args[i]
        i += 1
        if c in 'di':
            v = v - (1 << 32) if v & 0x80000000 else v
            return str(v)
        if c in 'xXp':
            return '%x' % v
        if c == 'c':
            return chr(v & 0xff)
        if c == 's':
            return '<str@%x>' % v
        return str(v)
    return SPEC.sub(one, f)


def ts_s(t):
    # upper 48 bits: 1.25 ms ticks; lower 16: 1/32 of those (QXDM time). Shown as seconds from the first message.
    return (t >> 16) * 1.25e-3 + (t & 0xffff) / 32.0 * 1.25e-3 / 1024


def decode(p, qdb):
    c = p[0]
    if c == 0x79 and len(p) >= 20:
        _, _, n, drop, t, line, ssid, _ = struct.unpack('<BBBBQHHL', p[:20])
        args = list(struct.unpack('<%dL' % n, p[20:20 + 4 * n]))
        body = p[20 + 4 * n:].rstrip(b'\0').split(b'\0')
        f = body[0].decode('latin1', 'replace')
        fn = body[-1].decode('latin1', 'replace') if len(body) > 1 else ''
        return t, ssid, '%s:%u' % (fn, line), fmt(f, args), drop
    if c == 0x92 and len(p) >= 24:
        _, _, n, drop, t, line, ssid, _ = struct.unpack('<BBBBQHHL', p[:20])
        h, = struct.unpack('<L', p[20:24])
        args = list(struct.unpack('<%dL' % n, p[24:24 + 4 * n]))
        e = qdb.get(h)
        return t, ssid, '%s:%u' % (e[2], e[1]) if e else '?', fmt(e[3], args) if e else 'hash %u %s' % (h, args), drop
    if c == 0x99 and len(p) >= 18:
        _, _, ns, drop, t, h, _ = struct.unpack('<BBBBQLH', p[:18])
        n, size = ns >> 4, ns & 15
        a = p[18:]
        args = [int.from_bytes(a[k * size:(k + 1) * size], 'little') for k in range(n)] if size else []
        e = qdb.get(h)
        if e:
            return t, e[0], '%s:%u' % (e[2], e[1]), fmt(e[3], args), drop
        return t, -1, '?', 'hash %u %s' % (h, args), drop
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    qdb = load_qdb(sys.argv[2] if len(sys.argv) > 2 else 'work/fw/modem/img/image/qdsp6m.qdb')
    t0, other = None, {}
    for line in open(sys.argv[1], errors='replace'):
        m = re.search(r'BLUELINE DIAG: < (\d+) ([0-9a-f]+)', line)
        if not m:
            if 'BLUELINE DIAG:' in line:
                print(line.rstrip()[line.find('BLUELINE DIAG:'):])
            continue
        p = bytes.fromhex(m.group(2))
        r = decode(p, qdb)
        if not r:
            other[p[0]] = other.get(p[0], 0) + 1
            continue
        t, ssid, where, text, drop = r
        t0 = t if t0 is None else t0
        print('%9.3f %5d %-40s %s%s' % (ts_s(t) - ts_s(t0), ssid, where[:40], text, ' (dropped %d)' % drop if drop else ''))
    if other:
        print('other packets by command:', ', '.join('0x%02x x%d' % kv for kv in sorted(other.items())))


if __name__ == '__main__':
    main()
