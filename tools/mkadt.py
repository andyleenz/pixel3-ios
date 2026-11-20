#!/usr/bin/env python3
"""Generate the Apple Device Tree for XNU on the Pixel 3 (blueline).

  mkadt.py OUT.adt [--qemu] [--cpus N] [--ufs] [--iphone DT.im4p]
                   [--gpu-fw a630_gmu.bin [--gpu-sqe auto|vendor|linux|none|PATH]
                    [--gpu-zap auto|none|PATH.mdt]]
                   [--haptic-fw DIR]
                   [--dump]

The kernel is ios-sweet's SWEET machine config, so this provides what
that boot path reads: /chosen (RAM range, entropy), /cpus, /arm-io/gic,
the "sweet-fbcon" framebuffer node and /defaults. Values come from the
README (probe runs, mainline sdm845.dtsi).

Names the kernel matches on: the root lists "xiaomi,sweet" and the CPUs
list "qcom,kryo470" because ios-sweet's platform expert and CPU driver
match those strings; the blueline names come first.

Storage only with --ufs: adds /sweet-ufs, the UFS host at 0x1d84000 that
ios-sweet's root driver uses (rd=ufsroot0; read-only unless the boot-arg
ufsrw=1 is also given). Without it the kernel cannot reach the phone's UFS.

--iphone presents the board as the iPhone X (iPhone10,3 / D22AP) whose
iOS 16.7.16 userland runs on it: root identity, the /chosen, /buttons,
/arm-io/wdt and /arm-io/disp0 properties its daemons read, and /product
copied from the real D22AP device tree (DeviceTree.d22ap.im4p from the
IPSW; Apple's file, never stored here). Which properties matter and why is
from ios-sweet's bring-up notes.

--gpu-fw adds /blueline-gpu with "gmu-firmware": the Adreno 630 GMU's
firmware (qcom/a630_gmu.bin from linux-firmware, 32768 bytes, a raw
Cortex-M3 TCM image), which xnu patch 0126 loads at boot-arg bluegpu=3.
It is not redistributable here: tools/fetch-gpu-fw.sh downloads the pinned
copy into work/fw/ (ignored by git) and checks its SHA-256; this checks it
again. The kernel logs the image's 32-bit word sum, printed here too.

--haptic-fw DIR adds /blueline-haptic with "wmfw" (DIR/cs40l20.wmfw, the
CS40L20's DSP program) and "wavetable" (DIR/cs40l20.bin), the vendor
partition's /firmware copies (work/fw/vendor/, ignored by git: debugfs
from the OTA's vendor.img), loaded by xnu patch 0150 at bluehaptic=2.
It also adds "sqe-firmware", the CP's SQE microcode (a630_sqe.fw, the
whole file; the kernel drops dword 0 as Linux does), for xnu 0137 at
bluegpu=6. --gpu-sqe picks it: auto (default) takes the phone's own
vendor copy at DIR/vendor/a630_sqe.fw if present, else linux-firmware's
DIR/a630_sqe.fw (DIR = --gpu-fw's directory), else none; vendor/linux
insist on that one; none leaves it out; or a path. Only the two pinned
SHA-256s are accepted, and Linux's a630 version check must pass.
And "zap-elf", the GPU's zap shader for xnu 0144 (bluegpu=7, PAS id 13):
the phone's own /vendor/firmware a630_zap.mdt + .b00..b0N (Google-signed
for blueline; never committed, work/fw/vendor only), squashed into one
ELF the way pil-squasher does (segment N at its p_offset), checked as
Linux's mdt_loader checks it (header, hash segment, metadata == the .mdt
for a split image, loadable span within the 0x2000 gpu_mem region) and,
if DIR/vendor/a630_zap.elf exists, byte-compared with it. --gpu-zap: auto
(default) takes DIR/vendor/a630_zap.mdt if present, else none; none
leaves it out; or a .mdt path. Only the pinned SHA-256 is accepted.

--qemu swaps in QEMU virt's GIC, timer frequency and timer interrupt
(-M virt,gic-version=3) for emulator tests.
"""
import argparse
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from adt import Node, dump, load, parse, serialize, strs, u32, u64  # noqa: E402

