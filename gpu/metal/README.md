# metal: Metal on the Adreno 630 (stage 1)

Route: Metal frontend (AdrenoMetal, MIT, to be adapted to iOS 16), then metal2vulkan (translates
AIR to SPIR-V), then Turnip (`gpu/mesa-ios`, `VK=1`, out/bluevk.dylib), then bluedrm, then BlueGPU.
Nothing here runs on the phone yet.

| File | What |
|---|---|
| `turnip-a630.json` | metal2vulkan device profile (Khronos profiles 0.8, `VP_M2V_turnip-a630`) of our Turnip on the A630 |
| `turnip-a630-vulkaninfo.json`, `turnip-a630-formats.json` | its sources: `vulkaninfo --json` and `corpus-vulkan --capture-formats` |
| `m2v-regen-turnip-a630.patch` | the `SOURCES` entry for metal2vulkan's `scripts/regen-device-profiles` (metal2vulkan 0d4d572, GPL-2.0-or-later) |
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
