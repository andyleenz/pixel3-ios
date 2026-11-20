/*
 * CS35L36 bring-up sequence for blueline_audio.c (drop-in functions).
 *
 * Written from scratch. Two GPL drivers were used only as a description of
 * the chip (register addresses, field positions, values, order, delays):
 *   [PX] the Pixel 3's own production driver, the one that ran on these two
 *        amps: AOSP kernel/msm-extra, branch android-msm-crosshatch-4.9-
 *        android12, asoc/codecs/cs35l36.c, cs35l36.h, cs35l36-tables.c,
 *        include/sound/cs35l36.h (Cirrus Logic, 2017-2018);
 *   [ML] mainline Linux sound/soc/codecs/cs35l36.c / cs35l36.h (Cirrus, 2018);
 *   [MC] the Pixel 3 machine driver, msm-extra asoc/sdm845.c (DAI format,
 *        clocks, which amp carries the "R" control prefix);
 *   [DT] Documentation/devicetree/bindings/sound/cs35l36.txt.
 * The CS35L36 datasheet is not public (searched; [PX] quotes its section
 * "7.11.3 BST_IPK_CTL" once). Where [PX] and [ML] differ, [PX] wins: it is
 * what made sound on this phone.
 *
 * Which amp is which ([MC] spk_codec_right_ch_conf: dev "cs35l36.4-0040",
 * name_prefix "R"):
 *   0x41, top speaker ("portrait left" in the DT):     "AMP ...",   "Channel Mux" = RX1   -> TDM slot 0
 *   0x40, bottom speaker ("portrait right" in the DT): "R AMP ...", "R Channel Mux" = RX2 -> TDM slot 1
 * (mixer_paths_tavil_b1.xml defaults. Its "speaker-mono" path, bottom only,
 * enables "R AMP" alone; "handset", which uses the top speaker as the
 * earpiece, enables "AMP" alone. Both paths agree with this.)
 *
 * Sequence (the caller releases reset first):
 *   amp_boot     DEVID, revision, 10 V/12 V part, revision errata (A0 or B0)
 *   amp_config   boost, DT options, IRQ pin, TDM slave port, slot, PLL on SCLK,
 *                48 kHz, gain, volume. Clocks need not run yet (as on stock).
 *   [SoC: start QUAT TDM, SCLK 12.288 MHz + 48 kHz frame sync running]
 *   amp_power(a, 1)  the stock DAPM power-up, ends unmuted
 *   amp_power(a, 0)  mute, power down; then the SoC may stop the clocks
 *   amp_dump     status read-back; amp_recover releases a protection latch
 *
 * Add to struct amp:  uint32_t rev; uint8_t l37;
 * Needs amp_rd / amp_wr / amp_upd (32-bit big-endian, 0 = OK), IOSleep, printf.
 *
 * Registers used ([PX]/[ML] names; bit fields from their header):
 *   0x00000000 SW_RESET     reads the device ID, 0x035A36
 *   0x00000004 SW_REV       log only; no driver uses it (reads 0x06 on this phone)
 *   0x00000008 HW_REV       log only
 *   0x00000020 TESTKEY_CTRL 0x5555, 0xAAAA unlock; 0xCCCC, 0x3333 lock
 *   0x00000478 OTP_MEM30    bits 23:16 == 0xCC: CS35L37 (12 V) else CS35L36 (10 V)
 *   0x00000500/504 OTP_CTRL1/2   A0 errata (reruns the OTP boot, ECC off then on)
 *   0x00000C00 PAC_CTL1     bit 0 PAC enable (0 = reset)      } B0 one-word
 *   0x00000C08 PAC_CTL3     bit 0 PAC memory access           } PAC patch
 *   0x00E02800 PAC_PMEM_WORD0 <- 0x00DD0102                  }
 *   0x00002004 DEVICE_ID    log only;  0x0000200C REV_ID: >> 8 = 0xA0 or 0xB0
 *   0x00002014 PWR_CTRL1    bit 0 GLOBAL_EN
 *   0x00002018 PWR_CTRL2    bit 0 AMP_EN; bits 5:4 BST_EN (2 boost on, 1 bypass: VBST = VP)
 *   0x0000201C PWR_CTRL3    bit 4 class H
 *   0x00002020 CTRL_OVRRIDE bit 1 SYNC_GLOBAL_OVR, must be 0 (A0 and B0)
 *   0x00002024 AMP_OUT_MUTE bit 4 AMP_MUTE ("AMP Enable Switch" = 1 means bit 4 = 0)
 *   0x00002034 PROTECT_REL_ERR  bits 1-6: protection release pulses
 *   0x00002400 PAD_INTERFACE bit 0 INT out enable, 1 INT/GPIO pin select,
 *              2 polarity (0 = active low), 3 IRQ source select (A0 only), 5 drive (0 = open drain)
 *   0x00002C04 PLL_CLK_CTRL bits 2:0 source (0 = SCLK), 4 REFCLK_EN, 10:5 REFCLK_FREQ, 11 OPENLOOP
 *   0x00002C0C GLOBAL_CLK_CTRL bits 4:0 GLOBAL_FS (0x03 = 48 kHz)
 *   0x00002D10 TST_FS_MON0  sample-rate monitor windows (see AMP_SET_FS_MON)
 *   0x00003008 PLL_LOOP_PARAMS, 0x00003010 DCO_CTRL, 0x00003014 MISC_CTRL: A0 PLL fixes
 *   0x00003800 BSTCVRT_VCTRL1 bits 7:0 boost target (0x96 = 10 V)
 *   0x00003804 BSTCVRT_VCTRL2 bits 1:0 target source (1 = class-H tracking), bit 2 limit to VCTRL1
 *   0x00003808 BSTCVRT_PEAK_CUR bits 6:0 (0x10 = 1.60 A, +50 mA per step)
 *   0x00003810 BSTCVRT_COEFF K1 bits 7:0, K2 bits 15:8
 *   0x00003814 BSTCVRT_SLOPE_LBST slope bits 15:8, inductor bits 1:0 (0 = 1 uH)
 *   0x00003818 BSTCVRT_SW_FREQ bits 3:0 CCM frequency
 *   0x00003830 BSTCVRT_OVERVOLT_CTRL bits 5:0 OVP threshold (0x10 = 11 V)
 *   0x0000394C BST_ANA2_TEST bits 18:15 OVP trim (0x0C = 11 V; test key)
 *   0x00004220 DTEMP_WARN_THLD bits 1:0 (1 = 115 C)
 *   0x00004300 DTEMP_STATUS, 0x0000640C VPBR_STATUS, 0x00006410 VBBR_STATUS: dump only
 *   0x00004800 ASP_TX_PIN_CTRL bit 6 SCLK master, 7 SCLK force, 8 SCLK invert, 21 TX Hi-Z
 *   0x00004804 ASP_RATE_CTRL bit 0 LRCLK master, 1 force, 2 invert
 *   0x00004808 ASP_FORMAT  bits 2:0 (0 = DSP mode A / TDM, 2 = I2S)
 *   0x00004818 ASP_FRAME_CTRL RX width bits 23:16, TX width bits 7:0 (0x20 = 32)
 *   0x0000482C ASP_RX1_SLOT bits 5:0
 *   0x0000483C ASP_RX_TX_EN bit 16 RX1 enable (bits 0-5: TX1-6, feedback, left off)
 *   0x00004C00 ASP_RX1_SEL  bits 6:0 DAC source (0x08 = ASP RX1, 0 = zeros)
 *   0x00006000 AMP_DIG_VOL_CTRL bits 13:3 volume (signed, 0.125 dB steps, 0 = 0 dB),
 *              2:0 soft ramp, 14 invert
 *   0x00006808 NG_CFG      bits 13:8 NG_AMP_EN (ldm-mode-select)
 *   0x00006C04 AMP_GAIN_CTRL bits 9:5 PCM gain ("AMP PCM Gain"), bit 10 zero-cross
 *   0x00007400 DAC_MSM_CFG bit 0 PDM mode, 3 LDM enter ramp, 4 LDM exit ramp
 *   0x00D00000-0C INT1-4_STATUS (write 1 to clear), 0x00D00020-2C raw, 0x00D00040/48 masks
 *   0x00D00218 PAC_INT_FLUSH_CTRL, 0x00D00220-3C PAC_INT0-7_CTRL (A0 errata)
 *   errata-only, undocumented: A0 0x2088 0x6E08 0x6454 0x7064 0x7E14 0x7E34 0x7410
 *   0x7418 0x410C; B0 0x7064 0x7848-0x7868 0x3854 0x7418 0x394C.
 */

