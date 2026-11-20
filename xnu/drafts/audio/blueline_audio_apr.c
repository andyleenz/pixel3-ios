/*
 * Pixel 3 (blueline) speaker: PCM to the two CS35L36 amps on QUAT TDM through
 * the stock ADSP firmware's Elite audio services (Android 9-12 era, APR
 * transport; not AudioReach/GPR).
 *
 *   bsnd_shm -> ASM session 1 (PCM decoder) -> ADM Audio Rx matrix
 *            -> COPP (NULL topology) -> AFE port QUAT_TDM_RX_0 -> TDM pins
 *
 * Written from the protocol as described by, not copied from: the downstream
 * audio driver (LineageOS android_kernel_google_msm-4.9, lineage-19.1,
 * techpack/audio: ipc/apr.h, ipc/apr.c, include/dsp/apr_audio-v2.h,
 * include/dsp/q6core.h, dsp/q6core.c, q6afe.c, q6adm.c, q6asm.c,
 * msm_audio_ion.c, asoc/msm-dai-q6-v2.c, msm-pcm-routing-v2.c, sdm845.c) and
 * mainline Linux sound/soc/qcom/qdsp6/ (q6core.c, q6afe.c, q6adm.c, q6asm.c,
 * q6asm-dai.c, q6routing.c) plus sound/soc/qcom/sdm845.c. Board values: the
 * stock DT node qcom,msm-dai-tdm-quat-rx with its dtbo 8 overrides, and
 * mixer_paths_tavil_b1.xml (path "speaker": QUAT_TDM_RX_0, two channels, S32_LE).
 *
 * Every packet is an APR SEQ_CMD: 20-byte header, src APPS 5 -> dest ADSP 4,
 * the same service id at both ends (CORE 3, AFE 4, ASM 7, ADM 8). Each command
 * waits for the reply carrying its token, APR_BASIC_RSP_RESULT 0x000110E8
 * {opcode, status} unless another reply is named. Ports: QUAT_TDM_RX_0 0x9030,
 * its group 0x9130; ASM session 1 stream 1 = 0x0101.
 *
 * bsnd_apr_core_ready
 *   1  CORE AVCS_CMD_ADSP_EVENT_GET_STATE 0x0001290C, repeated until
 *           AVCS_CMDRSP_ADSP_EVENT_GET_STATE 0x0001290D says 1
 *   2  CORE AVCS_CMD_GET_FWK_VERSION 0x0001292C -> AVCS_CMDRSP_GET_FWK_VERSION 0x0001292D
 * bsnd_apr_tdm_start
 *   3  AFE  AFE_SVC_CMD_SET_PARAM 0x000100F3: AFE_MODULE_CLOCK_SET 0x0001028F,
 *           AFE_PARAM_ID_CLOCK_SET 0x00010290: Q6AFE_LPASS_CLK_ID_QUAD_TDM_IBIT 0x206,
 *           12288000 Hz, Q6AFE_LPASS_CLK_ATTRIBUTE_INVERT_COUPLE_NO 4, enable 1
 *  (3a) AFE AFE_SVC_CMD_SET_PARAM: AFE_MODULE_GROUP_DEVICE 0x00010254,
 *           AFE_PARAM_ID_GROUP_DEVICE_TDM_CONFIG 0x0001029E: group 0x9130 = {0x9030}
 *  (3b) AFE AFE_SVC_CMD_SET_PARAM: AFE_MODULE_GROUP_DEVICE,
 *           AFE_PARAM_ID_GROUP_DEVICE_ENABLE 0x00010256 {0x9130, 1}
 *           (3a/3b only with bsnd_tdm_group; stock skips them for a one-port group)
 *   4  AFE  AFE_PORT_CMD_SET_PARAM_V2 0x000100EF, port 0x9030: AFE_MODULE_AUDIO_DEV_INTERFACE
 *           0x0001020C, AFE_PARAM_ID_TDM_CONFIG 0x0001029D: 2 of 8 x 32-bit slots (mask 0x3),
 *           48 kHz, short sync, internal sync, one-bit data delay
 *   5  AFE  AFE_PORT_CMD_SET_PARAM_V2, port 0x9030: AFE_MODULE_TDM 0x0001028A,
 *           AFE_PARAM_ID_PORT_SLOT_MAPPING_CONFIG 0x00010297: byte offsets {0, 4}
 *   6  AFE  AFE_PORT_CMD_DEVICE_START 0x000100E5 {0x9030}
 * bsnd_apr_stream_open
 *   7  ASM  ASM_CMD_SHARED_MEM_MAP_REGIONS 0x00010D92, ADSP_MEMORY_MAP_SHMEM8_4K_POOL 3
 *           -> ASM_CMDRSP_SHARED_MEM_MAP_REGIONS 0x00010D93 {mem_map_handle}
 *   8  ASM  ASM_STREAM_CMD_OPEN_WRITE_V3 0x00010DB3 to 0x0101: ASM_MEDIA_FMT_MULTI_CHANNEL_PCM_V2
 *           0x00010DA5, ASM_STREAM_POSTPROCOPO_ID_NONE 0x00010C68, sink = matrix
 *   9  ADM  ADM_CMD_DEVICE_OPEN_V5 0x00010326 to 0x9030: RX path, endpoint 0x9030,
 *           NULL_COPP_TOPOLOGY 0x00010312, 2 ch, 16 bit, 48 kHz
 *           -> ADM_CMDRSP_DEVICE_OPEN_V5 0x00010329 {status, copp_id}
 *  10  ADM  ADM_CMD_MATRIX_MAP_ROUTINGS_V5 0x00010325: ADM_MATRIX_ID_AUDIO_RX 0, session 1 -> copp_id
 *  11  ASM  ASM_DATA_CMD_MEDIA_FMT_UPDATE_V2 0x00010D98 to 0x0101: 2 ch, 16 bit, 48 kHz, FL/FR
 *  12  ASM  ASM_SESSION_CMD_RUN_V2 0x00010DAA to 0x0101: run immediately
 * bsnd_apr_write (does not wait)
 *      ASM  ASM_DATA_CMD_WRITE_V2 0x00010DAB to 0x0101 -> ASM_DATA_EVENT_WRITE_DONE_V2 0x00010D99
 *           {addr, handle, status}; ASM_SESSION_EVENT_RX_UNDERFLOW 0x00010C17 when the queue runs dry
 * bsnd_apr_stream_close
 *  13  ASM  ASM_STREAM_CMD_CLOSE 0x00010BCD to 0x0101
 *  14  ADM  ADM_CMD_DEVICE_CLOSE_V5 0x00010327 to copp_id, from port 0x9030
 *  15  ASM  ASM_CMD_SHARED_MEM_UNMAP_REGIONS 0x00010D94 {mem_map_handle}
 * bsnd_apr_tdm_stop
 *  16  AFE  AFE_PORT_CMD_DEVICE_STOP 0x000100E6 {0x9030}, then 3b with 0 if used, then 3 with enable 0
 */
