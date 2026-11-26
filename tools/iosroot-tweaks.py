#!/usr/bin/env python3
"""Bring-up changes to the iOS root made by tools/mkiosroot.sh.

  sudo tools/iosroot-tweaks.py MOUNTED_ROOT
  sudo tools/iosroot-tweaks.py --only bluerun MOUNTED_ROOT   (just that change)
  sudo tools/iosroot-tweaks.py --only launchd MOUNTED_ROOT   (just the launchd jobs; remigrate.sh)

Idempotent; run as root (files keep their owners). What each change is for
(findings from ios-sweet's bring-up on the same iOS build, see their
NOTES.md; the code here is our own):

  launchd.plist   no daemon may panic the system when it crashes
                  (_PanicOnCrash renamed); CommCenter removed (no baseband);
                  jobs that crash and restart forever without the hardware
                  or services they expect removed (DENY, HackiOS's list)
  containers      /private/var/containers/... exist (normally the data volume)
  migration       recorded as done for this build, datamigrator not loaded
                  (as HackiOS does; lsd builds its database from /Applications)
  audio/media     RedwoodAudio.driver (audio/redwood-hal, built with its
                  build.sh) installed in System/Library/Audio/Plug-Ins/HAL;
                  VirtualAudio kept (mediaserverd needs it), and put back if
                  an older run moved it aside; BTAudioHALPlugin.driver moved
                  to HAL.disabled (bluetoothd is not run: the plugin retried
                  its connection in a tight loop, ~1.2 cores of mediaserverd
                  and launchd at idle, LOG.md 2026-11-23); MediaToolbox's
                  StartRecorderServer key removed again (it gates the camera
                  capture servers too)
  SpringBoard     no watchdogs (CPU rendering is slow), launch watchdogs x20,
                  no cloud-config UI, battery percentage shown
  Setup           marked done, mini-buddies off
  activation      mobileactivationd data ark says Activated (the kernel's
                  device tree selects its no-server "Hactivation" path)
  bluerun         launchd job com.blueline.bluerun: /usr/local/bin/bluerun
                  once per boot, as root (the test runner of
                  tools/phonetest.sh --run; the binary itself is pushed
                  with each test, tools/bluerun/). Without the binary, or
                  without a bluerun= boot-arg, it does nothing.
"""
import glob
import os
import plistlib
import shutil
import sys

BUILD, VERSION = '20H392', '16.7.16'
MOBILE = 501

# Words in the labels of launchd jobs that are removed. HackiOS's list
# (hackios-xnu-userland, userland/mkjobs.py): each of these is missing its
# hardware or service here and crashes or is restarted over and over;
# syncdefaultsd aborts part-way through the migration pass.
# (mobileassetd stays: wallpapers and posters come as mobile assets.)
DENY = ('watchdog', 'CommCenter', 'wifi', 'WiFi', 'bluetooth', 'BTServer', 'locationd', 'softwareupdate',
        'datamigrator', 'backupd', 'thermalmonitord', 'keybagd', 'nfcd', 'biometrickitd', 'pearld',
        'obliterat', 'storage_mounter', 'com.apple.fud', 'sepd', 'seputil', 'camera', 'ReportCrash',
        'osanalytics', 'lockdown', 'audio', 'jetsamproperties', 'purplebuddy', 'restore', 'usb',
        'accessoryd', 'bird', 'homed', 'routined', 'duetexpertd', 'com.apple.dmd',
        'syncdefaultsd', 'photoanalysisd', 'avconferenced',
        # FairPlay needs the Secure Enclave: fairplayd restarts forever, and checkpointd's call
        # to it never returns, which hangs Photos (and anything else that asks checkpointd).
        'fairplayd')

# Jobs kept although a DENY word is in their label. CommCenter in its no-baseband
# form (the job Wi-Fi-only iPads run; launchd loads it when the device tree has
# no baseband node) and its helpers: without them SpringBoard retries the
# CoreTelephony connection every frame, and every failed try resets the idle
# timer, so the screen never locks by itself (LOG.md 2026-11-23). The cellular
# CommCenter job (same label, needs a baseband node) stays out.
KEEP_KEYS = ('/System/Library/LaunchDaemons/com.apple.CommCenter-noncellular.plist',
             '/System/Library/LaunchDaemons/com.apple.CommCenterRootHelper.plist',
             '/System/Library/LaunchDaemons/com.apple.CommCenterMobileHelper.plist')