#define R_SW_RESET		0x00000000u	/* reads DEVID */
#define R_SW_REV		0x00000004u
#define R_HW_REV		0x00000008u
#define R_TESTKEY		0x00000020u
#define R_OTP_MEM30		0x00000478u
#define R_OTP_CTRL1		0x00000500u
#define R_OTP_CTRL2		0x00000504u
#define R_PAC_CTL1		0x00000c00u
#define R_PAC_CTL3		0x00000c08u
#define R_DEVICE_ID		0x00002004u
#define R_REV_ID		0x0000200cu
#define R_PWR_CTRL1		0x00002014u
#define R_PWR_CTRL2		0x00002018u
#define R_PWR_CTRL3		0x0000201cu
#define R_CTRL_OVRRIDE		0x00002020u
#define R_AMP_OUT_MUTE		0x00002024u
#define R_PROTECT_REL_ERR	0x00002034u
#define R_PAD_INTERFACE		0x00002400u
#define R_PLL_CLK_CTRL		0x00002c04u
#define R_GLOBAL_CLK_CTRL	0x00002c0cu
#define R_TST_FS_MON0		0x00002d10u
#define R_PLL_LOOP_PARAMS	0x00003008u
#define R_DCO_CTRL		0x00003010u
#define R_MISC_CTRL		0x00003014u
#define R_BST_VCTRL1		0x00003800u
#define R_BST_VCTRL2		0x00003804u
#define R_BST_PEAK_CUR		0x00003808u
#define R_BST_COEFF		0x00003810u
#define R_BST_SLOPE_LBST	0x00003814u
#define R_BST_SW_FREQ		0x00003818u
#define R_BST_OVERVOLT		0x00003830u
#define R_BST_ANA2_TEST		0x0000394cu
#define R_DTEMP_WARN_THLD	0x00004220u
#define R_DTEMP_STATUS		0x00004300u
#define R_ASP_TX_PIN_CTRL	0x00004800u
#define R_ASP_RATE_CTRL		0x00004804u
#define R_ASP_FORMAT		0x00004808u
#define R_ASP_FRAME_CTRL	0x00004818u
#define R_ASP_RX1_SLOT		0x0000482cu
#define R_ASP_RX_TX_EN		0x0000483cu
#define R_ASP_RX1_SEL		0x00004c00u
#define R_AMP_DIG_VOL		0x00006000u
#define R_VPBR_STATUS		0x0000640cu
#define R_VBBR_STATUS		0x00006410u
#define R_NG_CFG		0x00006808u
#define R_AMP_GAIN_CTRL		0x00006c04u
#define R_DAC_MSM_CFG		0x00007400u
#define R_INT1_STATUS		0x00d00000u	/* INT2..4 follow at +4 */
#define R_INT1_RAW		0x00d00020u
#define R_INT1_MASK		0x00d00040u
#define R_INT3_MASK		0x00d00048u
#define R_INT4_STATUS		0x00d0000cu
#define R_INT4_RAW		0x00d0002cu
#define R_PAC_INT_FLUSH		0x00d00218u
#define R_PAC_INT0_CTRL		0x00d00220u	/* INT1..7 follow at +4 */
#define R_PAC_PMEM0		0x00e02800u

