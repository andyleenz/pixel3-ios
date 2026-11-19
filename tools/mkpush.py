#!/usr/bin/env python3
"""Build (or list) a payload of files for the kernel to put into the iOS root.

  mkpush.py OUT.bin [--name NAME] [--rm DEVPATH]... [--mkdir DEVPATH[:MODE[:UID:GID]]]...
            LOCAL:DEVPATH[:MODE[:UID:GID]]...
  mkpush.py --list PAYLOAD.bin

LOCAL may be a file or a directory (copied recursively under DEVPATH).
MODE is octal (default 755 when LOCAL is executable, else 644; directories
755); UID:GID default 0:0. tools/iosfs-push.sh writes the payload into
userdata (recovery), and the kernel applies it at the next boot with
bluepush=1 (patch 0152, bsd/dev/blueline_payload.c, which has the format).

Mach-O files are checked before they go in: arm64 (not arm64e, not x86_64),
built for iOS, and code signed. An unsigned one is signed ad-hoc on a copy
(codesign -s -); --no-sign makes that an error instead.
"""
import argparse
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
import zlib

BLOCK = 4096
MAX_BYTES = 65536 * BLOCK - BLOCK
FILE, DIR, REMOVE = 1, 2, 3
KINDS = {FILE: 'file', DIR: 'dir', REMOVE: 'remove'}
ENTRY = struct.Struct('<IIIIIIQ')
HEADER = struct.Struct('<8sIIQQII32s')

CPU_ARM64, CPU_X86_64 = 0x0100000c, 0x01000007
LC_CODE_SIGNATURE, LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS = 0x1d, 0x32, 0x25
PLATFORMS = {1: 'macOS', 2: 'iOS', 3: 'tvOS', 4: 'watchOS', 6: 'Mac Catalyst', 7: 'iOS simulator'}


def macho_slices(data):
    """(offset, size) of each Mach-O in data; [] when it is not one."""
    if data[:4] == b'\xcf\xfa\xed\xfe':
        return [(0, len(data))]
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[3] == 0xbf
        n = struct.unpack_from('>I', data, 4)[0]
        if n > 32:			# a Java class file shares the magic
            return []
        out, at = [], 8
        for _ in range(n):
            if wide:
                _, _, off, size = struct.unpack_from('>IIQQ', data, at)[:4]
                at += 32
            else:
                _, _, off, size = struct.unpack_from('>IIII', data, at)[:4]
                at += 20
            out.append((off, size))
        return out
    return []


def macho_problems(data):
    """Why a Mach-O will not run on the phone; unsigned is reported separately."""
    problems, unsigned = [], False
    usable = False
    for off, _ in macho_slices(data):
        if data[off:off + 4] != b'\xcf\xfa\xed\xfe':
            continue
        cpu, sub, _, ncmds, _ = struct.unpack_from('<iIIII', data, off + 4)
        cpu &= 0xffffffff
        if cpu != CPU_ARM64:
            continue
        if (sub & 0xff) == 2:
            problems.append('arm64e slice (the phone runs arm64 only)')
            continue
        usable = True
        at, signed, platform = off + 32, False, None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', data, at)
            if cmd == LC_CODE_SIGNATURE:
                signed = True
            elif cmd == LC_BUILD_VERSION:
                platform = struct.unpack_from('<I', data, at + 8)[0]
            elif cmd == LC_VERSION_MIN_IPHONEOS:
                platform = 2
            at += size
        if platform not in (None, 2):
            problems.append('built for %s, not iOS' % PLATFORMS.get(platform, platform))
        unsigned |= not signed
    if not usable and not problems:
        problems.append('no arm64 slice')
    return problems, unsigned


def checked_data(local, no_sign, tmp):
    data = open(local, 'rb').read()
    if not macho_slices(data):
        return data
    problems, unsigned = macho_problems(data)
    if problems:
        sys.exit('%s: %s' % (local, '; '.join(problems)))
    if unsigned:
        if no_sign or not shutil.which('codesign'):
            sys.exit('%s: not code signed (codesign -s - %s)' % (local, local))
        copy = os.path.join(tmp, '%d-%s' % (len(os.listdir(tmp)), os.path.basename(local)))
        shutil.copy2(local, copy)
        subprocess.run(['codesign', '-s', '-', '-f', copy], check=True, capture_output=True)
        print('%s: was unsigned, signed ad-hoc (copy)' % local)
        data = open(copy, 'rb').read()
    return data


def parse_owner(fields, default_mode):
    mode = int(fields[0], 8) if fields and fields[0] else default_mode
    uid = int(fields[1]) if len(fields) > 1 else 0
    gid = int(fields[2]) if len(fields) > 2 else 0
    return mode, uid, gid


def check_path(p):
    parts = p.split('/')
    if not p.startswith('/') or p == '/' or '.' in parts or '..' in parts or p.startswith('/dev/') or \
            len(p.encode()) >= 1024:
        sys.exit('bad device path %r (absolute, no . or .., not under /dev)' % p)
    return p


