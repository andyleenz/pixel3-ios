#!/usr/bin/env python3
"""camera-plists.py OS-VOLUME OUT-DIR - the two Apple plists the stock Camera app needs changed, made from the IPSW.

  tools/camera/camera-plists.py /Volumes/SydneyUpdate20H392.D22D221OS work/camera

Writes, for D22 and D221 (Apple-derived: kept in work/, pushed with phonetest --push):
  OUT/com.apple.jetsamproperties.MODEL.plist  -> /System/Library/LaunchDaemons/
      mediaserverd's InactiveHardMemoryLimit 75 MB -> 1600 MB (its ActiveSoftMemoryLimit). With BlueMetal and Mesa
      loaded it is over 75 MB, and jetsam killed it (per-process-limit) each time Camera went to the background (cam36).
  OUT/AVCaptureSession.MODEL.plist            -> /System/Library/PrivateFrameworks/CMCapture.framework/MODEL/AVCaptureSession.plist
      every *StabilizationSupported and IrisSupported false, the VideoStabilizationTypeOverride* keys removed.
      Otherwise the graph adds BWVISNode, which needs an ISP processing session (CreateProcessingSession, SessionType 4)
      that the plug-in does not have, and the session stops (cam37).
"""
import os
import plistlib
import sys


def unstabilise(x):
    n = 0
    if isinstance(x, dict):
        for k in list(x):
            if k.endswith('StabilizationSupported') or k == 'IrisSupported':
                if x[k] is not False:
                    x[k] = False
                    n += 1
            elif k.startswith('VideoStabilizationTypeOverride'):
                del x[k]
                n += 1
            else:
                n += unstabilise(x[k])
    elif isinstance(x, list):
        for y in x:
            n += unstabilise(y)
    return n


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    vol, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for m in ('D22', 'D221'):
        src = '%s/System/Library/LaunchDaemons/com.apple.jetsamproperties.%s.plist' % (vol, m)
        d = plistlib.load(open(src, 'rb'))
        d['Version4']['Daemon']['Override']['com.apple.mediaserverd']['InactiveHardMemoryLimit'] = 1600
        plistlib.dump(d, open('%s/com.apple.jetsamproperties.%s.plist' % (out, m), 'wb'), fmt=plistlib.FMT_BINARY)
        src = '%s/System/Library/PrivateFrameworks/CMCapture.framework/%s/AVCaptureSession.plist' % (vol, m)
        d = plistlib.load(open(src, 'rb'))
        n = unstabilise(d)
        plistlib.dump(d, open('%s/AVCaptureSession.%s.plist' % (out, m), 'wb'), fmt=plistlib.FMT_BINARY)
        print('%s: jetsam limit raised, %d stabilisation keys changed' % (m, n))


if __name__ == '__main__':
    main()