#if defined(ARM64_BOARD_CONFIG_SWEET)

#include <sys/systm.h>
#include <sys/errno.h>
#include <kern/clock.h>
#include <mach/mach_time.h>
#include <libkern/libkern.h>
#include "blueline_audio_apr.h"

extern void IOSleep(unsigned int milliseconds);

/* APR transport, ipc/apr.h */
#define APR_HDR_SIZE			20u		/* sizeof(struct apr_hdr) */
#define APR_HDR_FIELD_SEQ_CMD		0x0250u		/* APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD 2, APR_HDR_LEN 5 words, APR_PKT_VER 0) */
#define APR_DOMAIN_ADSP			4
#define APR_DOMAIN_APPS			5
#define APR_SVC_ADSP_CORE		3
#define APR_SVC_AFE			4
#define APR_SVC_ASM			7
#define APR_SVC_ADM			8
#define APR_BASIC_RSP_RESULT		0x000110E8u
#define APR_RSP_ACCEPTED		0x000100BEu

/* Status codes, apr_audio-v2.h ADSP_E* */
#define ADSP_EOK			0x0u
#define ADSP_EFAILED			0x1u
#define ADSP_EUNSUPPORTED		0x3u
#define ADSP_EABORTED			0xDu

/* Core, include/dsp/q6core.h */
#define AVCS_CMD_ADSP_EVENT_GET_STATE		0x0001290Cu
#define AVCS_CMDRSP_ADSP_EVENT_GET_STATE	0x0001290Du
#define AVCS_CMD_GET_FWK_VERSION		0x0001292Cu
#define AVCS_CMDRSP_GET_FWK_VERSION		0x0001292Du

/* AFE, apr_audio-v2.h (each param's minor version is 1, as q6afe.c and msm-dai-q6-v2.c send) */
#define AFE_SVC_CMD_SET_PARAM			0x000100F3u
#define AFE_PORT_CMD_SET_PARAM_V2		0x000100EFu
#define AFE_PORT_CMD_DEVICE_START		0x000100E5u
#define AFE_PORT_CMD_DEVICE_STOP		0x000100E6u
#define AFE_MODULE_CLOCK_SET			0x0001028Fu
#define AFE_PARAM_ID_CLOCK_SET			0x00010290u
#define Q6AFE_LPASS_CLK_ID_QUAD_TDM_IBIT	0x206u	/* internal (DT clk-internal <1>); _EBIT 0x207 is for a slave */
#define Q6AFE_LPASS_CLK_ATTRIBUTE_INVERT_COUPLE_NO 0x4u	/* msm_dai_tdm_q6_probe default, no DT override; mainline
							 * q6afe-dai.c q6afe_mi2s_set_sysclk for TDM clocks */
#define AFE_MODULE_AUDIO_DEV_INTERFACE		0x0001020Cu
#define AFE_PARAM_ID_TDM_CONFIG			0x0001029Du
#define AFE_MODULE_TDM				0x0001028Au
#define AFE_PARAM_ID_PORT_SLOT_MAPPING_CONFIG	0x00010297u
#define AFE_MODULE_GROUP_DEVICE			0x00010254u
#define AFE_PARAM_ID_GROUP_DEVICE_TDM_CONFIG	0x0001029Eu
#define AFE_PARAM_ID_GROUP_DEVICE_ENABLE	0x00010256u
#define AFE_PORT_INVALID			0xFFFFu	/* also AFE_SLOT_MAPPING_OFFSET_INVALID */

/* AFE_PORT_ID_TDM_PORT_RANGE_START 0x9000 + 0x30, group = port + 0x100; the stock DT agrees. */
#define QUAT_TDM_RX_0		0x9030u		/* AFE_PORT_ID_QUATERNARY_TDM_RX */
#define QUAT_TDM_RX_GROUP	0x9130u		/* AFE_GROUP_DEVICE_ID_QUATERNARY_TDM_RX */

/* sdm845.c sdm845_tdm_snd_hw_params: 8 x 32-bit slots, mask 0xFFFF >> (16 - ch), channel n at byte 4n. */
#define TDM_RATE		48000u
#define TDM_CHANNELS		2u
#define TDM_SLOTS		8u
#define TDM_SLOT_BITS		32u
#define TDM_SLOT_MASK		0x3u
#define TDM_BCLK_HZ		(TDM_RATE * TDM_SLOTS * TDM_SLOT_BITS)	/* 12288000 = DT clk-rate */

/* ADM, apr_audio-v2.h and q6adm.c */
#define ADM_CMD_DEVICE_OPEN_V5		0x00010326u
#define ADM_CMDRSP_DEVICE_OPEN_V5	0x00010329u
#define ADM_CMD_DEVICE_CLOSE_V5		0x00010327u
#define ADM_CMD_MATRIX_MAP_ROUTINGS_V5	0x00010325u
#define ADM_MATRIX_ID_AUDIO_RX		0
#define ADM_CMD_COPP_OPEN_MODE_OF_OPERATION_RX_PATH_COPP 1
#define ADM_CMD_COPP_OPEN_END_POINT_ID_2_IGNORE	0xFFFFu
#define NULL_COPP_TOPOLOGY		0x00010312u
#define INVALID_COPP_ID			0xFFu
#define PCM_CHANNEL_FL			1
#define PCM_CHANNEL_FR			2

/*
 * COPP width. Stock takes it from the app type (16-bit playback 69936 gives 16)
 * or else the back end (S32_LE gives 32): msm-pcm-routing-v2.c
 * msm_routing_get_bit_width. The AFE widens to 32-bit slots either way.
 */
#define BSND_ADM_BITS			16u

/* ASM, apr_audio-v2.h */
#define ASM_CMD_SHARED_MEM_MAP_REGIONS		0x00010D92u
#define ASM_CMDRSP_SHARED_MEM_MAP_REGIONS	0x00010D93u
#define ASM_CMD_SHARED_MEM_UNMAP_REGIONS	0x00010D94u
#define ADSP_MEMORY_MAP_SHMEM8_4K_POOL		3	/* what every q6 driver maps with, not EBI 0 */
#define ASM_STREAM_CMD_OPEN_WRITE_V3		0x00010DB3u
#define ASM_STREAM_POSTPROCOPO_ID_NONE		0x00010C68u	/* mainline q6asm.c ASM_NULL_POPP_TOPOLOGY */
#define ASM_MEDIA_FMT_MULTI_CHANNEL_PCM_V2	0x00010DA5u
#define ASM_DATA_CMD_MEDIA_FMT_UPDATE_V2	0x00010D98u
#define ASM_SESSION_CMD_RUN_V2			0x00010DAAu
#define ASM_DATA_CMD_WRITE_V2			0x00010DABu
#define ASM_DATA_EVENT_WRITE_DONE_V2		0x00010D99u
#define ASM_SESSION_EVENT_RX_UNDERFLOW		0x00010C17u
#define ASM_STREAM_CMD_CLOSE			0x00010BCDu