#define DEVID_L36		0x035a36u
#define REV_A0			0xa0u
#define REV_B0			0xb0u

/* INT1 (+0) and INT3 (+8) error bits, the ones the IRQ handler acts on */
#define INT1_BST_OVP		(1u << 16)
#define INT1_BST_DCM_UVP	(1u << 17)
#define INT1_BST_SHORT		(1u << 18)
#define INT1_TEMP_WARN		(1u << 25)
#define INT1_TEMP_ERR		(1u << 26)
#define INT3_AMP_SHORT		(1u << 12)
#define INT4_PLL_UNLOCK		(1u << 13)	/* read from INT4 RAW after GLOBAL_EN */
#define INT4_MCU_CONFIG_CLR	(1u << 16)	/* B0 PAC patch done */

/*
 * TST_FS_MON0. Both drivers mean to set the sample-rate monitor windows to
 * FS1 = 16, FS2 = 36 for an SCLK above 6 MHz (under the test key). On the
 * Pixel 3 that write never reached the chip: [PX]'s register map does not list
 * 0x2D10 as readable, so its read-modify-write failed silently. Stock sound
 * worked with the chip's own windows, so this stays off (the same applies to
 * the A0 PLL gain update of 0x3008 below, which failed the same way). Set it
 * to 1 to do what [ML] does.
 */
#define AMP_SET_FS_MON		0

static int
amp_testkey(const struct amp *a, int unlock)
{
	return unlock ? (amp_wr(a, R_TESTKEY, 0x5555) || amp_wr(a, R_TESTKEY, 0xaaaa)) :
	       (amp_wr(a, R_TESTKEY, 0xcccc) || amp_wr(a, R_TESTKEY, 0x3333));
}

static int
amp_seq(const struct amp *a, const uint32_t (*s)[2], unsigned n)
{
	for (unsigned i = 0; i < n; i++) {
		if (amp_wr(a, s[i][0], s[i][1])) {
			printf("BLUE SOUND: %s amp: write 0x%08x failed\n", a->name, s[i][0]);
			return EIO;
		}
	}
	return 0;
}

/* Revision A0 fixes: [PX] cs35l36_reva0_errata_patch, then cs35l36_pac_int_patch. */
static const uint32_t amp_a0_fix[][2] = {
	{ R_OTP_CTRL1, 0x00002060 }, { R_OTP_CTRL2, 1 },	/* OTP boot again, ECC off */
	{ R_OTP_CTRL1, 0x00002460 }, { R_OTP_CTRL2, 1 },	/* and with ECC on */
	{ 0x2088, 0x012a1838 }, { R_MISC_CTRL, 0x0100ee0e }, { R_PLL_LOOP_PARAMS, 0x0008184a },
	{ 0x7418, 0x509001c8 }, { 0x7064, 0x0929a800 }, { R_TST_FS_MON0, 0x0002c01c },
	{ 0x410c, 0x00000a11 }, { 0x6e08, 0x8b19140c }, { 0x6454, 0x0300000a },
	{ 0x7e14, 0x000020ef }, { 0x7e34, 0x0000000e }, { 0x410c, 0x00000a11 },
	{ 0x7410, 0x20514b00 },
	/* PAC interrupt set-up */
	{ R_CTRL_OVRRIDE, 0 },
	{ R_PAC_INT0_CTRL + 0x00, 0x00860001 }, { R_PAC_INT0_CTRL + 0x04, 0x00860001 },
	{ R_PAC_INT0_CTRL + 0x08, 0x00860001 }, { R_PAC_INT0_CTRL + 0x0c, 0x00860001 },
	{ R_PAC_INT0_CTRL + 0x10, 0x00860001 }, { R_PAC_INT0_CTRL + 0x14, 0x00860001 },
	{ R_PAC_INT0_CTRL + 0x18, 0x00860001 }, { R_PAC_INT0_CTRL + 0x1c, 0x00860001 },
	{ R_PAC_INT_FLUSH, 0x000000ff },
};