# qcom/a630_gmu.bin, linux-firmware 88ea23e7 (unchanged since; see
# tools/fetch-gpu-fw.sh). Legacy image: 16K ITCM then 16K DTCM.
GMU_FW_SIZE = 0x8000
GMU_FW_SHA256 = 'da8d9b1b1f5c1a0b311f32567093b4828f3c80031dd8435f91ac13c664e173a6'


def gmu_firmware(path):
    """The GMU image, checked: size, hash, vector table (SP in DTCM, Thumb reset in ITCM)."""
    fw = open(path, 'rb').read()
    digest = hashlib.sha256(fw).hexdigest()
    sp, reset = struct.unpack_from('<II', fw) if len(fw) >= 8 else (0, 0)
    if len(fw) != GMU_FW_SIZE or not 0x40000 <= sp <= 0x44000 or not reset & 1 or reset >= 0x4000:
        sys.exit('--gpu-fw %s: not a legacy a630_gmu.bin (%d bytes, sp %#x, reset %#x)'
                 % (path, len(fw), sp, reset))
    if digest != GMU_FW_SHA256:
        sys.exit('--gpu-fw %s: sha256 %s, expected %s (linux-firmware 88ea23e7)'
                 % (path, digest, GMU_FW_SHA256))
    return fw


# a630_sqe.fw candidates. dword[1] is the version word (Linux's buf[0]):
# a6xx_ucode_check_version accepts a630 if (word & 0xfff) >= 0x190, or the
# word ends in 0xa (patched build) with dword[3] & 0xf >= 1.
SQE_FW_KNOWN = {
    # linux-firmware 75f16899 (v2.07), tools/fetch-gpu-fw.sh
    '1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c': 'linux-firmware 75f16899',
    # the phone's /vendor/firmware (LineageOS 22.2 blueline vendor image, Google's blob)
    '36298bd53ea3666413d288a3a3f5266f67fcb6db038a0a481af5869d1c17859c': 'blueline vendor',
}
SQE_FW_MAX = 0x9000 + 4		# xnu 0137: SQE window at GPU VA 0x01000000, + dword 0

# a630_zap: the squashed ELF (pil-squasher layout) of the phone's split
# /vendor/firmware a630_zap.mdt + .b00-.b02 (LineageOS 22.2 blueline vendor
# image, Google's blob), which is also the vendor's own a630_zap.elf.
ZAP_KNOWN = {
    'b5e73cff5e70c5cff5abbf41017039855a8aa0fef75ff583f40499a1bca866de': 'blueline vendor',
}
ZAP_REGION_SIZE = 0x2000		# sdm845.dtsi gpu_mem 0x8c415000, xnu 0144
ZAP_FILE_MAX = 0x10000			# xnu 0144's limit
ZAP_META_MAX = 0x4000


def zap_phdrs(elf, what):
    """mdt_header_valid: the program headers of a 32-bit ELF."""
    if len(elf) < 52 or elf[:4] != b'\x7fELF' or elf[4] != 1:
        sys.exit('--gpu-zap %s: not a 32-bit ELF' % what)
    phoff, = struct.unpack_from('<I', elf, 0x1c)
    phentsize, phnum, shentsize, shnum = struct.unpack_from('<HHHH', elf, 0x2a)
    if phentsize != 32 or phnum < 2 or phoff + 32 * phnum > len(elf) or shentsize or shnum:
        sys.exit('--gpu-zap %s: ELF header not valid for mdt_loader' % what)
    return [struct.unpack_from('<8I', elf, phoff + 32 * i) for i in range(phnum)]


