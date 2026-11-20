# Audio drafts (not built)

Next stages of the speaker work, written but not yet wired into
`bsd/dev/blueline_audio.c` or run on the phone. Patches 0185 (amp probe) and
0186 (ADSP boot) are the tested part.

- `cs35l36_seq.c`: CS35L36 boot, errata, config (TDM slot, PLL from the bit
  clock, boost), power up/down, status dump and protection release. Needs
  `amp_rd`/`amp_wr`/`amp_upd` and two fields in `struct amp` (`rev`, `l37`).
  The 0x40 amp is stock's "R AMP" on TDM slot 1; 0x41 is "AMP" on slot 0.
- `blueline_audio_apr.c/.h`: the SDM845 APR commands (AVCS state, AFE QUAT
  TDM clock/config/start, ASM shared memory + open/write, ADM open + matrix
  map) over a 20-byte APR header. Needs a GLINK "apr_audio_svc" transport
  (`apr_tx`) and an ADSP-visible buffer (`bsnd_shm_*`; the ADSP sees it
  through its SMMU stream 0x1821).

Order to play a tone: GLINK lpass edge + APR channel, AFE TDM start, then
`amp_power(1)` (its PLL locks to the running bit clock), then ASM writes.
Keep the volume low: there is no speaker protection without ACDB data.

Both drafts are written from scratch; Linux's GPL drivers (mainline and the
Pixel 3's msm-extra) were used only as a description of the hardware and
the DSP's message formats.