/* Revision B0 fixes: [PX] cs35l36_revb0_errata_patch (after the PAC patch). */
static const uint32_t amp_b0_fix[][2] = {
	{ 0x7064, 0x0929a800 },
	{ 0x7850, 0x00002fa9 }, { 0x7854, 0x0003f1d5 }, { 0x7858, 0x0003f5e3 },
	{ 0x785c, 0x00001137 }, { 0x7860, 0x0001a7a5 }, { 0x7864, 0x0002f16a },
	{ 0x7868, 0x00003e21 }, { 0x7848, 0x00000001 },
	{ 0x3854, 0x05180240 }, { 0x7418, 0x509001c8 }, { R_BST_ANA2_TEST, 0x028764bd },
};

/*
 * B0 only, before its errata ([PX] cs35l36_pac): with the test key open, hold
 * the internal PAC (a small patch processor) in reset, write its one-word
 * program, start it, and wait up to ~20 ms for "MCU config cleared" in INT4.
 */
static int
amp_b0_pac(const struct amp *a)
{
	uint32_t v = 0;
	int i;
	if (amp_testkey(a, 1)) {
		return EIO;
	}
	IOSleep(10);
	if (amp_wr(a, R_PAC_CTL1, 0) || amp_wr(a, R_PAC_CTL3, 1) ||
	    amp_wr(a, R_PAC_PMEM0, 0x00dd0102) || amp_wr(a, R_PAC_CTL3, 0) ||
	    amp_wr(a, R_PAC_CTL1, 1)) {
		return EIO;
	}
	IOSleep(10);
	for (i = 0; i < 20; i++) {
		if (amp_rd(a, R_INT4_STATUS, &v) == 0 && (v & INT4_MCU_CONFIG_CLR)) {
			break;
		}
		IOSleep(1);
	}
	if (!(v & INT4_MCU_CONFIG_CLR)) {
		printf("BLUE SOUND: %s amp: B0 PAC patch did not finish (INT4 0x%x)\n", a->name, v);
		amp_testkey(a, 0);
		return ETIMEDOUT;
	}
	int err = amp_wr(a, R_INT4_STATUS, INT4_MCU_CONFIG_CLR) || amp_upd(a, R_PAC_CTL1, 1, 0);
	return amp_testkey(a, 0) || err ? EIO : 0;
}

/*
 * After reset release. Both drivers wait 2 ms and read the ID once; neither
 * polls an "OTP boot done" bit (the header names one, 0x02000000, but not its
 * register), so this polls the ID for up to 20 ms instead.
 *
 * The revision is REV_ID (0x200C) >> 8: 0xA0 or 0xB0. Register 0x4 (SW_REV,
 * 0x06 on this phone) is not a silicon revision and no driver reads it. Any
 * other REV_ID gets no errata and a warning, as in both drivers (their switch
 * has no default case).
 */
static int
amp_boot(struct amp *a)
{
	uint32_t devid = 0, devid2 = 0, revid = 0, swrev = 0, hwrev = 0, otp30 = 0;
	int i, err;
	for (i = 0; i < 10; i++) {
		IOSleep(2);
		if (amp_rd(a, R_SW_RESET, &devid) == 0 && devid == DEVID_L36) {
			break;
		}
	}
	if (devid != DEVID_L36) {
		printf("BLUE SOUND: %s amp: DEVID 0x%x after %d ms, not a CS35L36\n", a->name, devid, 2 * i);
		return ENODEV;
	}
	if (amp_rd(a, R_REV_ID, &revid) || amp_rd(a, R_OTP_MEM30, &otp30)) {
		return EIO;
	}
	amp_rd(a, R_DEVICE_ID, &devid2);
	amp_rd(a, R_SW_REV, &swrev);
	amp_rd(a, R_HW_REV, &hwrev);
	a->rev = revid >> 8;
	a->l37 = (otp30 & 0x00ff0000u) == 0x00cc0000u;
	printf("BLUE SOUND: %s amp: CS35L%d (%d V boost max), REV_ID 0x%x -> rev 0x%x (%s), "
	    "DEVICE_ID 0x%x, SW_REV 0x%x, HW_REV 0x%x, OTP_MEM30 0x%x, ID after %d ms\n",
	    a->name, a->l37 ? 37 : 36, a->l37 ? 12 : 10, revid, a->rev,
	    a->rev == REV_A0 ? "A0" : a->rev == REV_B0 ? "B0" : "UNKNOWN: no errata applied",
	    devid2, swrev, hwrev, otp30, 2 * (i + 1));

	switch (a->rev) {
	case REV_A0:
		err = amp_testkey(a, 1) || amp_seq(a, amp_a0_fix, sizeof(amp_a0_fix) / sizeof(amp_a0_fix[0])) ||
		    amp_testkey(a, 0);
		break;
	case REV_B0:
		err = amp_b0_pac(a);
		if (!err) {
			err = amp_testkey(a, 1) || amp_seq(a, amp_b0_fix, sizeof(amp_b0_fix) / sizeof(amp_b0_fix[0])) ||
			    amp_testkey(a, 0);
		}
		break;
	default:
		err = 0;
		break;
	}
	if (err) {
		printf("BLUE SOUND: %s amp: rev 0x%x errata FAILED (%d)\n", a->name, a->rev, err);
		return EIO;
	}
	return 0;
}

