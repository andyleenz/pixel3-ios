#!/usr/bin/env python3
"""Mac side of tools/bluerun/bluesh.c: the running phone over the USB link.

  tools/bluesh.py run [-t SECONDS] PATH [ARG...]   run, print its output, exit with its status
  tools/bluesh.py put LOCAL REMOTE [MODE]           copy a file onto the phone (MODE octal, default 755
                                                    for executables, else 644)
  tools/bluesh.py get REMOTE LOCAL                  copy a file off the phone
  tools/bluesh.py kill NAME                         SIGKILL processes named NAME (launchd restarts daemons)
  tools/bluesh.py wait [SECONDS]                    wait until bluesh answers
  tools/bluesh.py done                              end the session: the phone reboots as bluereboot= says
  tools/bluesh.py snap OUT.png                      a screenshot now (bluectl snap, kern.bluesnap, 0177)
  tools/bluesh.py touch STEP[;STEP...]              touches now (kern.bluetouch): bluetouchscript= steps,
                                                    time optional: "tap,540,1200;wait,800;swipe,540,2150,540,900,300"

Needs the phone booted with sweetusb=2 and bluesh running (bluerun=/usr/local/bin/bluesh
bluerun_after=launchd bluerun_timeout=36000), and the Mac's "Sweet iOS (USB Ethernet)" service at
192.168.7.1 (networksetup -setmanual, done once). The kernel's live log: tools/usb-live.py.
"""
import os
import socket
import struct
import sys
import time

PHONE = ('192.168.7.2', 2222)


def connect(timeout=10):
    s = socket.create_connection(PHONE, timeout=timeout)
    s.settimeout(None)
    return s


def readline(s):
    b = b''
    while not b.endswith(b'\n'):
        c = s.recv(1)
        if not c:
            break
        b += c
    return b.decode(errors='replace').strip()


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd == 'wait':
        end = time.time() + (float(argv[1]) if len(argv) > 1 else 300)
        while time.time() < end:
            try:
                s = connect(timeout=2)
                s.sendall(b'kill -\n')
                readline(s)
                print('bluesh: up')
                return 0
            except OSError:
                time.sleep(1)
        print('bluesh: no answer')
        return 1
    if cmd == 'snap':
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import importlib
        sp = importlib.import_module('snap2png')
        s = connect()
        s.sendall(b'run 20 /usr/local/bin/bluectl snap\n')
        data = b''
        while True:
            d = s.recv(1 << 20)
            if not d:
                break
            data += d
        if not data.startswith(b'BLUESNAP'):
            print(data[-300:].decode(errors='replace'))
            return 1
        (_m, _n, _v, _i, w, h, bpp, _sc, nbytes, ms, sb_ms, sw, sh, _r, _why) = sp.SNAP.unpack_from(data, 0)
        pix = data[sp.SNAP.size:sp.SNAP.size + nbytes]
        if len(pix) < nbytes:
            print('snap: %d of %d bytes' % (len(pix), nbytes))
            return 1
        sp.png(argv[1], w, h, sp.to_rgb(pix, bpp, w * h))
        print('%s  (%dx%d of %dx%d, SpringBoard +%d ms)' % (argv[1], w, h, sw, sh, sb_ms))
        return 0
    if cmd == 'touch':
        steps = [t if ':' in t else '0:' + t for t in ';'.join(argv[1:]).replace('/', ';').split(';') if t]
        argv = ['run', '/usr/local/bin/bluectl', 'touch', ';'.join(steps)]
        cmd = 'run'
    s = connect()
    if cmd == 'run':
        secs = 60
        if argv[1:2] == ['-t']:
            secs = int(argv[2])
            argv = argv[2:]
        s.sendall(('run %d %s\n' % (secs, ' '.join(argv[1:]))).encode())
        tail = b''
        while True:
            d = s.recv(65536)
            if not d:
                break
            sys.stdout.buffer.write(d)
            sys.stdout.flush()
            tail = (tail + d)[-64:]
        t = tail.decode(errors='replace')
        if '#exit ' in t:
            return int(t.rsplit('#exit ', 1)[1].split()[0])
        return 1
    if cmd == 'put':
        local, remote = argv[1], argv[2]
        mode = argv[3] if len(argv) > 3 else ('755' if os.access(local, os.X_OK) else '644')
        data = open(local, 'rb').read()
        s.sendall(('put %s %s %d\n' % (remote, mode, len(data))).encode() + data)
        r = readline(s)
        print(r)
        return 0 if r == '#ok' else 1
    if cmd == 'get':
        remote, local = argv[1], argv[2]
        s.sendall(('get %s\n' % remote).encode())
        r = readline(s)
        if not r.startswith('#size '):
            print(r)
            return 1
        n = int(r.split()[1])
        with open(local, 'wb') as f:
            while n > 0:
                d = s.recv(min(n, 65536))
                if not d:
                    break
                f.write(d)
                n -= len(d)
        return 0 if n == 0 else 1
    if cmd == 'done':
        s.sendall(b'done\n')
        print(readline(s))
        return 0
    if cmd == 'kill':
        s.sendall(('kill %s\n' % argv[1]).encode())
        print(readline(s))
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
