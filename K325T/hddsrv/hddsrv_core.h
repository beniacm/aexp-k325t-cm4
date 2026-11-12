/* hddsrv_core.h -- the A1200 hard disk's host side (ATA command set over hdd_spi.vhd), own code.
 * Shared by the server on the Linux module (hddsrv_linux.c) and the Verilator bench (K325T/sim/aga). */
#ifndef HDDSRV_CORE_H
#define HDDSRV_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

struct hdd_io {
    /* one SPI transaction (CS low .. high), len bytes out and in; returns 0 or -1 */
    int (*xfer)(void *ctx, const uint8_t *tx, uint8_t *rx, int len);
    /* wait until the attention line is high or timeout_ms passed; returns 1 high, 0 timeout, -1 error */
    int (*wait_att)(void *ctx, int timeout_ms);
    /* the disk image: whole 512-byte sectors; return 0 or -1 */
    int (*rd)(void *ctx, uint64_t lba, unsigned n, uint8_t *buf);
    int (*wr)(void *ctx, uint64_t lba, unsigned n, const uint8_t *buf);
    void (*log)(void *ctx, const char *msg);
    void *ctx;
};

struct hdd {
    struct hdd_io io;
    uint64_t nblk;          /* image size in sectors */
    int ro;                 /* read-only: writes fail with an error to the Amiga */
    unsigned cyls, heads, spt;          /* the default geometry (16 x 63) */
    unsigned cur_heads, cur_spt;        /* INITIALIZE DEVICE PARAMETERS */
    unsigned multiple;                  /* SET MULTIPLE MODE (sectors per block for xx MULTIPLE) */
    int verbose;
    /* statistics */
    uint64_t cmds, rd_sect, wr_sect, errors, resets, timeouts;
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
int  hdd_engine(struct hdd *h, uint8_t cmd, int has_data, uint16_t data, uint16_t *result);

#ifdef __cplusplus
}
#endif
#endif