def denied(key, job):
    """Whether launchd job KEY is removed: a DENY word in its label, not in KEEP_KEYS."""
    return key not in KEEP_KEYS and any(w in job.get('Label', '') for w in DENY)


def read_plist(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)


def write_plist(path, data, uid, gid, mode, fmt=plistlib.FMT_BINARY):
    with open(path, 'wb') as f:
        plistlib.dump(data, f, fmt=fmt)
    os.chown(path, uid, gid)
    os.chmod(path, mode)


def rewrite(path, change, fmt=plistlib.FMT_BINARY):
    """Apply change(data) to a plist in place, keeping owner and mode."""
    st = os.stat(path)
    data = read_plist(path)
    change(data)
    write_plist(path, data, st.st_uid, st.st_gid, st.st_mode & 0o7777, fmt)


def preferences(root, domain, values):
    d = os.path.join(root, 'private/var/mobile/Library/Preferences')
    path = os.path.join(d, domain + '.plist')
    data = read_plist(path) if os.path.exists(path) else {}
    data.update(values)
    write_plist(path, data, MOBILE, MOBILE, 0o600)
    print('preferences', domain, ', '.join(sorted(values)))


def launchd_jobs(root):
    def change(plist):
        jobs = plist['LaunchDaemons']
        n = 0
        for job in jobs.values():
            if '_PanicOnCrash' in job:
                job['_PanicOnCrasX'] = job.pop('_PanicOnCrash')
                n += 1
        gone = sorted(k for k, j in jobs.items() if denied(k, j))
        for k in gone:
            del jobs[k]
        print('launchd.plist: %d _PanicOnCrash renamed, %d jobs removed:' % (n, len(gone)))
        for k in gone:
            print('   ', k)
    rewrite(os.path.join(root, 'System/Library/xpc/launchd.plist'), change)


BLUERUN_KEY = '/System/Library/LaunchDaemons/com.blueline.bluerun.plist'
BLUERUN_JOB = {
    'Label': 'com.blueline.bluerun',
    'ProgramArguments': ['/usr/local/bin/bluerun'],
    'RunAtLoad': True,
    'LaunchOnlyOnce': True,
    'UserName': 'root',
    'POSIXSpawnType': 'Interactive',	# no background throttling for GPU tests
}


def bluerun_job(root):
    def change(plist):
        jobs = plist['LaunchDaemons']
        state = 'unchanged' if jobs.get(BLUERUN_KEY) == BLUERUN_JOB else 'replaced' if BLUERUN_KEY in jobs else 'added'
        jobs[BLUERUN_KEY] = dict(BLUERUN_JOB)
        print('launchd.plist: job com.blueline.bluerun', state)
    rewrite(os.path.join(root, 'System/Library/xpc/launchd.plist'), change)


def containers(root):
    for sub, owner in (('Bundle', 33), ('Data/System', 0), ('Shared/SystemGroup', 0), ('Temp', 0)):
        d = os.path.join(root, 'private/var/containers', sub)
        if not os.path.isdir(d):
            os.makedirs(d, 0o755)
            os.chown(d, owner, owner)
            print('created', os.path.relpath(d, root))


def system_container(root, identifier):
    pattern = os.path.join(root, 'private/var/containers/Data/System/*/'
                           '.com.apple.mobile_container_manager.metadata.plist')
    for meta in glob.glob(pattern):
        if read_plist(meta).get('MCMMetadataIdentifier') == identifier:
            return os.path.dirname(meta)
    return None


def activation(root):
    c = system_container(root, 'com.apple.mobileactivationd')
    if not c:
        print('note: no mobileactivationd container in the image yet; data ark skipped')
        return
    d = os.path.join(c, 'Library/internal')
    os.makedirs(d, exist_ok=True)
    os.chown(d, MOBILE, MOBILE)
    write_plist(os.path.join(d, 'data_ark.plist'), {
        '-ActivationState': 'Activated', '-BrickState': False,
        '-BuildVersion': BUILD, '-ProductVersion': VERSION,
        '-DataMigrationCompleted': True, '-PreSydroDataMigrationCompleted': True,
    }, MOBILE, MOBILE, 0o600)
    print('activation data ark written')