/*
 * Everything except power, in the order [PX] applies it (codec probe, the
 * IRQ pin set-up, then the TDM startup's set_fmt / set_sysclk / hw_params).
 * slot: 0 for the top amp (0x41, left), 1 for the bottom amp (0x40, right).
 */
static int
amp_config(const struct amp *a, uint32_t slot)
{
	int err;

	/*
	 * INT pin ([PX] i2c probe, DT irq-config): output on, the INT pin (not
	 * GPIO), active low, IRQ source 1 (written on A0 only, as [PX] does),
	 * open drain. Then [PX]'s default masks: INT3 unmasks amp short; INT1
	 * unmasks boost OVP, boost short, temperature warning and error, plus
	 * bits 15 and 22, which no source names. Boost UVP (bit 17) stays masked
	 * but still latches in the status register, where amp_dump reads it.
	 */
	err = amp_upd(a, R_PAD_INTERFACE, 0x27u, 0x01u) ||
	    (a->rev == REV_A0 && amp_upd(a, R_PAD_INTERFACE, 0x08u, 0x08u)) ||
	    amp_wr(a, R_INT1_MASK, 0xf9ba7fffu) ||
	    amp_wr(a, R_INT3_MASK, 0xffffefffu);
	if (err) {
		return EIO;
	}

	/*
	 * [PX] codec probe, DT options in its order: amp-gain-zc, ldm-mode-select
	 * (all NG_AMP_EN bits), multi-amp-mode (TX pin Hi-Z when not sending),
	 * pdm-ldm-enter and -exit ramps. Boost: target 10000 mV =
	 * ((10000 - 2550) / 100 + 1) << 1 = 0x96; boost-ctl-select 1 = follow the
	 * class-H tracking target; peak 3700 mA = (3700 - 1600) / 50 + 16 = 58 =
	 * 0x3A ([PX], citing the datasheet: 16 = 1.60 A; [ML] leaves out the +16,
	 * which would give 2.65 A); 1.0 uH: K1 = K2 = 0x3C, CCM frequency 0, slope
	 * 0x75, LBST 0. Temperature warning at 115 C.
	 */
	err = amp_upd(a, R_AMP_GAIN_CTRL, 1u << 10, 1u << 10) ||
	    amp_upd(a, R_NG_CFG, 0x3f00u, 0x3f00u) ||
	    amp_upd(a, R_ASP_TX_PIN_CTRL, 1u << 21, 1u << 21) ||
	    amp_upd(a, R_DAC_MSM_CFG, 0x18u, 0x18u) ||
	    amp_upd(a, R_BST_VCTRL1, 0xffu, 0x96u) ||
	    amp_upd(a, R_BST_VCTRL2, 0x3u, 0x1u) ||
	    amp_upd(a, R_BST_PEAK_CUR, 0x7fu, 0x3au) ||
	    amp_upd(a, R_BST_COEFF, 0xffffu, 0x3c3cu) ||
	    amp_upd(a, R_BST_SW_FREQ, 0xfu, 0) ||
	    amp_upd(a, R_BST_SLOPE_LBST, 0xff03u, 0x7500u) ||
	    amp_upd(a, R_DTEMP_WARN_THLD, 0x3u, 0x1u);
	/*
	 * The DT's weak-fet-delay = 4 and weak-fet-thld = 1 are read by neither
	 * driver ([DT] names them classh-wk-fet-delay / classh-weak-fet-thld-
	 * millivolt), so the chip's defaults stood on stock; 4 (100 ms) is the
	 * documented default anyway. Nothing to write.
	 */
	if (err) {
		return EIO;
	}

	/*
	 * A CS35L36 is the 10 V part: [PX] clamps it for safety whatever the DT
	 * says. OVP threshold 11 V; with the test key, OVP trim 0x0C, limit the
	 * class-H target to VCTRL1, and VCTRL1 = 0x96 (10 V).
	 */
	if (!a->l37) {
		err = amp_upd(a, R_BST_OVERVOLT, 0x3fu, 0x10u) || amp_testkey(a, 1) ||
		    amp_upd(a, R_BST_ANA2_TEST, 0xfu << 15, 0xcu << 15) ||
		    amp_upd(a, R_BST_VCTRL2, 1u << 2, 1u << 2) ||
		    amp_upd(a, R_BST_VCTRL1, 0xffu, 0x96u) || amp_testkey(a, 0);
		if (err) {
			return EIO;
		}
	}

	/* A0 and B0 both need SYNC_GLOBAL_OVR off while GLOBAL_EN is 0. */
	if (amp_upd(a, R_CTRL_OVRRIDE, 1u << 1, 0)) {
		return EIO;
	}

	/*
	 * Serial port ([MC] sdm845_tdm_snd_startup: DSP_A | CBS_CFS | IB_NF):
	 * slave for both clocks, not forced, bit clock inverted, frame sync not
	 * inverted, DSP mode A (data one bit clock after the frame pulse). Data 32
	 * bits per slot each way (S32_LE, hw_params); this amp's input slot; DAC
	 * fed zeros until power-up.
	 */
	err = amp_upd(a, R_ASP_TX_PIN_CTRL, 0x1c0u, 0x100u) ||
	    amp_upd(a, R_ASP_RATE_CTRL, 0x7u, 0) ||
	    amp_upd(a, R_ASP_FORMAT, 0x7u, 0) ||
	    amp_upd(a, R_ASP_FRAME_CTRL, 0x00ff00ffu, 0x00200020u) ||
	    amp_upd(a, R_ASP_RX1_SLOT, 0x3fu, slot) ||
	    amp_upd(a, R_ASP_RX1_SEL, 0x7fu, 0);
	if (err) {
		return EIO;
	}

	/*
	 * Clocks ([PX] codec set_sysclk, clock 0 = SCLK, 12.288 MHz): PLL open
	 * loop, reference 12.288 MHz (code 0x33), reference off, source SCLK, loop
	 * closed, reference on. PCM mode (not PDM). 48 kHz is GLOBAL_FS 0x03
	 * (hw_params). This only arms the PLL; it locks after GLOBAL_EN, and
	 * only with SCLK running.
	 */
	err = amp_upd(a, R_PLL_CLK_CTRL, 1u << 11, 1u << 11) ||
	    amp_upd(a, R_PLL_CLK_CTRL, 0x3fu << 5, 0x33u << 5) ||
	    amp_upd(a, R_PLL_CLK_CTRL, 1u << 4, 0) ||
	    amp_upd(a, R_PLL_CLK_CTRL, 0x7u, 0) ||
	    amp_upd(a, R_PLL_CLK_CTRL, 1u << 11, 0) ||
	    amp_upd(a, R_PLL_CLK_CTRL, 1u << 4, 1u << 4) ||
	    amp_upd(a, R_DAC_MSM_CFG, 0x1u, 0) ||
	    amp_upd(a, R_GLOBAL_CLK_CTRL, 0x1fu, 0x03u);
	if (err) {
		return EIO;
	}
	/*
	 * A0 only: DCO and misc PLL values. [PX] also updates 0x3008's gains
	 * (bits 9:4 = 4, bits 3:0 = 0x0A for 12.288 MHz), but that update failed
	 * on stock (see AMP_SET_FS_MON), so the errata value 0x0008184A stands.
	 */
	if (a->rev == REV_A0) {
		err = amp_testkey(a, 1) || amp_wr(a, R_DCO_CTRL, 0x00036da8) ||
		    amp_wr(a, R_MISC_CTRL, 0x0100ee0e) || amp_testkey(a, 0);
		if (err) {
			return EIO;
		}
	}
#if AMP_SET_FS_MON
	/* [ML]: SCLK > 6 MHz: FS1 = 16 (bits 10:0), FS2 = 36 (<< 12, inside mask 0x00FFF800). */
	err = amp_testkey(a, 1) || amp_upd(a, R_TST_FS_MON0, 0x00ffffffu, 16u | (36u << 12)) || amp_testkey(a, 0);
	if (err) {
		return EIO;
	}
#endif

	/*
	 * Levels. "AMP PCM Gain" / "R AMP PCM Gain" = 17 is AMP_GAIN_CTRL bits 9:5
	 * ([PX] SOC_SINGLE_TLV("AMP PCM Gain", 0x6C04, shift 5, max 0x13); the
	 * reset value is 0x13, the maximum). The dB size of a step is not public:
	 * the sibling CS35L41 uses the same field as 0.5 dB + 1 dB/step, which
	 * would make 17 about 17.5 dB. Digital volume 0 dB (bits 13:3 = 0; also
	 * the reset value; [PX] range -102 dB (0x4D0) to +12 dB in 0.125 dB steps).
	 */
	err = amp_upd(a, R_AMP_GAIN_CTRL, 0x1fu << 5, 17u << 5) ||
	    amp_upd(a, R_AMP_DIG_VOL, 0x7ffu << 3, 0);
	if (err) {
		return EIO;
	}
	printf("BLUE SOUND: %s amp: configured, TDM slot %u, rev 0x%x\n", a->name, slot, a->rev);
	return 0;
}

