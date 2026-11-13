/* hddsrv_core.h -- the A1200 hard disk's host side (ATA command set over hdd_spi.vhd), own code.
 * Shared by the server on the Linux module (hddsrv_linux.c) and the Verilator bench (K325T/sim/aga). */
#ifndef HDDSRV_CORE_H
#define HDDSRV_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* one SPI transaction of a batch; CS goes high after it (after delay_us with CS still low) */
struct hdd_seg {
    const uint8_t *tx;
    uint8_t *rx;
    uint16_t len, delay_us;
};
/* spidev's default bufsiz (4096) limits the bytes of one batch per direction, and it counts each
   transfer rounded up to the DMA alignment (ARCH_KMALLOC_MINALIGN = 128 on arm64): a 5-byte STATUS
   costs 128.  rx = NULL / tx = NULL: that direction is not needed (no bounce buffer used). */
#define HDD_BATCH_BYTES 4096
#define HDD_BATCH_ALIGN 128
#define HDD_AL(n) (((n) + HDD_BATCH_ALIGN - 1) / HDD_BATCH_ALIGN * HDD_BATCH_ALIGN)

struct hdd_io {
    /* one SPI transaction (CS low .. high), len bytes out and in; returns 0 or -1 */
    int (*xfer)(void *ctx, const uint8_t *tx, uint8_t *rx, int len);
    /* optional: n transactions in one go (one system call); NULL = one xfer each, delays ignored
       (the core checks every result, so a delay only buys speed, never correctness) */
    int (*xfer_batch)(void *ctx, const struct hdd_seg *seg, int n);
    /* wait until the attention line is high or timeout_ms passed; returns 1 high, 0 timeout, -1 error */
    int (*wait_att)(void *ctx, int timeout_ms);
    /* the disk image: whole 512-byte sectors; return 0 or -1 */
    int (*rd)(void *ctx, uint64_t lba, unsigned n, uint8_t *buf);
    int (*wr)(void *ctx, uint64_t lba, unsigned n, const uint8_t *buf);
    void (*log)(void *ctx, const char *msg);
    /* optional: keep / fetch a small state record that survives a restart of the server (RAM:
       a tmpfs file), so a server that died inside a read data phase resumes it transparently */
    void (*persist)(void *ctx, const void *rec, int len);
    int (*restore)(void *ctx, void *rec, int len);     /* 0 = got one */
    void *ctx;
};

/* a READ or WRITE in its data phase: a restarted server resumes it (a read: the CPU may wait inside
   the block in fast mode; a write: the CPU may still be filling the block -- a status written now
   would end its DRQ and the block would be lost without an error) */
struct hdd_inflight {
    uint32_t magic;                 /* HDD_INFLIGHT_MAGIC while a data phase is in progress */
    uint32_t phase;                 /* 1 block i about to be armed, 2 its DRQ status written */
    uint64_t lba, nblk;
    uint32_t total, block, i, n, fast, write;
};
#define HDD_INFLIGHT_MAGIC 0x48444452u

struct hdd {
    struct hdd_io io;
    uint64_t nblk;          /* image size in sectors */
    int ro;                 /* read-only: writes fail with an error to the Amiga */
    unsigned cyls, heads, spt;          /* the default geometry (16 x 63) */
    unsigned cur_heads, cur_spt;        /* INITIALIZE DEVICE PARAMETERS */
    unsigned multiple;                  /* SET MULTIPLE MODE (sectors per block for xx MULTIPLE) */
    int verbose;
    int fast;               /* reads in ide.v's fast mode (DRQ first, data streamed; the CPU waits) */
    /* statistics */
    uint64_t cmds, rd_sect, wr_sect, errors, resets, timeouts, links_lost;
    uint64_t batch_retries;             /* a batched step found the engine still busy and resumed */
    uint64_t resumes;                   /* reads resumed after a server restart */
    struct hdd_inflight inflight;
    int resume, resume_ph;              /* hdd_init found an in-flight data phase to resume (1, 2, 3) */
    int batch;                          /* use batches (default 1; 0 = the old one-step-per-call path) */
    int delay_cut;                      /* tests: batch delays shortened by this many percent (0..100) */
};

#define HDD_MAX_MULTIPLE 16

int  hdd_init(struct hdd *h);       /* geometry from nblk, drive present, ready status */
/* serve: handle requests until *stop becomes non-zero; returns 0, or -1 on a link error */
int  hdd_serve(struct hdd *h, volatile int *stop);
/* one round: wait up to timeout_ms for a request and handle it; 1 handled, 0 nothing, -1 error */
int  hdd_poll(struct hdd *h, int timeout_ms);
/* link test helpers (used by the server's --linktest) */
int  hdd_status(struct hdd *h, uint8_t *flags, uint16_t *result);
int  hdd_put(struct hdd *h, const uint8_t *amiga512);
int  hdd_get(struct hdd *h, uint8_t *amiga512);
/* n sectors into / out of ide.v's buffer from its current pointer, batched (PUT+COMMIT / FETCH+GET) */
int  hdd_put_n(struct hdd *h, const uint8_t *amiga, unsigned n);
int  hdd_get_n(struct hdd *h, uint8_t *amiga, unsigned n);
int  hdd_engine(struct hdd *h, uint8_t cmd, int has_data, uint16_t data, uint16_t *result);

#ifdef __cplusplus
}
#endif
#endif
