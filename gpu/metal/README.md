# metal: Metal on the Adreno 630 (stage 1)

Route: Metal frontend (UniXNU's AdrenoMetal, MIT), then the metal2vulkan runtime (translates AIR to
SPIR-V and runs it), then Turnip (`gpu/mesa-ios`, `VK=1`, out/bluevk.dylib), then bluedrm, then BlueGPU.
Metal reaches it through its plugin discovery: the kernel's IOAcceleratorES carries `MetalPluginName`
`BlueMetal` and `MetalPluginClassName` `BlueMetalDevice` (xnu patch 0215), and `plugin/BlueMetal.m` answers
the frontend's device to processes that opt in (`BLUE_METAL=1`, or the process name on a line of
`/usr/local/etc/bluemetal.procs`) and nil to the rest. `BLUE_METAL_LOG=1` logs the frontend's problems, and its
status every 5 s. One boot of backboardd on Metal: `sweetenv=backboardd:BLUE_METAL=1,BLUE_METAL_LOG=1` (replaces the GL shim's sweetenv).
Translated QuartzCore pipelines are also drawn straight through Vulkan by `gpu/mesa-ios/test/vk-draw.c`.

| File | What |
|---|---|
| `turnip-a630.json` | metal2vulkan device profile (Khronos profiles 0.8, `VP_M2V_turnip-a630`) of our Turnip on the A630 |
| `turnip-a630-vulkaninfo.json`, `turnip-a630-formats.json` | its sources: `vulkaninfo --json` and `corpus-vulkan --capture-formats` |
| `m2v-regen-turnip-a630.patch` | the `SOURCES` entry for metal2vulkan's `scripts/regen-device-profiles` (metal2vulkan 0d4d572, GPL-2.0-or-later) |
| `qc-spv.sh` | translates the QuartzCore pipelines the tests draw, from the mounted iOS root, into `out/qc` (not in git: derived from Apple's shaders) |
| `build-metal.sh` | builds into `out/`, from `work/ref/UniXNU`: `bluemetal.dylib` (frontend + metal2vulkan runtime), `BlueMetal.bundle`, `mtl-draw`, `mtl-sys`, `tri.metallib` |
| `test/ca-draw.m` | `CARenderer` renders a layer tree into a texture of `MTLCreateSystemDefaultDevice`'s device (CoreAnimation's Metal compositor); `-dump` logs its command buffers; `-iosurface` renders into an IOSurface and reads its pages (needs Mesa 0008, `VK_EXT_external_memory_host`); `-bench [frames]` times command buffers (encode, commit, scheduled, completed, GPU time) and CA frames at 256x256 and 1125x2250 (private and IOSurface); `-matrix` repeats the bench under each `TU_DEBUG` mode. Built for the Mac too as the reference; `-text`, `-a8` and `-rgba` print a CATextLayer and gray/BGRA images at odd row pitches as text art with a hash, to compare with the Mac |
| `plugin/` | `BlueMetal.bundle`: Metal's plugin (`/System/Library/Extensions`), loads `/usr/lib/bluemetal.dylib` for apps (an `.app`'s executable, not extensions) and `com.apple.WebKit.GPU`, or processes named in `/usr/local/etc/bluemetal.procs` (`-NAME` refuses) or with `BLUE_METAL=1` |
| `test/mtl-draw.mm` | opens the frontend's `MTLDevice` over `bluevk.dylib` and draws QuartzCore's stroke_line through the Metal API; `MTL_DRAW_TRI=tri.metallib`: one full-screen triangle (`test/tri.metal`). Built with `-DMTL_DRAW_SYSTEM` as `mtl-sys`: the device from `MTLCreateSystemDefaultDevice`, after printing each discovery step |
| `patches/m2v-0001-*` | metal2vulkan runtime: `read_pages` fallback on iOS |
| `patches/am-0001-*` | AdrenoMetal frontend: accept iOS 16's `_MTLDevice` (528 bytes; held to iPadOS 17's 536) |
| `patches/am-0002-*` | Debug: `NATIVE_METAL_ART=1` prints one-byte textures over buffers as text art of their bytes, and textures at rows off 64 bytes |
| `patches/am-0003-*` | Debug: `NATIVE_METAL_STAGES=1` prints each render commit's stage times (encoding thread, runtime commit, scheduling, GPU) and per-call encode times; `NATIVE_METAL_SAMPLE=1` samples the encoding thread's stack |
| `patches/am-0004-*` | Linear texture alignment of 64 bytes (A6xx pitch): CoreAnimation's images in buffers import without shadow copies (`NATIVE_METAL_LINEAR16=1`: 16) |
| `patches/am-0005-*` | `presentDrawable:` presents once the command buffer is scheduled, as Metal does, not after completion (`NATIVE_METAL_PRESENT_COMPLETED=1`: after). Needed with the DPU's second layer: presenting at completion added about a frame to each drawable's round trip, SpriteKit 40.5 -> 60.6 fps steady (sk22, sk23) |
| `m2vbatch.py` | translates every function of a metallib: `M2V_PROFILE=turnip-a630 python3 m2vbatch.py SCRATCH LIB TAG` |