/* Session 1 (of ASM_MAX_SESSION_ID 15), stream 1; APR port = session << 8 | stream (q6asm.c __q6asm_add_hdr). */
#define ASM_SESSION		1u
#define ASM_PORT		((ASM_SESSION << 8) | 1u)
#define BSND_FRAME_BYTES	4u		/* 2 channels x 16 bits */

#define BSND_TIMEOUT_MS		1000u		/* q6afe.c / q6adm.c TIMEOUT_MS */
#define BSND_MAX_PAYLOAD	96u
#define BSND_TOK_WRITE		0x80000000u	/* data-write tokens: this bit + slot index */
#define BSND_WR_SLOTS		16u
#define BSND_NO_COPP		0xFFFFu

/*
 * Steps 3a/3b. msm_dai_q6_tdm_prepare sends them only for a group of more than
 * one port; QUAT RX has one (DT tdm-group-num-ports <1>), and mainline never
 * sends them. Set this if DEVICE_START is refused.
 */
static bool bsnd_tdm_group = false;

/* ---- Wire formats: little-endian, packed, named after the apr.h / apr_audio-v2.h structs ---- */

struct bsnd_apr_hdr {			/* apr_hdr */
	uint16_t hdr_field, pkt_size;	/* pkt_size: header + payload */
	uint8_t src_svc, src_domain;
	uint16_t src_port;
	uint8_t dest_svc, dest_domain;
	uint16_t dest_port;
	uint32_t token, opcode;		/* the token comes back in the reply */
} __attribute__((packed));

/*
 * afe_svc_cmd_set_param, afe_port_cmd_set_param_v2 (address and handle 0:
 * the data follows in-band), afe_port_param_data_v2, and the {id, value}
 * of afe_group_device_enable and afe_port_cmd_device_start / _stop.
 */
struct bsnd_afe_svc_cmd { uint32_t payload_size, addr_lsw, addr_msw, mem_map_handle; } __attribute__((packed));
struct bsnd_afe_port_cmd {
	uint16_t port_id, payload_size;
	uint32_t addr_lsw, addr_msw, mem_map_handle;
} __attribute__((packed));
struct bsnd_param_hdr { uint32_t module_id, param_id; uint16_t param_size, reserved; } __attribute__((packed));
struct bsnd_pair16 { uint16_t id, value; } __attribute__((packed));

struct bsnd_clk_set {			/* afe_clk_set */
	uint32_t minor_version, clk_id, clk_freq_in_hz;
	uint16_t clk_attri, clk_root;
	uint32_t enable;
} __attribute__((packed));

struct bsnd_tdm_cfg {			/* afe_param_id_tdm_cfg */
	uint32_t minor_version, num_channels, sample_rate, bit_width;
	uint16_t data_format, sync_mode, sync_src, nslots_per_frame;
	uint16_t ctrl_data_out_enable, ctrl_invert_sync_pulse, ctrl_sync_data_delay, slot_width;
	uint32_t slot_mask;
} __attribute__((packed));

struct bsnd_slot_map {			/* afe_param_id_slot_mapping_cfg */
	uint32_t minor_version;
	uint16_t num_channel, bitwidth;
	uint32_t data_align_type;
	uint16_t offset[8];		/* byte offset of each channel within the frame */
} __attribute__((packed));

struct bsnd_group_tdm_cfg {		/* afe_param_id_group_device_tdm_cfg */
	uint32_t minor_version;
	uint16_t group_id, reserved;
	uint16_t port_id[8];
	uint32_t num_channels, sample_rate, bit_width;
	uint16_t nslots_per_frame, slot_width;
	uint32_t slot_mask;
} __attribute__((packed));

struct bsnd_adm_open {			/* adm_cmd_device_open_v5 */
	uint16_t flags, mode_of_operation, endpoint_id_1, endpoint_id_2;
	uint32_t topology_id;
	uint16_t dev_num_channel, bit_width;
	uint32_t sample_rate;
	uint8_t dev_channel_mapping[8];
} __attribute__((packed));

struct bsnd_adm_map {			/* adm_cmd_matrix_map_routings_v5 + one adm_session_map_node_v5 */
	uint32_t matrix_id, num_sessions;
	uint16_t session_id, num_copps, copp_id, pad;	/* one COPP, padded to 32 bits */
} __attribute__((packed));

struct bsnd_mem_map {			/* avs_cmd_shared_mem_map_regions + one avs_shared_map_region_payload */
	uint16_t mem_pool_id, num_regions;
	uint32_t property_flag;		/* 0: the address is physical, as the DSP sees it */
	uint32_t shm_addr_lsw, shm_addr_msw, mem_size_bytes;
} __attribute__((packed));

struct bsnd_open_write {		/* asm_stream_cmd_open_write_v3 */
	uint32_t mode_flags;
	uint16_t sink_endpointype, bits_per_sample;
	uint32_t postprocopo_id, dec_fmt_id;
} __attribute__((packed));

struct bsnd_media_fmt {			/* asm_data_cmd_media_fmt_update_v2 + asm_multi_channel_pcm_fmt_blk_v2 */
	uint32_t fmt_blk_size;		/* bytes after this field */
	uint16_t num_channels, bits_per_sample;
	uint32_t sample_rate;
	uint16_t is_signed, reserved;
	uint8_t channel_mapping[8];
} __attribute__((packed));

struct bsnd_write {			/* asm_data_cmd_write_v2 */
	uint32_t buf_addr_lsw, buf_addr_msw, mem_map_handle, buf_size;
	uint32_t seq_id, timestamp_lsw, timestamp_msw, flags;
} __attribute__((packed));

_Static_assert(sizeof(struct bsnd_apr_hdr) == APR_HDR_SIZE && sizeof(struct bsnd_afe_svc_cmd) == 16 &&
    sizeof(struct bsnd_afe_port_cmd) == 16 && sizeof(struct bsnd_param_hdr) == 12, "apr/afe headers");
_Static_assert(sizeof(struct bsnd_clk_set) == 20 && sizeof(struct bsnd_tdm_cfg) == 36 &&
    sizeof(struct bsnd_slot_map) == 28 && sizeof(struct bsnd_group_tdm_cfg) == 44, "afe params");
