#!/usr/bin/env python3
"""iOS's own log (os_log) from the running phone, over the USB link: no sync, no reboot.

  tools/bluelog.py [--mins N] REGEX     lines whose JSON matches REGEX, from log files
                                        written in the last N minutes (default 30)

Pulls the recently written files of /private/var/db/diagnostics with bluesh (tools/bluesh.py),
pairs them with the string tables in work/oslog/uuidtext (taken once from the root image:
7zz x work/ios-root.img '*/private/var/db/uuidtext/*'; new binaries are rare) and decodes them
with mandiant's unifiedlog_iterator ($UNIFIEDLOG, or work/src/macos-UnifiedLogs/examples/
target/release/unifiedlog_iterator). Output as tools/phonelog.sh: "boot time process | message".
The decoded log is filtered as it is parsed and never written out.
"""
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLUESH = os.path.join(ROOT, 'tools', 'bluesh.py')
DIAG = '/private/var/db/diagnostics'
SUBDIRS = ['', 'Persist', 'Special', 'Signpost', 'HighVolume', 'timesync']


def listing(dirs):
    out = subprocess.run([BLUESH, 'run', '/usr/local/bin/bluels'] + dirs, capture_output=True, text=True).stdout
    cur, files = None, []
    for line in out.splitlines():
        if line.endswith(':') and not line.startswith(' '):
            cur = line[:-1]
            continue
        m = re.match(r'\s+(\d+)\s+(\d+)\s+(\S+ \S+)\s+(.+)$', line)
        if m and cur and int(m.group(1), 8) & 0o170000 == 0o100000:
            t = datetime.datetime.strptime(m.group(3), '%Y-%m-%d %H:%M:%S').replace(tzinfo=datetime.timezone.utc)
            files.append((cur, m.group(4), int(m.group(2)), t))
    return files


def main(argv):
    mins = 30
    if argv[:1] == ['--mins']:
        mins = float(argv[1])
        argv = argv[2:]
    if len(argv) != 1:
        print(__doc__)
        return 2
    ul = os.environ.get('UNIFIEDLOG') or os.path.join(
        ROOT, 'work/src/macos-UnifiedLogs/examples/target/release/unifiedlog_iterator')
    uuidtext = os.path.join(ROOT, 'work/oslog/uuidtext')
    if not os.access(ul, os.X_OK) or not os.path.isdir(uuidtext):
        sys.exit('needs %s and %s (see the header)' % (ul, uuidtext))
    files = listing([DIAG + ('/' + d if d else '') for d in SUBDIRS])
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=mins)
    tmp = tempfile.mkdtemp(prefix='bluelog.')
    try:
        a = os.path.join(tmp, 'phone.logarchive')
        os.makedirs(a)
        for e in os.listdir(uuidtext):
            os.symlink(os.path.join(uuidtext, e), os.path.join(a, e))
        n = size = 0
        for d, name, sz, t in files:
            rel = os.path.relpath(os.path.join(d, name), DIAG)
            # tracev3 files only when recent; the small metadata files always
            if name.endswith('.tracev3') and t < since:
                continue
            os.makedirs(os.path.dirname(os.path.join(a, rel)), exist_ok=True)
            subprocess.run([BLUESH, 'get', os.path.join(d, name), os.path.join(a, rel)], check=True)
            n += 1
            size += sz
        sys.stderr.write('bluelog: %d files, %.0f MB pulled\n' % (n, size / 1e6))
        p = subprocess.Popen([ul, '-m', 'log-archive', '-i', a, '-o', '/dev/stdout'], cwd=tmp,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors='replace')
        rx = re.compile(argv[0])
        for line in p.stdout:
            if not rx.search(line):
                continue
            try:
                j = json.loads(line)
            except ValueError:
                continue
            print((j.get('boot_uuid') or '?')[:6], (j.get('timestamp') or '')[11:23],
                  (j.get('process') or 'pid %s' % j.get('pid')).rsplit('/', 1)[-1], '|',
                  (j.get('message') or '').replace('\n', ' '), flush=True)
        p.wait()
    finally:
        shutil.rmtree(tmp)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