The captures come from the Mac: the host build of the same Turnip (`VK=1 HOST=1`) over the fake BlueGPU,
loaded by the Vulkan loader through an ICD manifest (`VK_DRIVER_FILES`). The chip ID is the A630's
and the driver build is the one the phone runs, so the capabilities match the phone's. Recapture
after any change to Turnip or patch 0006:

```sh
echo '{"file_format_version":"1.0.1","ICD":{"library_path":"'$PWD'/gpu/mesa-ios/out/host/bluevk.dylib","api_version":"1.3.363"}}' > /tmp/bluevk_icd.json
VK_DRIVER_FILES=/tmp/bluevk_icd.json vulkaninfo --json
VK_DRIVER_FILES=/tmp/bluevk_icd.json corpus-vulkan --capture-formats formats.json --device-type gpu
# in metal2vulkan, with the patch applied (bump its sha256 fields):
python3 scripts/regen-device-profiles/regen_device_profiles.py --only turnip-a630 \
    --capture 'turnip-a630=VP_VULKANINFO_Turnip_Adreno_(TM)_630_26_3_1.json' --formats turnip-a630=formats.json
```

## Translation of the iOS 16.7 system metallibs (2026-11-24)

| Library | Functions | lavapipe | turnip-a630 |
|---|---|---|---|
| QuartzCore | 102 | 98 | 96 |
| RenderBox | 29 | 29 | 29 |
| CoreImage | 58 | 58 | 58 |

The failures on the A630:

- `tile_downsample_{1,2,4,8}`: `IdentityDomains` (a resource bound through a descriptor), not implemented in metal2vulkan.
- `inplace_copy_lpf` and `inplace_copy_lph`: raster order groups, which need
  `fragmentShaderPixelInterlock`. Turnip doesn't offer it on the A630.

"Translated" means a `.spv` was written. These are not drawn yet.

## mtl-draw: Metal on the phone (2026-11-24)

```sh
gpu/metal/build-metal.sh          # or --reuse-bridge after the first build (the bridge takes ~8 min)
tools/phonetest.sh --name mtl --push gpu/metal/out/mtl-draw:/usr/local/bin/mtl-draw:755 --run /usr/local/bin/mtl-draw
# through Metal's discovery (kernel with 0215):
O=gpu/metal/out E=/System/Library/Extensions/BlueMetal.bundle
tools/phonetest.sh --name msys --mkdir $E:755 --push $O/BlueMetal.bundle/Info.plist:$E/Info.plist:644 \
    --push $O/BlueMetal.bundle/BlueMetal:$E/BlueMetal:755 --push $O/bluemetal.dylib:/usr/lib/bluemetal.dylib:755 \
    --push $O/mtl-sys:/usr/local/bin/mtl-sys:755 --run /usr/local/bin/mtl-sys
```

Turnip must export `vkGetInstanceProcAddr` (the runtime opens the "loader" with `ash::Entry::load_from`):
`gpu/mesa-ios/patches/0007`. The same program builds for macOS against the bridge's `--target host`
build and runs over MoltenVK, for debugging in seconds instead of a phone boot:

```sh
mtl-draw-mac /opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib /Volumes/*D22D221OS/System/Library/Frameworks/QuartzCore.framework/default.metallib
```

`NATIVE_METAL_DUMP_CB=1:1 NATIVE_METAL_DUMP_LOG=1` logs the first command buffer's passes, draws and bound data.