def zap_firmware(choice, gmu_path):
    """The squashed zap ELF to embed (bytes, description) or (None, why)."""
    d = os.path.join(os.path.dirname(os.path.abspath(gmu_path)), 'vendor')
    if choice == 'none':
        return None, 'left out (--gpu-zap none)'
    mdt_path = os.path.join(d, 'a630_zap.mdt') if choice == 'auto' else choice
    if not os.path.isfile(mdt_path):
        if choice == 'auto':
            return None, 'none found (%s)' % mdt_path
        sys.exit('--gpu-zap %s: no such file' % mdt_path)
    if not mdt_path.endswith('.mdt'):
        sys.exit('--gpu-zap %s: want the .mdt (its .bNN next to it)' % mdt_path)
    mdt = open(mdt_path, 'rb').read()
    log = ['%s sha256 %s' % (os.path.basename(mdt_path), hashlib.sha256(mdt).hexdigest())]
    ph = zap_phdrs(mdt, mdt_path)
    if ph[0][0] == 1:
        sys.exit('--gpu-zap %s: phdr 0 is PT_LOAD' % mdt_path)
    hashes = [i for i in range(1, len(ph)) if ph[i][6] & (7 << 24) == 2 << 24]
    if not hashes:
        sys.exit('--gpu-zap %s: no hash segment' % mdt_path)
    ehdr_size, hash_size = ph[0][4], ph[hashes[0]][4]
    if ehdr_size + hash_size != len(mdt):
        sys.exit('--gpu-zap %s: %d bytes, not header %#x + hash %#x: not a split image\'s .mdt'
                 % (mdt_path, len(mdt), ehdr_size, hash_size))
    # pil-squasher: every segment with bytes, from its .bNN, at its p_offset
    size = max(p[1] + p[4] for p in ph if p[4])
    elf = bytearray(size)
    for i, (typ, off, va, pa, filesz, memsz, flags, align) in enumerate(ph):
        if not filesz:
            continue
        seg_path = mdt_path[:-4] + '.b%02d' % i
        if not os.path.isfile(seg_path):
            sys.exit('--gpu-zap %s: missing (segment %d, %#x bytes)' % (seg_path, i, filesz))
        seg = open(seg_path, 'rb').read()
        log.append('%s sha256 %s' % (os.path.basename(seg_path), hashlib.sha256(seg).hexdigest()))
        if len(seg) != filesz:
            sys.exit('--gpu-zap %s: %d bytes, phdr %d says %#x' % (seg_path, len(seg), i, filesz))
        elf[off:off + filesz] = seg
    elf = bytes(elf)
    # qcom_mdt_read_metadata on the squashed file must give the .mdt back
    if elf[:ehdr_size] + elf[ph[hashes[0]][1]:ph[hashes[0]][1] + hash_size] != mdt:
        sys.exit('--gpu-zap %s: the .bNN do not match the .mdt\'s header and hash' % mdt_path)
    load = [p for p in ph if p[0] == 1 and p[6] & (7 << 24) != 2 << 24 and p[5]]
    if not load or any(p[4] > p[5] for p in load):
        sys.exit('--gpu-zap %s: no loadable segment, or p_filesz > p_memsz' % mdt_path)
    span = max((p[3] + p[5] + 0xfff) & ~0xfff for p in load) - min(p[3] for p in load)
    if span > ZAP_REGION_SIZE or len(elf) > ZAP_FILE_MAX or len(mdt) > ZAP_META_MAX:
        sys.exit('--gpu-zap %s: image %#x (region %#x), file %d, metadata %d: too big'
                 % (mdt_path, span, ZAP_REGION_SIZE, len(elf), len(mdt)))
    vendor_elf = mdt_path[:-4] + '.elf'
    if os.path.isfile(vendor_elf):
        same = open(vendor_elf, 'rb').read() == elf
        log.append('%s %s' % (os.path.basename(vendor_elf), 'identical' if same else 'DIFFERS'))
        if not same:
            sys.exit('--gpu-zap %s: the squashed image differs from %s' % (mdt_path, vendor_elf))
    digest = hashlib.sha256(elf).hexdigest()
    if digest not in ZAP_KNOWN:
        sys.exit('--gpu-zap %s: squashed sha256 %s is not a known a630_zap' % (mdt_path, digest))
    return elf, ('%s (%s), squashed sha256 %s, metadata %d bytes, load span %#x; %s'
                 % (mdt_path, ZAP_KNOWN[digest], digest, len(mdt), span, ', '.join(log)))


def sqe_version_ok(fw):
    """(version word, accepted) as Linux's a630 check sees the file."""
    if len(fw) < 16:
        return 0, False
    _, ver, _, pl = struct.unpack_from('<4I', fw)
    return ver, ((ver & 0xf) == 0xa and (pl & 0xf) >= 1) or (ver & 0xfff) >= 0x190