_Static_assert(sizeof(struct bsnd_adm_open) == 28 && sizeof(struct bsnd_adm_map) == 16 &&
    sizeof(struct bsnd_mem_map) == 20 && sizeof(struct bsnd_open_write) == 16 &&
    sizeof(struct bsnd_media_fmt) == 24 && sizeof(struct bsnd_write) == 32, "adm/asm payloads");

/* ---- State ---- */

/* The awaited reply. bsnd_apr_rx claims the token (-> 0) before filling the rest: taken whole or not at all. */
static struct {
	uint32_t token, done;
	uint32_t opcode, status, len;	/* reply opcode, ADSP status, payload bytes */
	uint32_t pl[32];		/* the first 128 payload bytes */
} bsnd_rsp;

static uint32_t bsnd_seq;		/* control tokens, 1..0x7fffffff */

/* Writes the DSP holds; slot index = token & ~BSND_TOK_WRITE. */
static struct {
	uint32_t busy, off, len;
} bsnd_wr[BSND_WR_SLOTS];
static uint32_t bsnd_wr_inflight;
static bsnd_write_done_fn bsnd_wr_cb;

static struct {
	bool tdm_up, group_up;		/* port started; steps 3a/3b done */
	bool stream_open, running;	/* ASM session open; RUN sent, writes allowed */
	uint16_t copp_id;		/* BSND_NO_COPP when none */
	uint32_t mem_handle;		/* 0 when unmapped */
	uint32_t underflows;
} bsnd = { .copp_id = BSND_NO_COPP };

/* ---- Helpers ---- */

static uint64_t
ms_abs(uint32_t ms)
{
	uint64_t t;
	nanoseconds_to_absolutetime((uint64_t)ms * NSEC_PER_MSEC, &t);
	return t;
}

static const char *
adsp_err(uint32_t s)
{
	static const char *const names[] = {
		"EOK", "EFAILED", "EBADPARAM", "EUNSUPPORTED", "EVERSION", "EUNEXPECTED",
		"EPANIC", "ENORESOURCE", "EHANDLE", "EALREADY", "ENOTREADY", "EPENDING",
		"EBUSY", "EABORTED", "EPREEMPTED", "ECONTINUE", "EIMMEDIATE", "ENOTIMPL",
		"ENEEDMORE", "?", "ENOMEMORY", "ENOTEXIST",
	};
	if (s < sizeof(names) / sizeof(names[0])) {
		return names[s];
	}
	return s == 0x11174u ? "ETERMINATED" : "?";
}

static void
apr_hdr(struct bsnd_apr_hdr *h, uint8_t svc, uint16_t src_port, uint16_t dest_port,
    uint32_t token, uint32_t opcode, uint32_t payload_len)
{
	h->hdr_field = APR_HDR_FIELD_SEQ_CMD;
	h->pkt_size = (uint16_t)(APR_HDR_SIZE + payload_len);
	h->src_svc = h->dest_svc = svc;
	h->src_domain = APR_DOMAIN_APPS;
	h->dest_domain = APR_DOMAIN_ADSP;
	h->src_port = src_port;
	h->dest_port = dest_port;
	h->token = token;
	h->opcode = opcode;
}

/*
 * Send one command and wait for the reply with its token: 0, the DSP's status
 * (> 0), or -errno. The reply stays in bsnd_rsp (COPP id, map handle, versions).
 */