def entries_from(specs, mkdirs, removes, no_sign, tmp):
    out = []				# (kind, mode, uid, gid, path, data)
    for r in removes:
        out.append((REMOVE, 0, 0, 0, check_path(r), b''))
    for m in mkdirs:
        path, *rest = m.split(':')
        out.append((DIR,) + parse_owner(rest, 0o755) + (check_path(path), b''))
    for spec in specs:
        local, dev, *rest = spec.split(':') + ([] if ':' in spec else [None])
        if dev is None:
            sys.exit('%r: want LOCAL:DEVPATH' % spec)
        dev = check_path(dev.rstrip('/') or '/')
        if os.path.isdir(local):
            # a directory: modes from the local files, UID:GID (if given) for all
            _, uid, gid = parse_owner([''] + rest[1:], 0)
            for top, dirs, files in os.walk(local):
                dirs.sort()
                rel = os.path.relpath(top, local)
                ddir = dev if rel == '.' else dev + '/' + rel
                out.append((DIR, 0o755, uid, gid, check_path(ddir), b''))
                for f in sorted(files):
                    lp = os.path.join(top, f)
                    st = os.lstat(lp)
                    if not stat.S_ISREG(st.st_mode):
                        print('skipped (not a regular file):', lp)
                        continue
                    mode = 0o755 if st.st_mode & 0o111 else 0o644
                    out.append((FILE, mode, uid, gid, check_path(ddir + '/' + f),
                                checked_data(lp, no_sign, tmp)))
        else:
            st = os.stat(local)
            mode, uid, gid = parse_owner(rest, 0o755 if st.st_mode & 0o111 else 0o644)
            out.append((FILE, mode, uid, gid, dev, checked_data(local, no_sign, tmp)))
    return out


def pad8(b):
    return b + bytes(-len(b) % 8)


def build(out_path, name, entries):
    body = bytearray()
    for kind, mode, uid, gid, path, data in entries:
        p = path.encode() + b'\0'
        body += ENTRY.pack(kind, mode, uid, gid, len(p), 0, len(data)) + pad8(p) + pad8(data)
    if not entries:
        sys.exit('nothing to push')
    if len(body) > MAX_BYTES:
        sys.exit('payload is %d MiB; the area holds %d MiB' % (len(body) >> 20, MAX_BYTES >> 20))
    hdr = HEADER.pack(b'BLUEPUSH', 1, len(entries), len(body), int(time.time()),
                      zlib.crc32(bytes(body)) & 0xffffffff, 0, name.encode()[:31])
    blob = hdr + bytes(BLOCK - len(hdr)) + body
    blob += bytes(-len(blob) % BLOCK)
    with open(out_path, 'wb') as f:
        f.write(blob)
    for kind, mode, uid, gid, path, data in entries:
        print('  %-6s %s %s%s' % (KINDS[kind], path, '%d bytes, ' % len(data) if kind == FILE else '',
                                 '%o %d:%d' % (mode, uid, gid) if kind != REMOVE else ''))
    print('%s: %d entries, %d KiB (%d blocks), CRC %08x' %
          (out_path, len(entries), len(body) >> 10, len(blob) // BLOCK, zlib.crc32(bytes(body)) & 0xffffffff))


def listing(path):
    d = open(path, 'rb').read()
    magic, ver, count, nbytes, stamp, crc, _, name = HEADER.unpack_from(d, 0)
    if magic != b'BLUEPUSH':
        sys.exit('%s: no payload (magic %r)' % (path, magic))
    body = d[BLOCK:BLOCK + nbytes]
    ok = len(body) == nbytes and zlib.crc32(body) & 0xffffffff == crc
    print('payload "%s", version %d, %s, %d entries, %d KiB, CRC %08x %s' % (
        name.rstrip(b'\0').decode(errors='replace'), ver, time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(stamp)),
        count, nbytes >> 10, crc, 'ok' if ok else 'BAD (or truncated)'))
    at = 0
    for _ in range(count):
        if at + ENTRY.size > len(body):
            print('  (truncated)')
            break
        kind, mode, uid, gid, plen, _, size = ENTRY.unpack_from(body, at)
        p = body[at + ENTRY.size:at + ENTRY.size + plen].rstrip(b'\0').decode(errors='replace')
        print('  %-6s %s %d bytes %o %d:%d' % (KINDS.get(kind, kind), p, size, mode, uid, gid))
        at += ENTRY.size + (plen + 7) // 8 * 8 + (size + 7) // 8 * 8
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('out', nargs='?')
    ap.add_argument('specs', nargs='*', metavar='LOCAL:DEVPATH[:MODE[:UID:GID]]')
    ap.add_argument('--name', default='')
    ap.add_argument('--rm', action='append', default=[], metavar='DEVPATH')
    ap.add_argument('--mkdir', action='append', default=[], metavar='DEVPATH[:MODE[:UID:GID]]')
    ap.add_argument('--no-sign', action='store_true', help='refuse unsigned Mach-O files')
    ap.add_argument('--list', metavar='PAYLOAD')
    a = ap.parse_intermixed_args()
    if a.list:
        sys.exit(listing(a.list))
    if not a.out:
        ap.error('OUT.bin is needed')
    with tempfile.TemporaryDirectory() as tmp:
        ents = entries_from(a.specs, a.mkdir, a.rm, a.no_sign, tmp)
        build(a.out, a.name or os.path.basename(a.out), ents)


if __name__ == '__main__':
    main()
