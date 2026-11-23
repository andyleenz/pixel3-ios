#!/usr/bin/env python3
"""Build the phone's launchd.plist from the IPSW original, with jobs put back.

  tools/launchd-build.py OUT [LABEL...]

What tools/iosroot-tweaks.py makes of work/orig/System/Library/xpc/launchd.plist
(_PanicOnCrash renamed, the DENY jobs removed, the bluerun job added), except that
each LABEL given is kept. No root and no image: the result goes to the phone with
  tools/phonetest.sh --push OUT:/System/Library/xpc/launchd.plist
e.g. tools/launchd-build.py work/test/launchd-wifid.plist com.apple.wifid
"""
import importlib.util
import os
import plistlib
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('tweaks', os.path.join(here, 'iosroot-tweaks.py'))
tweaks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tweaks)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out, keep = sys.argv[1], set(sys.argv[2:])
    orig = os.path.join(here, '..', 'work/orig/System/Library/xpc/launchd.plist')
    with open(orig, 'rb') as f:
        plist = plistlib.load(f)
    jobs = plist['LaunchDaemons']
    for job in jobs.values():
        if '_PanicOnCrash' in job:
            job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
    gone = [k for k, j in jobs.items()
            if j.get('Label') not in keep and tweaks.denied(k, j)]
    for k in gone:
        del jobs[k]
    jobs[tweaks.BLUERUN_KEY] = dict(tweaks.BLUERUN_JOB)
    kept = sorted(j.get('Label') for j in jobs.values() if j.get('Label') in keep)
    missing = keep - set(kept)
    if missing:
        sys.exit('no such job: ' + ', '.join(sorted(missing)))
    with open(out, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)
    print('%s: %d jobs removed, kept %s' % (out, len(gone), ', '.join(kept) or 'none'))


if __name__ == '__main__':
    main()