static int
apr_send_wait(const char *what, uint8_t svc, uint16_t src_port, uint16_t dest_port,
    uint32_t opcode, const void *payload, uint32_t len, uint32_t timeout_ms, bool quiet)
{
	uint8_t pkt[APR_HDR_SIZE + BSND_MAX_PAYLOAD] __attribute__((aligned(8)));
	uint32_t tok, t;
	uint64_t deadline;

	if (len > BSND_MAX_PAYLOAD) {
		return -EINVAL;
	}
	do {
		tok = ++bsnd_seq & ~BSND_TOK_WRITE;
	} while (tok == 0);
	apr_hdr((struct bsnd_apr_hdr *)pkt, svc, src_port, dest_port, tok, opcode, len);
	if (len != 0) {
		memcpy(pkt + APR_HDR_SIZE, payload, len);
	}

	/* Arm the waiter before sending so a fast reply cannot slip past. */
	__atomic_store_n(&bsnd_rsp.done, 0, __ATOMIC_RELAXED);
	__atomic_store_n(&bsnd_rsp.token, tok, __ATOMIC_RELEASE);
	if (apr_tx(pkt, APR_HDR_SIZE + len) != 0) {
		__atomic_store_n(&bsnd_rsp.token, 0, __ATOMIC_RELEASE);
		printf("BLUE SOUND: %s (op %#x): apr_tx failed\n", what, opcode);
		return -EIO;
	}

	deadline = mach_absolute_time() + ms_abs(timeout_ms);
	while (!__atomic_load_n(&bsnd_rsp.done, __ATOMIC_ACQUIRE)) {
		if (mach_absolute_time() > deadline) {
			/* Withdraw the token. If bsnd_apr_rx already claimed it, the reply is landing: keep waiting. */
			t = tok;
			if (__atomic_compare_exchange_n(&bsnd_rsp.token, &t, 0, false,
			    __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
				if (!quiet) {
					printf("BLUE SOUND: %s (op %#x): no reply in %u ms\n", what, opcode, timeout_ms);
				}
				return -ETIMEDOUT;
			}
		}
		IOSleep(1);
	}

	if (bsnd_rsp.opcode == APR_BASIC_RSP_RESULT && bsnd_rsp.pl[0] != opcode) {
		printf("BLUE SOUND: %s: reply names op %#x, sent %#x\n", what, bsnd_rsp.pl[0], opcode);
	}
	if (bsnd_rsp.status != ADSP_EOK) {
		if (!quiet) {
			printf("BLUE SOUND: %s (op %#x): ADSP %s (%#x)\n", what, opcode,
			    adsp_err(bsnd_rsp.status), bsnd_rsp.status);
		}
		return (int)bsnd_rsp.status;
	}
	return 0;
}

static int
apr_cmd(const char *what, uint8_t svc, uint16_t src_port, uint16_t dest_port,
    uint32_t opcode, const void *payload, uint32_t len)
{
	return apr_send_wait(what, svc, src_port, dest_port, opcode, payload, len, BSND_TIMEOUT_MS, false);
}

/*
 * Set one AFE parameter in-band: service-wide for port 0 (clocks, groups),
 * else on that port. param_size is the exact struct size; for the TDM config
 * stock sends the size of its union of all port configs (q6afe.c
 * afe_tdm_port_start), which only adds unused trailing bytes.
 */
static int
afe_set(const char *what, uint16_t port, uint32_t module_id, uint32_t param_id,
    const void *data, uint16_t size)
{
	uint8_t pl[16 + sizeof(struct bsnd_param_hdr) + sizeof(struct bsnd_group_tdm_cfg)];
	struct bsnd_param_hdr ph = { .module_id = module_id, .param_id = param_id, .param_size = size };
	struct bsnd_afe_svc_cmd sc = { .payload_size = sizeof(ph) + size };
	struct bsnd_afe_port_cmd pc = { .port_id = port, .payload_size = (uint16_t)(sizeof(ph) + size) };

	if (size > sizeof(struct bsnd_group_tdm_cfg)) {
		return -EINVAL;
	}
	if (port != 0) {
		memcpy(pl, &pc, sizeof(pc));
	} else {
		memcpy(pl, &sc, sizeof(sc));
	}
	memcpy(pl + 16, &ph, sizeof(ph));
	memcpy(pl + 16 + sizeof(ph), data, size);
	return apr_cmd(what, APR_SVC_AFE, 0, 0, port != 0 ? AFE_PORT_CMD_SET_PARAM_V2 : AFE_SVC_CMD_SET_PARAM,
	    pl, 16 + sizeof(ph) + size);
}

/* ---- 1. Core ---- */

/* Ask AVCS for the framework version and log it, with each service's API version (ids as in apr.h). */
static int
avcs_version(bool quiet)
{
	uint32_t n, i, words;
	int rc;

	rc = apr_send_wait("AVCS version", APR_SVC_ADSP_CORE, 0, 0, AVCS_CMD_GET_FWK_VERSION, NULL, 0, 200, quiet);
	if (rc != 0) {
		return rc;
	}
	if (bsnd_rsp.opcode != AVCS_CMDRSP_GET_FWK_VERSION || bsnd_rsp.len < 20) {
		return -EPROTO;
	}
	n = bsnd_rsp.pl[4];
	words = bsnd_rsp.len / 4 < 32 ? bsnd_rsp.len / 4 : 32;
	printf("BLUE SOUND: AVS %u.%u.%u.%u, %u services\n", bsnd_rsp.pl[0], bsnd_rsp.pl[1],
	    bsnd_rsp.pl[2], bsnd_rsp.pl[3], n);
	for (i = 0; i < n && 7 + 3 * i < words; i++) {
		printf("BLUE SOUND:   service %#x api %u branch %u\n", bsnd_rsp.pl[5 + 3 * i],
		    bsnd_rsp.pl[6 + 3 * i], bsnd_rsp.pl[7 + 3 * i]);
	}
	return 0;
}

/*
 * The core answers AVCS_CMD_ADSP_EVENT_GET_STATE with 1 once every audio
 * service has registered (q6core.c q6core_is_adsp_ready). Firmware without
 * that query answers EUNSUPPORTED, and mainline then assumes the DSP is up
 * (q6core.c __q6core_is_adsp_ready); we take an answered version query as proof.
 */
int
bsnd_apr_core_ready(unsigned timeout_ms)
{
	uint64_t deadline = mach_absolute_time() + ms_abs(timeout_ms);
	int rc;

	for (;;) {
		rc = apr_send_wait("AVCS state", APR_SVC_ADSP_CORE, 0, 0, AVCS_CMD_ADSP_EVENT_GET_STATE,
		    NULL, 0, 100, true);
		if (rc == 0 && bsnd_rsp.opcode == AVCS_CMDRSP_ADSP_EVENT_GET_STATE && bsnd_rsp.pl[0] != 0) {
			printf("BLUE SOUND: ADSP audio services ready\n");
			avcs_version(false);
			return 0;
		}
		if (rc == (int)ADSP_EUNSUPPORTED && avcs_version(true) == 0) {
			printf("BLUE SOUND: ADSP audio services ready (no state query on this firmware)\n");
			return 0;
		}
		if (mach_absolute_time() > deadline) {
			printf("BLUE SOUND: ADSP audio services not ready after %u ms (last %d)\n", timeout_ms, rc);
			return -ETIMEDOUT;
		}
		IOSleep(50);
	}
}

/* ---- 2. QUAT TDM ---- */

/* Bit clock on or off (msm-dai-q6-v2.c msm_dai_q6_tdm_set_clk); clk_root 0 = default. */
static int
tdm_clock(bool on)
{
	struct bsnd_clk_set clk = {
		.minor_version = 1, .clk_id = Q6AFE_LPASS_CLK_ID_QUAD_TDM_IBIT, .clk_freq_in_hz = TDM_BCLK_HZ,
		.clk_attri = Q6AFE_LPASS_CLK_ATTRIBUTE_INVERT_COUPLE_NO, .clk_root = 0, .enable = on,
	};

	return afe_set(on ? "QUAD_TDM_IBIT on" : "QUAD_TDM_IBIT off", 0,
	    AFE_MODULE_CLOCK_SET, AFE_PARAM_ID_CLOCK_SET, &clk, sizeof(clk));
}

/* Steps 3a/3b; disabling needs only the enable word. num_channels = active slots (apr_audio-v2.h). */
static int
tdm_group(bool on)
{
	struct bsnd_group_tdm_cfg cfg = {
		.minor_version = 1, .group_id = QUAT_TDM_RX_GROUP,
		.port_id = { QUAT_TDM_RX_0, AFE_PORT_INVALID, AFE_PORT_INVALID, AFE_PORT_INVALID,
		    AFE_PORT_INVALID, AFE_PORT_INVALID, AFE_PORT_INVALID, AFE_PORT_INVALID },
		.num_channels = TDM_CHANNELS, .sample_rate = TDM_RATE, .bit_width = TDM_SLOT_BITS,
		.nslots_per_frame = TDM_SLOTS, .slot_width = TDM_SLOT_BITS, .slot_mask = TDM_SLOT_MASK,
	};
	struct bsnd_pair16 en = { .id = QUAT_TDM_RX_GROUP, .value = on };
	int rc;

	if (on) {
		rc = afe_set("TDM group config", 0, AFE_MODULE_GROUP_DEVICE,
		    AFE_PARAM_ID_GROUP_DEVICE_TDM_CONFIG, &cfg, sizeof(cfg));
		if (rc != 0) {
			return rc;
		}
	}
	rc = afe_set(on ? "TDM group enable" : "TDM group disable", 0, AFE_MODULE_GROUP_DEVICE,
	    AFE_PARAM_ID_GROUP_DEVICE_ENABLE, &en, sizeof(en));
	bsnd.group_up = on && rc == 0;
	return rc;
}

int
bsnd_apr_tdm_start(void)
{
	/* Values from the stock DT; (dtbo) marks the dtbo 8 overrides of the base node. */
	struct bsnd_tdm_cfg tdm = {
		.minor_version = 1,
		.num_channels = TDM_CHANNELS, .sample_rate = TDM_RATE,
		.bit_width = TDM_SLOT_BITS,		/* S32_LE (mixer_paths "QUAT_TDM_RX_0 Format") */
		.data_format = 0,			/* AFE_LINEAR_PCM_DATA */
		.sync_mode = 0,				/* AFE_PORT_TDM_SHORT_SYNC_BIT_MODE: sync-mode 0 (dtbo) */
		.sync_src = 1,				/* AFE_PORT_TDM_SYNC_SRC_INTERNAL: sync-src 1 */
		.nslots_per_frame = TDM_SLOTS,
		.ctrl_data_out_enable = 0,		/* AFE_PORT_TDM_CTRL_DATA_OE_DISABLE: data-out 0 */
		.ctrl_invert_sync_pulse = 0,		/* AFE_PORT_TDM_SYNC_NORMAL: invert-sync 0 (dtbo) */
		.ctrl_sync_data_delay = 1,		/* AFE_PORT_TDM_DATA_DELAY_1_BCLK_CYCLE: data-delay 1 */
		.slot_width = TDM_SLOT_BITS, .slot_mask = TDM_SLOT_MASK,
	};
	struct bsnd_slot_map map = {
		.minor_version = 1, .num_channel = TDM_CHANNELS, .bitwidth = TDM_SLOT_BITS,
		.data_align_type = 0,			/* AFE_SLOT_MAPPING_DATA_ALIGN_MSB: data-align 0 */
		.offset = { 0, 4, AFE_PORT_INVALID, AFE_PORT_INVALID, AFE_PORT_INVALID,
		    AFE_PORT_INVALID, AFE_PORT_INVALID, AFE_PORT_INVALID },
	};
	struct bsnd_pair16 start = { .id = QUAT_TDM_RX_0 };
	int rc;

	if (bsnd.tdm_up) {
		return 0;
	}

	/* 1. LPASS makes the 12.288 MHz bit clock for QUAT; the SoC is clock and frame master. */
	rc = tdm_clock(true);
	if (rc != 0) {
		return rc;
	}

	/* 2. Optionally, the group around the port (off by default, as stock). */
	if (bsnd_tdm_group && (rc = tdm_group(true)) != 0) {
		goto clock_off;
	}

	/* 3. The port's frame: 8 slots of 32 bits, our two channels in slots 0 and 1. No custom TDM header. */
	rc = afe_set("TDM port config", QUAT_TDM_RX_0, AFE_MODULE_AUDIO_DEV_INTERFACE,
	    AFE_PARAM_ID_TDM_CONFIG, &tdm, sizeof(tdm));
	if (rc != 0) {
		goto group_off;
	}

	/* 4. Where in the frame each channel goes (byte offsets). */
	rc = afe_set("TDM slot map", QUAT_TDM_RX_0, AFE_MODULE_TDM,
	    AFE_PARAM_ID_PORT_SLOT_MAPPING_CONFIG, &map, sizeof(map));
	if (rc != 0) {
		goto group_off;
	}

	/* 5. Start the port: clocks and frame sync run, the slots carry zeros until a stream feeds them. */
	rc = apr_cmd("AFE start QUAT_TDM_RX_0", APR_SVC_AFE, 0, 0, AFE_PORT_CMD_DEVICE_START,
	    &start, sizeof(start));
	if (rc != 0) {
		goto group_off;
	}
	bsnd.tdm_up = true;
	printf("BLUE SOUND: QUAT_TDM_RX_0 up: %u Hz, %u of %u x %u-bit slots, bit clock %u Hz\n",
	    TDM_RATE, TDM_CHANNELS, TDM_SLOTS, TDM_SLOT_BITS, TDM_BCLK_HZ);
	return 0;

group_off:
	if (bsnd.group_up) {
		tdm_group(false);
	}
clock_off:
	tdm_clock(false);
	return rc;
}

int
bsnd_apr_tdm_stop(void)
{
	struct bsnd_pair16 stop = { .id = QUAT_TDM_RX_0 };
	int rc;

	if (!bsnd.tdm_up) {
		return 0;
	}
	/* Port, then group, then clock (msm-dai-q6-v2.c msm_dai_q6_tdm_shutdown order). */
	rc = apr_cmd("AFE stop QUAT_TDM_RX_0", APR_SVC_AFE, 0, 0, AFE_PORT_CMD_DEVICE_STOP, &stop, sizeof(stop));
	if (bsnd.group_up) {
		tdm_group(false);
	}
	tdm_clock(false);
	bsnd.tdm_up = false;
	return rc;
}

/* ---- 3. Stream ---- */

int
bsnd_apr_stream_open(void)
{
	struct bsnd_mem_map mm = {
		.mem_pool_id = ADSP_MEMORY_MAP_SHMEM8_4K_POOL, .num_regions = 1, .property_flag = 0,
		.shm_addr_lsw = (uint32_t)bsnd_shm_pa, .shm_addr_msw = (uint32_t)(bsnd_shm_pa >> 32),
		.mem_size_bytes = bsnd_shm_size,
	};
	struct bsnd_open_write ow = {
		.mode_flags = 0,			/* ASM_LEGACY_STREAM_SESSION */
		.sink_endpointype = 0,			/* ASM_END_POINT_DEVICE_MATRIX */
		.bits_per_sample = 16,
		.postprocopo_id = ASM_STREAM_POSTPROCOPO_ID_NONE, .dec_fmt_id = ASM_MEDIA_FMT_MULTI_CHANNEL_PCM_V2,
	};
	struct bsnd_adm_open ao = {
		.flags = 0,				/* ADM_LEGACY_DEVICE_SESSION */
		.mode_of_operation = ADM_CMD_COPP_OPEN_MODE_OF_OPERATION_RX_PATH_COPP,
		.endpoint_id_1 = QUAT_TDM_RX_0, .endpoint_id_2 = ADM_CMD_COPP_OPEN_END_POINT_ID_2_IGNORE,
		.topology_id = NULL_COPP_TOPOLOGY,
		.dev_num_channel = TDM_CHANNELS, .bit_width = BSND_ADM_BITS, .sample_rate = TDM_RATE,
		.dev_channel_mapping = { PCM_CHANNEL_FL, PCM_CHANNEL_FR },
	};
	struct bsnd_adm_map map = {
		.matrix_id = ADM_MATRIX_ID_AUDIO_RX, .num_sessions = 1, .session_id = ASM_SESSION, .num_copps = 1,
	};
	struct bsnd_media_fmt fmt = {
		.fmt_blk_size = sizeof(struct bsnd_media_fmt) - 4,
		.num_channels = 2, .bits_per_sample = 16, .sample_rate = TDM_RATE, .is_signed = 1,
		.channel_mapping = { PCM_CHANNEL_FL, PCM_CHANNEL_FR },
	};
	uint32_t run[3] = { 0, 0, 0 };	/* asm_session_cmd_run_v2: ASM_SESSION_CMD_RUN_STARTIME_RUN_IMMEDIATE, time 0 */
	int rc;

	if (bsnd.stream_open || bsnd.mem_handle != 0) {
		return -EBUSY;
	}
	if (!bsnd.tdm_up) {
		printf("BLUE SOUND: stream open before the TDM port is up\n");
		return -ENXIO;
	}
	if ((bsnd_shm_pa & 0xFFFu) != 0 || bsnd_shm_size == 0 || (bsnd_shm_size & 0xFFFu) != 0) {
		printf("BLUE SOUND: shm %#llx+%#x must be 4 KiB aligned and sized\n",
		    (unsigned long long)bsnd_shm_pa, bsnd_shm_size);
		return -EINVAL;
	}

	/* 1. Map the PCM buffer into the DSP; writes then name regions of it by handle and address. */
	rc = apr_cmd("ASM map shm", APR_SVC_ASM, 0, 0, ASM_CMD_SHARED_MEM_MAP_REGIONS, &mm, sizeof(mm));
	if (rc == 0 && (bsnd_rsp.opcode != ASM_CMDRSP_SHARED_MEM_MAP_REGIONS || bsnd_rsp.pl[0] == 0)) {
		printf("BLUE SOUND: ASM map shm: reply op %#x, handle %#x\n", bsnd_rsp.opcode, bsnd_rsp.pl[0]);
		rc = -EPROTO;
	}
	if (rc != 0) {
		return rc;
	}
	bsnd.mem_handle = bsnd_rsp.pl[0];

	/* 2. ASM session 1: a PCM "decoder" feeding the ADM matrix. No post-processing, so no calibration. */
	rc = apr_cmd("ASM open write", APR_SVC_ASM, ASM_PORT, ASM_PORT, ASM_STREAM_CMD_OPEN_WRITE_V3, &ow, sizeof(ow));
	if (rc != 0) {
		goto fail;
	}
	bsnd.stream_open = true;

	/*
	 * 3. A COPP on QUAT_TDM_RX_0 with NULL_COPP_TOPOLOGY, a built-in pass-through:
	 * stock opens it when ACDB has no topology for the device (msm-pcm-routing-v2.c
	 * msm_routing_get_adm_topology); mainline q6routing.c always does.
	 */
	rc = apr_cmd("ADM open", APR_SVC_ADM, QUAT_TDM_RX_0, QUAT_TDM_RX_0, ADM_CMD_DEVICE_OPEN_V5, &ao, sizeof(ao));
	if (rc == 0 && (bsnd_rsp.opcode != ADM_CMDRSP_DEVICE_OPEN_V5 || bsnd_rsp.len < 8 ||
	    (bsnd_rsp.pl[1] & 0xFFFFu) >= INVALID_COPP_ID)) {
		printf("BLUE SOUND: ADM open: reply op %#x, copp %#x\n", bsnd_rsp.opcode, bsnd_rsp.pl[1] & 0xFFFFu);
		rc = -EPROTO;
	}
	if (rc != 0) {
		goto fail;
	}
	bsnd.copp_id = (uint16_t)(bsnd_rsp.pl[1] & 0xFFFFu);

	/* 4. Route session 1 into that COPP through the Audio Rx matrix. */
	map.copp_id = bsnd.copp_id;
	rc = apr_cmd("ADM matrix map", APR_SVC_ADM, 0, 0, ADM_CMD_MATRIX_MAP_ROUTINGS_V5, &map, sizeof(map));
	if (rc != 0) {
		goto fail;
	}

	/* 5. What the buffers hold: interleaved signed 16-bit L/R at 48 kHz. */
	rc = apr_cmd("ASM media format", APR_SVC_ASM, ASM_PORT, ASM_PORT, ASM_DATA_CMD_MEDIA_FMT_UPDATE_V2,
	    &fmt, sizeof(fmt));
	if (rc != 0) {
		goto fail;
	}

	/* 6. Run now. Until the first write the session renders silence and reports underflows. */
	bsnd.underflows = 0;
	rc = apr_cmd("ASM run", APR_SVC_ASM, ASM_PORT, ASM_PORT, ASM_SESSION_CMD_RUN_V2, run, sizeof(run));
	if (rc != 0) {
		goto fail;
	}
	bsnd.running = true;
	printf("BLUE SOUND: stream running: ASM session %u -> COPP %u -> QUAT_TDM_RX_0, shm handle %#x\n",
	    ASM_SESSION, bsnd.copp_id, bsnd.mem_handle);
	return 0;

fail:
	bsnd_apr_stream_close();
	return rc;
}

int
bsnd_apr_stream_close(void)
{
	uint32_t handle, i, busy;
	uint64_t deadline;
	int rc = 0, r;

	/* Refuse new writes, then let the queued ones play out. */
	if (bsnd.running) {
		bsnd.running = false;
		deadline = mach_absolute_time() + ms_abs(500);
		while (bsnd_apr_writes_in_flight() != 0 && mach_absolute_time() < deadline) {
			IOSleep(5);
		}
	}

	/* Session, then the COPP it fed, then the memory (stock order). Closing hands back unplayed writes. */
	if (bsnd.stream_open) {
		r = apr_cmd("ASM close", APR_SVC_ASM, ASM_PORT, ASM_PORT, ASM_STREAM_CMD_CLOSE, NULL, 0);
		rc = rc ? rc : r;
		bsnd.stream_open = false;
	}
	if (bsnd.copp_id != BSND_NO_COPP) {
		r = apr_cmd("ADM close", APR_SVC_ADM, QUAT_TDM_RX_0, bsnd.copp_id, ADM_CMD_DEVICE_CLOSE_V5, NULL, 0);
		rc = rc ? rc : r;
		bsnd.copp_id = BSND_NO_COPP;
	}
	if (bsnd.mem_handle != 0) {
		handle = bsnd.mem_handle;
		r = apr_cmd("ASM unmap shm", APR_SVC_ASM, 0, 0, ASM_CMD_SHARED_MEM_UNMAP_REGIONS, &handle, sizeof(handle));
		rc = rc ? rc : r;
		bsnd.mem_handle = 0;
	}

	/* Forget writes that never came back; whoever wins a slot's claim drops the count. */
	for (i = 0; i < BSND_WR_SLOTS; i++) {
		busy = 1;
		if (__atomic_compare_exchange_n(&bsnd_wr[i].busy, &busy, 0, false,
		    __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
			__atomic_fetch_sub(&bsnd_wr_inflight, 1, __ATOMIC_RELEASE);
		}
	}
	if (bsnd.underflows != 0) {
		printf("BLUE SOUND: stream closed after %u underflows\n", bsnd.underflows);
	}
	return rc;
}

/* ---- 4. Data ---- */

void
bsnd_apr_set_write_done(bsnd_write_done_fn fn)
{
	__atomic_store_n(&bsnd_wr_cb, fn, __ATOMIC_RELEASE);
}

uint32_t
bsnd_apr_writes_in_flight(void)
{
	return __atomic_load_n(&bsnd_wr_inflight, __ATOMIC_ACQUIRE);
}

int
bsnd_apr_write(uint32_t off, uint32_t len)
{
	struct {
		struct bsnd_apr_hdr h;
		struct bsnd_write w;
	} __attribute__((packed)) pkt;
	uint64_t addr = bsnd_shm_pa + off;
	uint32_t slot, idle;

	if (!bsnd.running) {
		return -ENXIO;
	}
	if (len == 0 || (len % BSND_FRAME_BYTES) != 0 || off > bsnd_shm_size || len > bsnd_shm_size - off ||
	    (addr & 31u) != 0) {
		printf("BLUE SOUND: bad write %#x+%#x (whole frames, 32-byte aligned, inside shm)\n", off, len);
		return -EINVAL;
	}

	/* Claim a free slot; its index rides in the token so the write-done finds (off, len) again. */
	for (slot = 0; slot < BSND_WR_SLOTS; slot++) {
		idle = 0;
		if (__atomic_compare_exchange_n(&bsnd_wr[slot].busy, &idle, 1, false,
		    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
			break;
		}
	}
	if (slot == BSND_WR_SLOTS) {
		return -EBUSY;
	}
	bsnd_wr[slot].off = off;
	bsnd_wr[slot].len = len;
	__atomic_fetch_add(&bsnd_wr_inflight, 1, __ATOMIC_RELEASE);

	/* No timestamp (flags 0): the DSP plays it right after the previous buffer. */
	apr_hdr(&pkt.h, APR_SVC_ASM, ASM_PORT, ASM_PORT, BSND_TOK_WRITE | slot, ASM_DATA_CMD_WRITE_V2, sizeof(pkt.w));
	pkt.w = (struct bsnd_write){
		.buf_addr_lsw = (uint32_t)addr, .buf_addr_msw = (uint32_t)(addr >> 32),
		.mem_map_handle = bsnd.mem_handle, .buf_size = len, .seq_id = slot,
	};
	if (apr_tx(&pkt, sizeof(pkt)) != 0) {
		__atomic_fetch_sub(&bsnd_wr_inflight, 1, __ATOMIC_RELEASE);
		__atomic_store_n(&bsnd_wr[slot].busy, 0, __ATOMIC_RELEASE);
		return -EIO;
	}
	return 0;
}

/* A write came back, played or not: free its slot, then hand the region back to the owner. */
static void
write_done(uint32_t slot, uint32_t status)
{
	bsnd_write_done_fn cb;
	uint32_t off, len, busy = 1;

	if (slot >= BSND_WR_SLOTS) {
		return;
	}
	off = bsnd_wr[slot].off;
	len = bsnd_wr[slot].len;
	if (!__atomic_compare_exchange_n(&bsnd_wr[slot].busy, &busy, 0, false,
	    __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
		return;		/* already returned, or forgotten by stream_close */
	}
	__atomic_fetch_sub(&bsnd_wr_inflight, 1, __ATOMIC_RELEASE);
	if (status != ADSP_EOK) {
		printf("BLUE SOUND: write %#x+%#x: ADSP %s (%#x)\n", off, len, adsp_err(status), status);
	}
	cb = __atomic_load_n(&bsnd_wr_cb, __ATOMIC_ACQUIRE);
	if (cb != NULL) {
		cb(off, len, status);
	}
}

/* ---- 5. Receive ---- */

void
bsnd_apr_rx(const void *pkt, uint32_t len)
{
	struct bsnd_apr_hdr h;
	uint32_t pl[32];
	uint32_t hlen, plen, status, want;

	if (pkt == NULL || len < APR_HDR_SIZE) {
		return;
	}
	memcpy(&h, pkt, sizeof(h));
	hlen = ((h.hdr_field >> 4) & 0xFu) * 4;		/* header length in words, as apr.c apr_cb_func reads it */
	if (hlen < APR_HDR_SIZE || h.pkt_size < hlen || h.pkt_size > len) {
		printf("BLUE SOUND: bad APR packet (field %#x, size %u of %u)\n", h.hdr_field, h.pkt_size, len);
		return;
	}
	plen = h.pkt_size - hlen;
	memset(pl, 0, sizeof(pl));
	memcpy(pl, (const uint8_t *)pkt + hlen, plen < sizeof(pl) ? plen : sizeof(pl));

	switch (h.opcode) {
	case ASM_DATA_EVENT_WRITE_DONE_V2:
		/* {buf_addr_lsw, buf_addr_msw, mem_map_handle, status} */
		write_done(h.token & ~BSND_TOK_WRITE, plen >= 16 ? pl[3] : ADSP_EFAILED);
		return;
	case ASM_SESSION_EVENT_RX_UNDERFLOW:
		/* The DSP wanted data and none was queued; log the first and every 256th. */
		if ((bsnd.underflows++ & 0xFFu) == 0) {
			printf("BLUE SOUND: ASM underflow (%u so far)\n", bsnd.underflows);
		}
		return;
	case APR_RSP_ACCEPTED:
		return;
	case APR_BASIC_RSP_RESULT:
		/* {opcode, status}. With a write token: a buffer handed back unplayed, on close
		 * (mainline q6asm.c q6asm_stream_callback) or because the DSP refused it. */
		status = plen >= 8 ? pl[1] : ADSP_EFAILED;
		if (h.token & BSND_TOK_WRITE) {
			write_done(h.token & ~BSND_TOK_WRITE, status != ADSP_EOK ? status : ADSP_EABORTED);
			return;
		}
		break;
	case ADM_CMDRSP_DEVICE_OPEN_V5:
		/* {status, copp_id, reserved} */
		status = plen >= 4 ? pl[0] : ADSP_EFAILED;
		break;
	default:
		/* Replies that carry data (map handle, AVCS state, version) have no status field. */
		status = ADSP_EOK;
		break;
	}

	/* Hand the reply to the waiting command if the token is the one it armed. */
	want = h.token;
	if (want == 0 || !__atomic_compare_exchange_n(&bsnd_rsp.token, &want, 0, false,
	    __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
		printf("BLUE SOUND: unclaimed APR op %#x token %#x from svc %u port %#x (status %#x)\n",
		    h.opcode, h.token, h.src_svc, h.src_port, status);
		return;
	}
	bsnd_rsp.opcode = h.opcode;
	bsnd_rsp.status = status;
	bsnd_rsp.len = plen;
	memcpy(bsnd_rsp.pl, pl, sizeof(pl));
	__atomic_store_n(&bsnd_rsp.done, 1, __ATOMIC_RELEASE);
}

#endif /* ARM64_BOARD_CONFIG_SWEET */
