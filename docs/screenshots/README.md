# Screenshots

Taken on the phone by `bluesnap` (the kernel reads the frame the display is
showing; 540x1080, half the panel's resolution, RGB565). Newest first.

| File | What |
|---|---|
| 2026-11-19-gpu-safari.png | Safari's start page on the GPU path (kernel flip thread, 0160) |
| 2026-11-19-gpu-home.png | Home screen, drawn by the Adreno 630 (CoreAnimation over Mesa freedreno, `blueui=1`), zero-copy flip |
| 2026-11-19-gpu-settings.png | Settings opened by a scripted tap |
| 2026-11-19-gpu-settings-scrolled.png | Settings scrolled (blurred nav bar) |
| 2026-11-19-gpu-settings-subpage.png | A Settings sub-page |
| 2026-11-20-home-wallpaper.png | Home screen after the first-boot migration: the wallpaper (PosterBoard) and widgets |
| 2026-11-20-system-apps.png | Second home page: the removable stock apps the migration installed (0164) |
| 2026-11-20-control-center.png | Control Center with its blurs and clean glyphs (sRGB gamut, 0169 exact rows) |
| 2026-11-20-full-width-status-bar.png | Home screen filling the whole panel (1125x2250 scaled by 0.96, 0184) with iOS's own status bar (Jindo off) and Wi-Fi joined by itself after boot (0183) |
| 2026-11-20-full-width-apps.png | Second home page (the stock apps) at the full-width canvas |
| 2026-11-20-full-width-settings.png | Settings at the full-width canvas, with the status bar |
| 2026-11-20-wifi-safari-google.png | Safari loading google.com over Wi-Fi |
| 2026-11-21-lock.png | Lock screen at the full-width canvas, after a lock/wake cycle with the panel asleep (`bluefb_dcs=2`) |
| 2026-11-21-home1.png | Home screen, settled, full width |
| 2026-11-21-home2.png | Second home page (stock apps), full width |
| 2026-11-21-control-center.png | Control Center, drawn by the GPU in place into the display buffer (val1) |
| 2026-11-21-settings.png | Settings scrolled past the Wi-Fi row |
| 2026-11-21-safari.png | Safari on apple.com over Wi-Fi |
| 2026-11-27-passcode-keypad.png | Lock screen keypad after swipe up with a passcode set (0246, `bluepasscode=1`) |
| 2026-11-27-camera-app.png | Stock Camera app on sensor frames (cam37); preview still one flat colour |
| 2026-11-27-camera-preview.png | Stock Camera app live preview from the rear IMX363 (cam40, 0247); unfocused |