/*
 * Power, as [PX]'s DAPM runs it for "AMP Playback" (widget order: SDIN, BOOST
 * Mux, CLASS H, Main AMP, then the "AMP Enable" switch); the codec's
 * mute_stream op only talks to the ADSP's speaker protection, so the mute here
 * is the DAPM one.
 *
 * Up needs the TDM clocks already running. On stock, the AFE port (and so
 * SCLK and frame sync) starts in the CPU DAI's prepare, before the DAPM
 * stream event that sets GLOBAL_EN. [PX] waits 2 ms and checks PLL unlock
 * once, then unmutes anyway; this polls up to 20 ms, also unmutes anyway (a
 * late clock may still lock), and returns ETIMEDOUT so the caller knows.
 *
 * Down: DAC source to zeros, mute, amp off, GLOBAL_EN off, 2 ms; class H off,
 * boost to bypass, 2 ms; serial port input off. Stop the TDM clocks after.
 */
static int
amp_power(const struct amp *a, int on)
{
	uint32_t raw = 0;
	int i, err;
	if (on) {
		err = amp_upd(a, R_ASP_RX_TX_EN, 1u << 16, 1u << 16) ||	/* SDIN: ASP RX1 on */
		    amp_upd(a, R_PWR_CTRL2, 0x3u << 4, 0x2u << 4) ||		/* BOOST Mux: boost on */
		    amp_upd(a, R_PWR_CTRL3, 1u << 4, 1u << 4) ||		/* CLASS H */
		    amp_upd(a, R_PWR_CTRL2, 1u, 1u) ||				/* Main AMP: AMP_EN */
		    amp_upd(a, R_PWR_CTRL1, 1u, 1u);				/* GLOBAL_EN */
		if (err) {
			return EIO;
		}
		for (i = 0; i < 10; i++) {
			IOSleep(2);
			if (amp_rd(a, R_INT4_RAW, &raw) == 0 && !(raw & INT4_PLL_UNLOCK)) {
				break;
			}
		}
		/* DAC from ASP RX1, then unmute ("AMP Enable Switch" = 1). */
		err = amp_upd(a, R_ASP_RX1_SEL, 0x7fu, 0x08u) ||
		    amp_upd(a, R_AMP_OUT_MUTE, 1u << 4, 0);
		printf("BLUE SOUND: %s amp: on, PLL %s after %d ms (INT4 raw 0x%x)%s\n", a->name,
		    (raw & INT4_PLL_UNLOCK) ? "NOT LOCKED" : "locked", 2 * (i < 10 ? i + 1 : 10), raw,
		    err ? ", unmute FAILED" : "");
		if (err) {
			return EIO;
		}
		return (raw & INT4_PLL_UNLOCK) ? ETIMEDOUT : 0;
	}
	/* Every step is tried even if one fails (one statement each keeps the order). */
	err = 0;
	err += amp_upd(a, R_ASP_RX1_SEL, 0x7fu, 0) != 0;
	err += amp_upd(a, R_AMP_OUT_MUTE, 1u << 4, 1u << 4) != 0;
	err += amp_upd(a, R_PWR_CTRL2, 1u, 0) != 0;
	err += amp_upd(a, R_PWR_CTRL1, 1u, 0) != 0;
	IOSleep(2);
	err += amp_upd(a, R_PWR_CTRL3, 1u << 4, 0) != 0;
	err += amp_upd(a, R_PWR_CTRL2, 0x3u << 4, 0x1u << 4) != 0;
	IOSleep(2);
	err += amp_upd(a, R_ASP_RX_TX_EN, 1u << 16, 0) != 0;
	printf("BLUE SOUND: %s amp: off%s\n", a->name, err ? " (a write FAILED)" : "");
	return err ? EIO : 0;
}