def migration_done(root):
    """Record the data migration as done for this build (undoes migration-reset.py)."""
    preferences(root, 'com.apple.migration', {
        'LastSystemVersion': BUILD,
        'DMLastMigrationResults': {'success': True, 'buildVersion': BUILD}})
    sentinel = os.path.join(root, 'private/var/datamigrator/migrate')
    if os.path.exists(sentinel):
        os.remove(sentinel)
        print('datamigrator sentinel removed')


def audio_media(root):
    hal = os.path.join(root, 'Library/Audio/Plug-Ins/HAL')
    aside = os.path.join(root, 'Library/Audio/Plug-Ins/HAL.disabled/VirtualAudio.plugin')
    if os.path.exists(aside) and not os.path.exists(os.path.join(hal, 'VirtualAudio.plugin')):
        os.makedirs(hal, exist_ok=True)
        shutil.move(aside, hal)
        print('VirtualAudio.plugin put back')
    bt = os.path.join(root, 'System/Library/Audio/Plug-Ins/HAL/BTAudioHALPlugin.driver')
    if os.path.isdir(bt):
        bt_aside = os.path.join(root, 'System/Library/Audio/Plug-Ins/HAL.disabled')
        os.makedirs(bt_aside, exist_ok=True)
        shutil.move(bt, bt_aside)
        print('BTAudioHALPlugin.driver moved aside (no bluetoothd)')
    driver = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../audio/redwood-hal/out/RedwoodAudio.driver')
    if os.path.isdir(driver):
        dest = os.path.join(root, 'System/Library/Audio/Plug-Ins/HAL/RedwoodAudio.driver')
        if os.path.exists(dest):
            shutil.rmtree(dest)
        shutil.copytree(driver, dest)
        print('RedwoodAudio.driver installed')
    else:
        print('RedwoodAudio.driver not built (audio/redwood-hal/build.sh): no sound from iOS')
    for conf in glob.glob(os.path.join(
            root, 'System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist')):
        # An older run set StartRecorderServer False; that also stopped the capture servers
        # (FigStartCaptureServers: com.apple.coremedia.capturesession), so AVFoundation's
        # camera calls got no answer (LOG.md 2026-11-26). Apple's value (absent: start) is restored.
        rewrite(conf, lambda d: d.pop('StartRecorderServer', None), plistlib.FMT_XML)
        print('MediaToolbox recorder and capture servers on (Apple default)')


def main():
    args = sys.argv[1:]
    only = None
    if len(args) == 3 and args[0] == '--only' and args[1] in ('bluerun', 'launchd'):
        only, args = args[1], args[2:]
    if len(args) != 1 or not os.path.isdir(os.path.join(args[0], 'System/Library/xpc')):
        sys.exit(__doc__)
    if os.geteuid() != 0:
        sys.exit('run as root')
    root = args[0]
    if only == 'bluerun':
        bluerun_job(root)
        return
    if only == 'launchd':
        launchd_jobs(root)
        return
    launchd_jobs(root)
    bluerun_job(root)
    containers(root)
    activation(root)
    audio_media(root)
    migration_done(root)
    preferences(root, 'com.apple.springboard', {
        'BKNoWatchdogs': True, 'FBLaunchWatchdogScale': 20, 'SBShowBatteryPercentage': True,
        'FBLaunchWatchdogExceptions': {'com.apple.purplebuddy': 100.0},
        'MCForceShowCloudConfigurationUI': False})
    preferences(root, 'com.apple.purplebuddy', {
        'SetupDone': True, 'SetupFinishedAllSteps': True, 'SetupVersion': 11,
        'ForceNoBuddy': True, 'SetupState': 'SetupUsingAssistant',
        'daemonizeNeedsToRun': False})
    preferences(root, 'com.apple.purplebuddy.notbackedup', dict.fromkeys((
        'ShouldRunDiagnosticsMiniBuddy', 'ShouldRunHSA2MiniBuddy', 'ShouldRunKeychainSyncMiniBuddy',
        'ShouldRunMesaMiniBuddy', 'ShouldRunPaymentMiniBuddy', 'ShouldRunStandardMiniBuddy',
        'SilentICDPUpgrade'), False))
    preferences(root, 'com.apple.frontboard', {'FBLaunchWatchdogScale': 20})
    preferences(root, 'com.apple.managedconfiguration.notbackedup', {
        'LockdownActivationIndicatesCloudConfigurationAvailable': False})


if __name__ == '__main__':
    main()