def sqe_firmware(choice, gmu_path):
    """The SQE image to embed (bytes, description) or (None, why)."""
    d = os.path.dirname(os.path.abspath(gmu_path))
    vendor, linux = os.path.join(d, 'vendor', 'a630_sqe.fw'), os.path.join(d, 'a630_sqe.fw')
    if choice == 'none':
        return None, 'left out (--gpu-sqe none)'
    if choice == 'auto':
        path = vendor if os.path.isfile(vendor) else linux if os.path.isfile(linux) else None
        if path is None:
            return None, 'none found (%s, %s; tools/fetch-gpu-fw.sh)' % (vendor, linux)
    else:
        path = {'vendor': vendor, 'linux': linux}.get(choice, choice)
    fw = open(path, 'rb').read()
    digest = hashlib.sha256(fw).hexdigest()
    ver, ok = sqe_version_ok(fw)
    if digest not in SQE_FW_KNOWN:
        sys.exit('--gpu-sqe %s: sha256 %s is not a known a630_sqe.fw' % (path, digest))
    if not ok or len(fw) > SQE_FW_MAX or len(fw) % 4:
        sys.exit('--gpu-sqe %s: %d bytes, version word %#x: not usable (Linux needs >= 0x190 or a patched'
                 ' ..a build; at most %d bytes)' % (path, len(fw), ver, SQE_FW_MAX))
    return fw, '%s (%s), version word %#x' % (path, SQE_FW_KNOWN[digest], ver)


# Kernel-managed RAM: above every fixed carve-out in both the mainline and
# the LineageOS device tree (README, "Second run"), 32 MiB aligned at both
# ends (XNU maps it with 16K-granule L2 blocks).
DRAM_BASE = 0xf4000000
DRAM_SIZE = 0x17e000000 - DRAM_BASE		# RAM ends at 0x17e0a0000

# /arm-io children are relative to this. It must not be 0: ios-sweet's
# serial setup treats a zero SoC base as "no SoC".
SOC_BASE = 0x01000000

FB, FB_W, FB_H = 0x9d400000, 1080, 2160
FB_STRIDE = FB_W * 4
FB_SIZE = 0x900000				# 1080*2160*4 = 0x8e6200, rounded up

PHONE = dict(gicd=0x17a00000, gicr=0x17a60000, timebase=19200000,
             vtimer=19)			# Qualcomm PPI 3 = INTID 19
QEMU = dict(gicd=0x08000000, gicr=0x080a0000, timebase=62500000,
            vtimer=27)			# QEMU virt: PPI 11 = INTID 27
GICD_SIZE, GICR_SIZE = 0x10000, 0x100000	# 8 redistributors x 0x20000

# Kryo 385: cores 0-3 Silver (A55-class), 4-7 Gold (A75-class), MPIDR
# core number in Aff1 (boot CPU MPIDR 0x81000000).
CPU_HZ = [1766400000] * 4 + [2803200000] * 4

# ufshc@1d84000 "std" registers (mainline sdm845.dtsi: size 0x2500)
UFS, UFS_SIZE = 0x01d84000, 0x3000


# --iphone: synthetic ECID (not any real device's), A11 chip id
ECID = 0x504958454c330001			# 'PIXEL3' + 1
CHIP_ID = 0x8015


def d22ap_product(im4p):
    """/product of the real D22AP tree, minus iBoot placeholders and bookkeeping."""
    root, _ = parse(load(im4p))
    for c in root.children:
        if c.name == 'product':
            return [(k, v) for k, v, ph in c.props if not ph and k not in ('name', 'AAPL,phandle')]
    sys.exit('%s: no /product node' % im4p)


def haptic_firmware(d):
    """cs40l20.wmfw + cs40l20.bin from DIR, checked for their magic."""
    wmfw = open(os.path.join(d, 'cs40l20.wmfw'), 'rb').read()
    wt = open(os.path.join(d, 'cs40l20.bin'), 'rb').read()
    if wmfw[:4] != b'WMFW' or len(wmfw) & 3 or wt[:4] != b'WMDR':
        sys.exit('--haptic-fw %s: cs40l20.wmfw / cs40l20.bin are not WMFW / WMDR files' % d)
    return wmfw, wt


def wlan_firmware(d):
    """wlanmdsp.mbn (an ELF) + bdwlan-blueline.bin from DIR (the vendor image's /firmware)."""
    mdsp = open(os.path.join(d, 'wlanmdsp.mbn'), 'rb').read()
    bdf = open(os.path.join(d, 'bdwlan-blueline.bin'), 'rb').read()
    if mdsp[:4] != b'\x7fELF':
        sys.exit('--wlan-fw %s: wlanmdsp.mbn is not an ELF' % d)
    return mdsp, bdf