/*
 * For when it stays silent. Prints the power, clock, port and level registers
 * and the four interrupt status words (latched, then live), and decodes the
 * error bits [PX]'s IRQ handler acts on. Returns the latched INT1 error bits,
 * with the amp-short bit from INT3 folded in as bit 0.
 */
static uint32_t
amp_dump(const struct amp *a)
{
	static const struct {
		uint32_t reg;
		const char *name;
	} r[] = {
		{ R_PWR_CTRL1, "PWR1 (b0 GLOBAL_EN)" }, { R_PWR_CTRL2, "PWR2 (b0 AMP, b5:4 BST)" },
		{ R_PWR_CTRL3, "PWR3 (b4 classH)" }, { R_AMP_OUT_MUTE, "MUTE (b4)" },
		{ R_PLL_CLK_CTRL, "PLL_CLK" }, { R_GLOBAL_CLK_CTRL, "GLOBAL_FS" },
		{ R_ASP_TX_PIN_CTRL, "ASP_PIN" }, { R_ASP_RATE_CTRL, "ASP_RATE" },
		{ R_ASP_FORMAT, "ASP_FMT" }, { R_ASP_FRAME_CTRL, "ASP_FRAME" },
		{ R_ASP_RX1_SLOT, "RX1_SLOT" }, { R_ASP_RX_TX_EN, "RX_TX_EN (b16 RX1)" },
		{ R_ASP_RX1_SEL, "DAC_SRC (8=ASP)" }, { R_AMP_DIG_VOL, "DIG_VOL" },
		{ R_AMP_GAIN_CTRL, "GAIN (b9:5)" }, { R_BST_VCTRL1, "BST_V1" },
		{ R_BST_VCTRL2, "BST_V2" }, { R_BST_PEAK_CUR, "BST_IPK" },
		{ R_DTEMP_STATUS, "DTEMP" }, { R_VPBR_STATUS, "VPBR" }, { R_VBBR_STATUS, "VBBR" },
		{ R_PAD_INTERFACE, "PAD" }, { R_INT1_MASK, "INT1_MASK" }, { R_INT3_MASK, "INT3_MASK" },
	};
	uint32_t v, st[4] = { 0 }, raw[4] = { 0 };
	for (unsigned i = 0; i < sizeof(r) / sizeof(r[0]); i++) {
		int e = amp_rd(a, r[i].reg, &v);
		printf("BLUE SOUND: %s amp: 0x%08x %-24s %s0x%08x\n", a->name, r[i].reg, r[i].name, e ? "NACK " : "", v);
	}
	for (int i = 0; i < 4; i++) {
		amp_rd(a, R_INT1_STATUS + 4u * i, &st[i]);
		amp_rd(a, R_INT1_RAW + 4u * i, &raw[i]);
	}
	printf("BLUE SOUND: %s amp: INT1-4 latched 0x%x 0x%x 0x%x 0x%x, live 0x%x 0x%x 0x%x 0x%x\n", a->name,
	    st[0], st[1], st[2], st[3], raw[0], raw[1], raw[2], raw[3]);
	printf("BLUE SOUND: %s amp:%s%s%s%s%s%s%s\n", a->name,
	    (raw[3] & INT4_PLL_UNLOCK) ? " PLL-UNLOCKED(no SCLK?)" : " pll-locked",
	    (st[0] & INT1_BST_OVP) ? " BOOST-OVERVOLTAGE" : "",
	    (st[0] & INT1_BST_DCM_UVP) ? " BOOST-UNDERVOLTAGE" : "",
	    (st[0] & INT1_BST_SHORT) ? " BOOST-INDUCTOR-SHORT" : "",
	    (st[0] & INT1_TEMP_WARN) ? " TEMP-WARNING" : "",
	    (st[0] & INT1_TEMP_ERR) ? " TEMP-ERROR" : "",
	    (st[2] & INT3_AMP_SHORT) ? " AMP-OUTPUT-SHORT" : "");
	return (st[0] & (INT1_BST_OVP | INT1_BST_DCM_UVP | INT1_BST_SHORT | INT1_TEMP_WARN | INT1_TEMP_ERR)) |
	       ((st[2] & INT3_AMP_SHORT) ? 1u : 0);
}

