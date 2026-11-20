/*
 * Pixel 3 (blueline) speaker: PCM to QUAT_TDM_RX_0 through the stock ADSP's
 * Elite audio services (AVCS, AFE, ADM, ASM) over APR. See blueline_audio_apr.c
 * for the command sequence and every id.
 *
 * Call order:
 *   bsnd_apr_core_ready(3000)      ADSP audio framework is up
 *   bsnd_apr_tdm_start()           bit clock + TDM port running (sends zeros)
 *   bsnd_apr_set_write_done(fn)    optional, before the first write
 *   bsnd_apr_stream_open()         ASM session -> ADM COPP -> QUAT_TDM_RX_0, running
 *   bsnd_apr_write(off, len) ...   queue regions of bsnd_shm; fn() hands each back
 *   bsnd_apr_stream_close()
 *   bsnd_apr_tdm_stop()
 *
 * Return values: 0 on success, a positive ADSP status (ADSP_EBADPARAM = 2,
 * ADSP_EUNSUPPORTED = 3, ...) when the DSP refused a command, or a negative
 * errno (-ETIMEDOUT, -EIO from apr_tx, -EINVAL, -EBUSY, -ENXIO).
 *
 * Threads: the control calls (everything but bsnd_apr_write) wait for their
 * reply and must come from one thread at a time, never from the thread that
 * calls bsnd_apr_rx(). bsnd_apr_write() does not wait and may run on its own
 * thread, but must stop before bsnd_apr_stream_close() starts; the write-done
 * callback runs on the bsnd_apr_rx() thread and must not block.
 *
 * Before bsnd_apr_tdm_start() the apps side must mux the QUAT TDM pins (the
 * ADSP does not touch TLMM): GPIO 58 (bit clock) and 59 (frame sync) to
 * function 1 "qua_mi2s", 8 mA, no pull; GPIO 61 (data out) and 60 (data in)
 * to function 1, 2 mA, no pull (stock DT quat_tdm_active, quat_tdm_dout_active,
 * quat_tdm_din_active).
 */
#ifndef _BLUELINE_AUDIO_APR_H_
#define _BLUELINE_AUDIO_APR_H_

#if defined(ARM64_BOARD_CONFIG_SWEET)

#include <sys/types.h>
#include <stdbool.h>

/* ---- Provided by the GLINK "apr_audio_svc" transport ---- */

/* Queue one APR packet (header included); 0 = queued. The bytes are copied before it returns. */
int apr_tx(const void *pkt, uint32_t len);

/*
 * The PCM buffer: physically contiguous, uncached, 4 KiB aligned, size a
 * multiple of 4 KiB (ADSP_MEMORY_MAP_SHMEM8_4K_POOL rule). bsnd_shm_pa is the
 * address as the ADSP sees it. With the stock SMMU setup that is the IOVA in
 * the apps SMMU context bank of stream 0x1821 with the stream id's low 4 bits
 * in bits 32-35, i.e. iova | (1ull << 32) (msm_audio_ion.c
 * msm_audio_ion_get_phys: "Append the SMMU SID information to the IOVA";
 * mainline q6asm-dai.c: addr | (sid << 32), sid = 0x1821 & 0xf).
 */
extern uint64_t bsnd_shm_pa;
extern uint8_t *bsnd_shm_va;
extern uint32_t bsnd_shm_size;

/* ---- This file's API ---- */

/* Poll the AVCS core until it reports the audio services up; logs the AVS version. */
int bsnd_apr_core_ready(unsigned timeout_ms);

/* QUAT TDM bit clock on, port configured and started; and back down. */
int bsnd_apr_tdm_start(void);
int bsnd_apr_tdm_stop(void);

/*
 * Map bsnd_shm, open ASM session 1 (PCM, 48 kHz, 2 ch, 16-bit interleaved
 * little-endian) and an ADM COPP on QUAT_TDM_RX_0, route one to the other,
 * and start the session. stream_close waits up to 500 ms for queued writes
 * to come back, then closes everything stream_open set up.
 */
int bsnd_apr_stream_open(void);
int bsnd_apr_stream_close(void);

/*
 * Queue bsnd_shm[off, off + len) for playback: len a multiple of 4 (one
 * stereo 16-bit frame), bsnd_shm_pa + off 32-byte aligned. At most 16 writes
 * in flight (-EBUSY beyond). The region belongs to the DSP until the
 * write-done callback returns it with status 0 (ADSP_EOK) or an ADSP error.
 */
typedef void (*bsnd_write_done_fn)(uint32_t off, uint32_t len, uint32_t status);
void bsnd_apr_set_write_done(bsnd_write_done_fn fn);
int bsnd_apr_write(uint32_t off, uint32_t len);
uint32_t bsnd_apr_writes_in_flight(void);

/* Called by the transport's polling thread for each received APR packet. */
void bsnd_apr_rx(const void *pkt, uint32_t len);

#endif /* ARM64_BOARD_CONFIG_SWEET */
#endif /* _BLUELINE_AUDIO_APR_H_ */
