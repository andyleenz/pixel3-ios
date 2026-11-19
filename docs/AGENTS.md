# Brief for drafting agents

Read this first; it replaces the groundwork every draft used to redo.

## Where things are
- Repo worktree: this checkout (branch `display-usb`). Our XNU changes: `xnu/patches/NNNN-*.patch`, applied in number order.
- Patched, built tree: `work/kbuild/dxb/xnu` (the list of applied patches: `work/kbuild/patch-list.txt`; their applied copies: `work/kbuild/dxb/patches/`). Never edit or build in it.
- Drafts and plans live outside the repo in `../pixel3-ios-gpu/` (`*-plan.md`, `ref/` = Linux, crosshatch, Mesa, HackiOS sources).
- The hardware test loop: `docs/TESTING.md`. Drafting agents never run it.
- Progress log: `../pixel3-ios/docs/LOG.md` (branch `linux-host`).

## Checking a draft patch (one command)
```
tools/patch-check.sh ../pixel3-ios-gpu/NNNN-name.patch            # new patch on top of the current tree
tools/patch-check.sh --replace NNNN-old.patch ../pixel3-ios-gpu/NNNN-v2.patch   # a new version of an applied patch
```
It clones the built tree, applies the draft (and re-applies later patches on top when replacing), and compiles every touched .c/.cpp with the build's exact clang line plus `-fsyntax-only`. Nothing is written into `work/kbuild`. Never run clang against the real tree yourself: stray `.d` files in `work/kbuild/dxb/build` have broken the real build before.

## Rules
- Draft only: no phone access, no commits, no pushes, no edits under `work/kbuild`.
- Patch numbers: take the next number not used in `xnu/patches/` or `../pixel3-ios-gpu/`; the prompt may assign one.
- Everything new is off unless its boot-arg turns it on; log a line before the first access to any new hardware block (if it hangs, the last line names it).
- Never write to persist, modemst1/2, fsg, fsc, EFS or anything holding the IMEI; never touch EDL/dload cookies. Phone writes go only to userdata.
- Firmware blobs, Apple binaries and IPSW content stay out of git (`work/` is ignored).
- Code from other ports: copy only MIT/compatible code with attribution; ios-sailfish (no licence) and Linux GPL drivers are references only.
- Keep hooks into shared files (`SweetFramebuffer.cpp`, `blueline_gpu.c`) small and put new code in new files, so parallel drafts don't collide.

## Key facts
- SoC SDM845; XNU RAM from 0xf4000000; panel buffer 0x9d400000, 1080x2160, stride 4320; iOS surfaces 1125x2436, stride 4608.
- GPU: Adreno 630, SMMU at 0x5040000 (cb0 GPU, cb1 GMU); patches 0125-0128, 0136-0138, 0144 (zap), 0147 (resident GPU, presents by 2D blit).
- SMC/SCM helper: `bsd/dev/blueline_scm.c` (0143). Bit-banged I2C: `blueline_touch.c` (0113).
- Screenshots and scripted touches for tests: `bluesnap=`, `bluetouchscript=` (0146). Watchdog on by default (0148).

## Report back
What was found (with sources), the files, boot-args, expected log lines, the first test command, risks, and an honest estimate in hours.