/*
 * The protection errors latch the amp into a safe mode until released ([PX]
 * cs35l36_irq): pulse the matching PROTECT_REL_ERR bit 0, 1, 0, then clear the
 * status bit (write 1). Release bits: 1 amp short, 2 boost short, 3 boost OVP,
 * 4 boost UVP, 5 temp warning, 6 temp error. ([PX] pulses bit 6, not 3, for
 * boost OVP; that looks like a copy slip, so both are pulsed here.)
 * errs is amp_dump's return value.
 */
static void
amp_recover(const struct amp *a, uint32_t errs)
{
	uint32_t rel = 0;
	rel |= (errs & 1u) ? 1u << 1 : 0;
	rel |= (errs & INT1_BST_SHORT) ? 1u << 2 : 0;
	rel |= (errs & INT1_BST_OVP) ? (1u << 3) | (1u << 6) : 0;
	rel |= (errs & INT1_BST_DCM_UVP) ? 1u << 4 : 0;
	rel |= (errs & INT1_TEMP_WARN) ? 1u << 5 : 0;
	rel |= (errs & INT1_TEMP_ERR) ? 1u << 6 : 0;
	if (!rel) {
		return;
	}
	amp_upd(a, R_PROTECT_REL_ERR, rel, 0);
	amp_upd(a, R_PROTECT_REL_ERR, rel, rel);
	amp_upd(a, R_PROTECT_REL_ERR, rel, 0);
	if (errs & ~1u) {
		amp_wr(a, R_INT1_STATUS, errs & ~1u);
	}
	if (errs & 1u) {
		amp_wr(a, R_INT1_STATUS + 8u, INT3_AMP_SHORT);
	}
	printf("BLUE SOUND: %s amp: released protection 0x%x (errors 0x%x)\n", a->name, rel, errs);
}