def build(qemu=False, cpus=1, seed=None, ufs=False, iphone=None, gpu_fw=None, sqe_fw=None, zap_fw=None,
          haptic_fw=None, wlan_fw=None):
    hw = QEMU if qemu else PHONE
    phandles = iter(range(1, 1 << 16))

    def node(name, props=None, children=None):
        n = Node(name, props, children)
        n.set('AAPL,phandle', u32(next(phandles)))
        return n

    chosen = node('chosen', {
        'dram-base': u64(DRAM_BASE),
        'dram-size': u64(DRAM_SIZE),
        'random-seed': seed if seed is not None else os.urandom(64),
        'debug-enabled': u32(1),
        'firmware-version': strs('pixel3-shim'),
        'system-firmware-version': strs('pixel3-shim'),
    }, [
        node('memory-map'),		# mkpayload.py adds RAMDisk here
        # Boot policy as with `csrutil disable` plus an unsealed root;
        # XNU reads it from /chosen/asmb (kern_csr.c).
        node('asmb', {'lp-sip0': u64(0x6f), 'lp-sip1': u32(1)}),
    ])

    cpu_nodes = []
    for core in range(cpus):
        cpu_nodes.append(node('cpu%d' % core, {
            'device_type': strs('cpu'),
            'compatible': strs('qcom,kryo385', 'qcom,kryo470', 'ARM,v8'),
            'reg': u32(0 if qemu else core << 8),	# MPIDR Aff1:Aff0
            'cpu-id': u32(core),
            'cluster-id': u32(0),
            'cluster-type': u32(0),		# one homogeneous SMP cluster
            'state': strs('running' if core == 0 else 'stopped'),
            'timebase-frequency': u32(hw['timebase']),
            'clock-frequency': u32(CPU_HZ[core]),
            'bus-frequency': u32(100000000),
            'peripheral-frequency': u32(hw['timebase']),
            'fixed-frequency': u32(hw['timebase']),
        }))
    cpus_node = node('cpus', {'#address-cells': u32(1), '#size-cells': u32(0)}, cpu_nodes)

    gic = node('gic', {
        'compatible': strs('arm,gic-v3'),
        'interrupt-controller': b'',
        'virtual-timer-intid': u32(hw['vtimer']),
        'reg': u64(hw['gicd'] - SOC_BASE, GICD_SIZE, hw['gicr'] - SOC_BASE, GICR_SIZE),
    })
    arm_io = node('arm-io', {
        'device_type': strs('sweet-io'),
        'compatible': strs('sweet-io', 'arm-io'),
        '#address-cells': u32(2),
        '#size-cells': u32(2),
        'ranges': u64(0, SOC_BASE, (1 << 32) - SOC_BASE),
    }, [gic])
    if wlan_fw is not None:
        # launchd starts wifid only when the device tree has a "wlan" node (com.apple.wifid's
        # _LimitLoadToDeviceTree: wlan, marconi-wifi); as ios-topaz's mkadt.py does.
        arm_io.children.append(node('wlan', {
            'device_type': strs('wlan'),
            'compatible': strs('blueline,wcn3990'),
        }))

    fbcon = node('sweet-fbcon', {
        'reg': u64(FB, FB_SIZE),		# absolute physical address
        'width': u32(FB_W),
        'height': u32(FB_H),
        'stride': u32(FB_STRIDE),
    })

    # pmap_compute_max_asids() needs /defaults to exist.
    defaults = node('defaults')

    root_props = {
        'compatible': strs('google,blueline', 'xiaomi,sweet', 'qcom,sdm845', 'AppleARM'),
        'model': strs('Pixel3,1'),
        'manufacturer': strs('Google'),
    }
    extra = []
    if iphone:
        # compatible[0] -> hw.model/hw.target, model -> hw.machine/hw.product.
        # "xiaomi,sweet" stays: ios-sweet's platform expert matches it.
        root_props = {
            'compatible': strs('D22AP', 'iPhone10,3', 'google,blueline', 'xiaomi,sweet',
                               'qcom,sdm845', 'AppleARM'),
            'model': strs('iPhone10,3'),
            'target-type': strs('D22'),
            'target-sub-type': strs('D22AP'),
            'manufacturer': strs('Apple Inc.'),
        }
        for k, v in {
            # /sbin/mount -P 1 wants the boot manifest hash; cryptexd wants
            # the hash method (stand-in values, as a dev board would have).
            'boot-manifest-hash': hashlib.sha384(b'pixel3 boot manifest').digest(),
            'crypto-hash-method': strs('sha2-384'),
            # MobileGestalt: screen scale; IOPlatformUUID comes from these two.
            'display-scale': u32(3),
            'unique-chip-id': struct.pack('<Q', ECID),
            'chip-id': u32(CHIP_ID),
            # Security status of a dev-fused board: mobileactivationd then
            # takes its local "Hactivation" path (no Apple servers).
            'certificate-production-status': u32(0),
            'effective-production-status-ap': u32(0),
            'certificate-security-mode': u32(1),
            'effective-security-mode-sep': u32(1),
        }.items():
            chosen.set(k, v)
        # keybagd: no effaceable storage -> plain-plist system keybag.
        defaults.set('no-effaceable-storage', u32(1))
        # watchdogd: no PMU to report boot stages to.
        arm_io.children.append(node('wdt', {'no-pmu': u32(1)}))
        # IOMobileFramebuffer counts these; canvas = what iOS draws: the
        # iPhone X panel, which the kernel (patch 0061) presents and crops
        # to the 1080x2160 Pixel panel.
        arm_io.children.append(node('disp0', {
            'device_type': strs('display-subsystem'),
            'compatible': strs('sweet,display'),
            'canvas-width': u32(1125),
            'canvas-height': u32(2436),
        }))
        # MobileGestalt HomeButtonType 2: no Home button (gesture UI).
        extra.append(node('buttons', {
            'button-names': strs('volup', 'voldown', 'hold'),
            'home-button-type': u32(2),
            'opposed-power-vol-buttons': u32(1),
        }))
        product = node('product')
        for k, v in d22ap_product(iphone):
            product.set(k, v)
        # The panel shows sRGB, and with "P3" CoreAnimation draws wide-colour
        # layers and snapshots into 'b3a8' surfaces (10-bit colour plus an
        # alpha plane) that the GPU path can't draw into: the wallpaper
        # blurs (App Library, Control Center) came out black.
        product.set('artwork-display-gamut', b'sRGB\0')
        extra.append(product)

    storage = []
    if ufs:
        storage.append(node('sweet-ufs', {
            'compatible': strs('qcom,ufshc'),
            'reg': u64(UFS, UFS_SIZE),		# absolute physical address
        }))

    if gpu_fw is not None:
        # Read by bsd/dev/blueline_gpu.c: the GMU image (0126) at bluegpu=3+,
        # the SQE microcode (0137) at bluegpu=6.
        gpu = {'gmu-firmware': gpu_fw}
        if sqe_fw is not None:
            gpu['sqe-firmware'] = sqe_fw
        if zap_fw is not None:
            gpu['zap-elf'] = zap_fw		# 0144, bluegpu=7
        extra.append(node('blueline-gpu', gpu))

    if wlan_fw is not None:
        # Read by bsd/dev/blueline_wifi.c (0167): served to the modem's WLAN PD over TFTP, and the board file.
        extra.append(node('blueline-wlan', {'wlanmdsp': wlan_fw[0], 'bdwlan': wlan_fw[1]}))

    if haptic_fw is not None:
        # Read by bsd/dev/blueline_haptic.c (0150) at bluehaptic=2.
        extra.append(node('blueline-haptic', {'wmfw': haptic_fw[0], 'wavetable': haptic_fw[1]}))

    root_props.update({'#address-cells': u32(2), '#size-cells': u32(2)})
    return node('device-tree', root_props, [chosen, defaults, cpus_node, arm_io, fbcon] + extra + storage)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='Pixel 3 Apple Device Tree generator')
    ap.add_argument('out')
    ap.add_argument('--qemu', action='store_true', help="QEMU virt's GIC and timer")
    ap.add_argument('--cpus', type=int, default=1, help='CPU nodes (default 1)')
    ap.add_argument('--ufs', action='store_true', help='add the UFS host (root on userdata)')
    ap.add_argument('--iphone', metavar='DT.im4p', help='iPhone X identity, /product from this tree')
    ap.add_argument('--gpu-fw', metavar='a630_gmu.bin',
                    help='add /blueline-gpu "gmu-firmware" (tools/fetch-gpu-fw.sh)')
    ap.add_argument('--gpu-sqe', default='auto', metavar='auto|vendor|linux|none|PATH',
                    help='with --gpu-fw: the "sqe-firmware" to add (default auto: vendor/ copy, else linux-firmware)')
    ap.add_argument('--gpu-zap', default='auto', metavar='auto|none|PATH.mdt',
                    help='with --gpu-fw: the "zap-elf" to add (default auto: DIR/vendor/a630_zap.mdt + .bNN)')
    ap.add_argument('--wlan-fw', metavar='DIR',
                    help='add /blueline-wlan: DIR/wlanmdsp.mbn and DIR/bdwlan-blueline.bin (from vendor /firmware)')
    ap.add_argument('--haptic-fw', metavar='DIR',
                    help='add /blueline-haptic "wmfw" + "wavetable" from DIR/cs40l20.wmfw, cs40l20.bin')
    ap.add_argument('--dump', action='store_true')
    a = ap.parse_args()
    if not 1 <= a.cpus <= 8 or (a.qemu and a.cpus != 1):
        sys.exit('--cpus: 1..8 on the phone, 1 in QEMU')
    if a.qemu and a.ufs:
        sys.exit('--ufs: QEMU virt has no UFS host')
    if a.qemu and a.gpu_fw:
        sys.exit('--gpu-fw: QEMU virt has no Adreno')
    gpu_fw = gmu_firmware(a.gpu_fw) if a.gpu_fw else None
    sqe_fw, sqe_why = sqe_firmware(a.gpu_sqe, a.gpu_fw) if a.gpu_fw else (None, None)
    zap_fw, zap_why = zap_firmware(a.gpu_zap, a.gpu_fw) if a.gpu_fw else (None, None)
    haptic_fw = haptic_firmware(a.haptic_fw) if a.haptic_fw else None
    wlan_fw = wlan_firmware(a.wlan_fw) if a.wlan_fw else None
    root = build(a.qemu, a.cpus, ufs=a.ufs, iphone=a.iphone, gpu_fw=gpu_fw, sqe_fw=sqe_fw, zap_fw=zap_fw,
                 haptic_fw=haptic_fw, wlan_fw=wlan_fw)
    blob = serialize(root)
    open(a.out, 'wb').write(blob)
    if a.dump:
        dump(root)
    print('%s: %d bytes' % (a.out, len(blob)), file=sys.stderr)
    if wlan_fw is not None:
        print('  /blueline-wlan wlanmdsp %d bytes, bdwlan %d bytes' % (len(wlan_fw[0]), len(wlan_fw[1])), file=sys.stderr)
    if haptic_fw is not None:
        print('  /blueline-haptic wmfw %d bytes, wavetable %d bytes' % (len(haptic_fw[0]), len(haptic_fw[1])),
              file=sys.stderr)
    if gpu_fw is not None:
        print('  /blueline-gpu gmu-firmware: %d bytes, word sum %#x'
              % (len(gpu_fw), sum(struct.unpack('<%dI' % (len(gpu_fw) // 4), gpu_fw)) & 0xffffffff),
              file=sys.stderr)
        if sqe_fw is not None:
            print('  /blueline-gpu sqe-firmware: %d bytes, word sum %#x: %s'
                  % (len(sqe_fw), sum(struct.unpack('<%dI' % (len(sqe_fw) // 4), sqe_fw)) & 0xffffffff, sqe_why),
                  file=sys.stderr)
        else:
            print('  /blueline-gpu sqe-firmware: %s' % sqe_why, file=sys.stderr)
        if zap_fw is not None:
            print('  /blueline-gpu zap-elf: %d bytes, word sum %#x: %s'
                  % (len(zap_fw), sum(struct.unpack('<%dI' % (len(zap_fw) // 4), zap_fw[:len(zap_fw) // 4 * 4]))
                     & 0xffffffff, zap_why), file=sys.stderr)
        else:
            print('  /blueline-gpu zap-elf: %s' % zap_why, file=sys.stderr)
