# Roadmap (2026-11-27)

The areas not yet working, with the cheapest known route for each. Estimates assume the 1-3 min automated
boot test. These are plans, not results: the tracker and LOG.md record only what was shown.

| Area | Feasibility | Route | Effort |
|---|---|---|---|
| Camera | in progress | `/dev/blueline-camera` (0233) streams 30 fps; sensor frames reach apps (cam35); stock Camera app shows a live preview (cam40, 0247) and saves 4032x3024 HEIC photos (cam41: software HEVC encoder registered, single-frame stills); Photos lists them with a correct key image (highest bank bit 14, cam45); the viewfinder moves (surface seed bumped after GPU writes, am-0010; it looped 8 frames before). live with the real sensor (mem1). Next: grid thumbnails, focus, video encode | hours |
| Thermals to thermalmonitord | done (default on) | 0235 + 0237 board thermistors + 0245: on by default, thermalmonitord's job kept; therm9/10: nominal pressure at idle; therm11: pressure 30 (critical) under 8-thread load, LMh holds the die at 56-69 C. Left: calibration (critical at 43 C board), pressure falling after load | - |
| Wi-Fi 5 GHz | needs a reference | ruled out: second rail (stock DT has ch0 only), board data, regulatory (firmware allows ch 36), ath10k pdev params (0236). Next: WMI trace from Android/Linux on this phone to diff; radio in the default boot | 1-2 days |
| Cellular control, SMS | deferred (2026-11-27) | 0238-0240 (`bluecell=1`): ABM boots the modem (cell4), CommCenter talks QMI to it (UIM, NAS, WDS, DMS); card status reads "SIM absent". Next: SIM detected, NAS registration, SMS | 2-4 days |
| Mobile data | more work | IPA v3.5.1 + GSI (Linux `drivers/net/ipa` has SDM845) | +4-6 days |
| Bluetooth | realistic | WCN3990 on a GENI UART (FIFO mode), init as Linux `btqca.c` / `hci_qca.c` (GPL: reimplement or keep in userland). UniXNU/QcaBluetooth (fa52814) is WCN7850 on iPadOS 27 with Linux code in its kernel and a patched bluetoothd; reusable as design (UART.SK pipe, BlueTool XPC stand-in, Type0 capabilities), not as code; iOS 16 bluetoothd transport still to check | 2-4 days |
| Sensors / CoreMotion | heaviest | iOS side known (0135 HID usages); hardware behind the SLPI: boot it (0186 loader), FastRPC sensor registry (never write persist), QMI sensor client | ~1 week |
| Auto-brightness | after sensors | ALS over the same SLPI stream to HID (0xff00/4) | +0.5 day |
| Microphone | hard-ish | SLIMbus NGD + WCD934x + AFE TX port, input stream in the audio HAL | 3-5 days |
| Video decode | check first | iOS ships `H264SW.videocodec`; write a decode test like VTHello | 0.5 day |
| Video encode | software realistic | OpenH264 as a VideoToolbox encoder; Venus driver 1-2 weeks | 1-2 days |
| GPS | after QMI | modem GNSS over QMI LOC | 2-4 days |
| Suspend / battery | hard | every subsystem must vote down so the AOP sleeps (floor 200 mA vs 176 mA recovery) | days-week |
| Calls, hotspot | hard | need mic + ADSP voice; data + AP mode | weeks |
| Passcode | works (`bluepasscode=1`) | 0246: set, lock at display off, keypad, unlock (passcode7). Left: keep it across reboots (keybag on disk), default on | 0.5 day |
| Face ID, Apple Pay, NFC, USB host | not worth it | no Secure Enclave / TrueDepth | - |

Also: memory pressure is normal with Camera open since 0248 (XNU 3.3 GiB, was 2.2 GiB; warning before), but
Photos' thumbnail job still does not run; overnight soak (wired memory, BO pool, daemon restarts); battery shows charging after unplug; app
reinstall does not work.

## Order

1. Overnight soak (the L23A test is moot: stock DT has one 3.3 V rail).
2. Camera sensor frames in apps, then Photos.
3. Thermals.
4. 5 GHz, radio in the default boot.
5. Cellular control plane.
6. Bluetooth.
7. Sensors (after QRTR/FastRPC nodes, below).

## Tooling

- QRTR and FastRPC device nodes: run existing Linux userland daemons (hexagonrpcd, libssc, qmi tools) as
  processes and iterate without rebooting; GPL code stays out of the kernel.
- A Linux boot on this phone as reference: regulator/clock summaries, WMI/HCI/QMI traces to diff.
- A boot-arg that logs each process's `IOServiceMatching` dictionaries and missed property reads.
- Shared bases: HID sensor service, firmware loader (ADSP, SLPI, Venus), GENI serial engine.
- One default config and a smoke matrix (boot, Wi-Fi join, tone, app launch, Metal, camera) per push.

## Camera review notes (advisor review of 0233 and bluecam, 2026-11-26)

Done: handlers called without `st.lock`; pool capped (allocation threshold); RAW conversion through tables;
`dev_bad` reset on a clean frame; 0994 dropped (`ml_io_map_unmappable` maps from `kernel_map`); WM0 address
check logs a done the model missed.

Open:
- Keep the cacheable ring read-only to the CPU: a kernel write would need a clean before the buffer is queued.
- Missed buf-done: if the address check fires, pop `round(gap / period)` queue entries (or follow WM0's address).
- One reader only: `dev_given` is global and the node is 0666; a second opener takes frames.
- camdev10/11 checked only header sequence: dump one frame (PGM) with the lens uncovered and a moving object
  to prove the ring and cache path.
- Time the copy alone (camtest sleeping 40 ms between reads); 32 ms a read may be the frame wait.
- Formats: the source has 1008x756 cells; offer 1280x720 / 640x480 rather than 1080p-12 MP, or the CPU
  conversion will not keep 30 fps.
- `ExposureTime` metadata should be `exposure_lines * line_ns`.
- EIO ends the frame thread with `st.running` still set and no fallback.
- If frames stop after the first: next suspects are the preview sink and a 420f to BGRA transfer wanting a
  hardware scaler. CamHello switches for no preview layer, 420f, smallest preset.
- Keep the debayer in userland on the CPU; NEON or an mmap of the ring only if profiling asks for it.
