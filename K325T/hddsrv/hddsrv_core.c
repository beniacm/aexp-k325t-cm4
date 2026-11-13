/* hddsrv_core.c -- the A1200 hard disk's host side, own code (K325T, branch a1200-ide).
 *
 * Gayle's IDE unit (MiSTer's ide.v, reached through hdd_spi.vhd) has the task file, the status and a
 * 16-sector buffer, but no command logic: on a command it raises request 100, after the CPU has read
 * or written a data block 101, after a reset 110; this file answers.  The mgmt registers (ide.v):
 *   0  write: error (15:8), block size in sectors (7:0) | read: features, ...
 *   1  read: sector number (15:8), sector count (7:0)
 *   2  read: cylinder (15:0)
 *   3  read: the HOB copies of sector / count (LBA48; unused here)
 *   5  write: status {BSY 15, DRDY 14, 13 fast read, DSC 12, DRQ 11, irq 10, last block 9, ERR 8}
 *      (clears the request) | read: command (15:8), drive/head (7:0)
 *   6  write: drive present (bit 3 = set, bit 0 = present, bit 1 = LBA48)
 *   15 the sector buffer (pointer reset by PTR0, advanced by every word)
 * Byte order: the Amiga reads a buffer word byte-swapped (gayle.v), so a word holds bytes 2i | 2i+1 << 8
 * of the sector as the Amiga sees it (an HDF file is in the Amiga's order); hdd_put / hdd_get convert.
 * Not derived from Main_MiSTer: register semantics from ide.v, behaviour from the ATA-2 spec.
 */
#include <stdio.h>
#include <string.h>
#include "hddsrv_core.h"

#define ST_BSY  (1u << 15)
#define ST_DRDY (1u << 14)
#define ST_FAST (1u << 13)   /* ide.v fast read: DRQ before the data, the CPU waits (Gayle nrdy) */
#define ST_DSC  (1u << 12)
#define ST_DRQ  (1u << 11)
#define ST_IRQ  (1u << 10)
#define ST_LAST (1u << 9)
#define ST_ERR  (1u << 8)

#define ER_ABRT 0x04
#define ER_IDNF 0x10
#define ER_UNC  0x40

static void lg(struct hdd *h, const char *fmt, unsigned a, unsigned b, unsigned c, unsigned d)
{
    char m[200];
    if (!h->io.log) return;
    snprintf(m, sizeof m, fmt, a, b, c, d);
    h->io.log(h->io.ctx, m);
}

int hdd_status(struct hdd *h, uint8_t *flags, uint16_t *result)
{
    uint8_t tx[5] = {0}, rx[5];
    if (h->io.xfer(h->io.ctx, tx, rx, 5)) return -1;
    if (rx[1] != 0xA1) {
        if (h->verbose > 1) lg(h, "STATUS answer %02x %02x %02x %02x", rx[1], rx[2], rx[3], rx[4]);
        return -1;
    }
    if (flags) *flags = rx[2];
    if (result) *result = (uint16_t)(rx[3] << 8 | rx[4]);
    return 0;
}

/* an engine command (REGRD 0x1a, REGWR 0x2a + data, COMMIT 0x31, PTR0 0x32, FETCH 0x40); waits for it */
int hdd_engine(struct hdd *h, uint8_t cmd, int has_data, uint16_t data, uint16_t *result)
{
    uint8_t tx[3] = {cmd, (uint8_t)(data >> 8), (uint8_t)data}, rx[3], fl;
    uint16_t res;
    int i;
    if (h->io.xfer(h->io.ctx, tx, rx, has_data ? 3 : 1)) return -1;
    for (i = 0; i < 100000; i++) {
        if (hdd_status(h, &fl, &res)) return -1;
        if (!(fl & 0x80) && (fl & 0x40)) {
            if (result) *result = res;
            return res == 0xDEAD ? -2 : 0;    /* -2: an Amiga reset ended the command */
        }
    }
    h->timeouts++;
    return -1;
}

/* an engine error: -1 link, -2 the Amiga is in reset (result x"DEAD"): passed up unchanged */
#define TRY(x) do { int rc_ = (x); if (rc_) return rc_; } while (0)


static int regwr(struct hdd *h, unsigned a, uint16_t v)  { return hdd_engine(h, 0x20 | a, 1, v, 0); }
static int ptr0(struct hdd *h)                           { return hdd_engine(h, 0x32, 0, 0, 0); }

int hdd_put(struct hdd *h, const uint8_t *s)
{
    uint8_t tx[513], rx[513];
    int i;
    tx[0] = 0x30;
    for (i = 0; i < 256; i++) {               /* word = s[2i] | s[2i+1] << 8, high byte sent first */
        tx[1 + 2 * i] = s[2 * i + 1];
        tx[2 + 2 * i] = s[2 * i];
    }
    if (h->io.xfer(h->io.ctx, tx, rx, 513)) return -1;
    return hdd_engine(h, 0x31, 0, 0, 0);
}

int hdd_get(struct hdd *h, uint8_t *s)
{
    uint8_t tx[513], rx[513];
    int i, r = hdd_engine(h, 0x40, 0, 0, 0);
    if (r) return r;
    memset(tx, 0, sizeof tx);
    tx[0] = 0x41;
    if (h->io.xfer(h->io.ctx, tx, rx, 513)) return -1;
    for (i = 0; i < 256; i++) {
        s[2 * i + 1] = rx[1 + 2 * i];
        s[2 * i] = rx[2 + 2 * i];
    }
    return 0;
}

/* ---- batches: several transactions per system call.  A STATUS (5 bytes) after each engine
   command reports whether it finished in time.  If one did not (a long stall of the Amiga clock),
   the rest of the batch raced it: hdd_spi ignores commands and PUT data only WHILE the engine is
   busy, so a later command may or may not have been taken and ide.v's buffer pointer is unknown.
   Then the whole block is redone the slow way from the start (PTR0, one verified step at a time):
   writing or reading the same sectors again is harmless (in fast read mode the CPU just waits
   until the pointer is ahead of it again). */
#define D_REG    2       /* us after a register access (the engine needs ~5 main clocks) */
#define D_COMMIT 30      /* us after COMMIT (256 words x 3 main clocks = 27 us; +10 us CS gap) */
#define D_FETCH  40      /* us after FETCH (256 words x 5 main clocks = 45 us; +10 us CS gap) */
#define DL(h, d) ((uint16_t)((d) * (100 - (h)->delay_cut) / 100))   /* tests: shortened delays */

static int batch(struct hdd *h, const struct hdd_seg *seg, int n)
{
    static uint8_t scratch[513];
    int i;
    if (h->io.xfer_batch) return h->io.xfer_batch(h->io.ctx, seg, n);
    for (i = 0; i < n; i++)
        if (h->io.xfer(h->io.ctx, seg[i].tx, seg[i].rx ? seg[i].rx : scratch, seg[i].len)) return -1;
    return 0;
}

/* a STATUS reply: 1 finished (result in *res), 0 still busy / not acknowledged, -1 link error */
static int st_done(const uint8_t *rx, uint16_t *res)
{
    if (rx[1] != 0xA1) return -1;
    if (!(rx[2] & 0x80) && (rx[2] & 0x40)) {
        if (res) *res = (uint16_t)(rx[3] << 8 | rx[4]);
        return 1;
    }
    return 0;
}

/* wait for the running engine command (after a "busy" STATUS in a batch) */
static int engine_wait(struct hdd *h)
{
    uint8_t fl;
    uint16_t res;
    int i;
    h->batch_retries++;
    for (i = 0; i < 100000; i++) {
        if (hdd_status(h, &fl, &res)) return -1;
        if (!(fl & 0x80) && (fl & 0x40)) return res == 0xDEAD ? -2 : 0;
    }
    h->timeouts++;
    lg(h, "engine_wait: timeout", 0, 0, 0, 0);
    return -1;
}

static const uint8_t st_tx[5] = {0, 0, 0, 0, 0};
static const uint8_t commit_tx[1] = {0x31};
static const uint8_t fetch_tx[1] = {0x40};

#define PER_PUT  (HDD_AL(513) + HDD_AL(1) + HDD_AL(5))     /* tx bytes per sector (the larger side) */
#define MAX_K    (HDD_BATCH_BYTES / PER_PUT)               /* 4 sectors per batch */

int hdd_put_n(struct hdd *h, const uint8_t *s, unsigned n)
{
    uint8_t tx[MAX_K][513], srx[MAX_K][5];
    struct hdd_seg seg[3 * MAX_K];
    unsigned done = 0, k, m, i;
    uint16_t res;
    if (!h->batch) goto slow;
    while (done < n) {
        m = n - done < MAX_K ? n - done : MAX_K;
        for (k = 0; k < m; k++) {
            const uint8_t *p = s + 512 * (done + k);
            tx[k][0] = 0x30;
            for (i = 0; i < 256; i++) { tx[k][1 + 2 * i] = p[2 * i + 1]; tx[k][2 + 2 * i] = p[2 * i]; }
            seg[3 * k]     = (struct hdd_seg){tx[k], NULL, 513, 0};
            seg[3 * k + 1] = (struct hdd_seg){commit_tx, NULL, 1, DL(h, D_COMMIT)};
            seg[3 * k + 2] = (struct hdd_seg){st_tx, srx[k], 5, 0};
        }
        if (batch(h, seg, 3 * (int)m)) return -1;
        for (k = 0; k < m; k++) {
            int r = st_done(srx[k], &res);
            if (r < 0) { lg(h, "put batch: bad STATUS %02x %02x after sector %u", srx[k][1], srx[k][2], done + k, 0); return -1; }
            if (r == 0) { TRY(engine_wait(h)); TRY(ptr0(h)); goto slow; }
            if (res == 0xDEAD) return -2;
        }
        done += m;
    }
    return 0;
slow:
    for (k = 0; k < n; k++) TRY(hdd_put(h, s + 512 * k));
    return 0;
}


int hdd_get_n(struct hdd *h, uint8_t *s, unsigned n)
{
    uint8_t gtx[513], rx[MAX_K][513], srx[MAX_K][5];
    struct hdd_seg seg[3 * MAX_K];
    unsigned done = 0, k, m, i;
    uint16_t res;
    if (!h->batch) goto slow;
    memset(gtx, 0, sizeof gtx);
    gtx[0] = 0x41;
    while (done < n) {
        m = n - done < MAX_K ? n - done : MAX_K;
        for (k = 0; k < m; k++) {
            seg[3 * k]     = (struct hdd_seg){fetch_tx, NULL, 1, DL(h, D_FETCH)};
            seg[3 * k + 1] = (struct hdd_seg){st_tx, srx[k], 5, 0};
            seg[3 * k + 2] = (struct hdd_seg){gtx, rx[k], 513, 0};
        }
        if (batch(h, seg, 3 * (int)m)) return -1;
        for (k = 0; k < m; k++) {
            int r = st_done(srx[k], &res);
            if (r < 0) { lg(h, "get batch: bad STATUS %02x %02x before sector %u", srx[k][1], srx[k][2], done + k, 0); return -1; }
            if (r == 0) { TRY(engine_wait(h)); TRY(ptr0(h)); goto slow; }
            if (res == 0xDEAD) return -2;
            for (i = 0; i < 256; i++) { s[512 * (done + k) + 2 * i + 1] = rx[k][1 + 2 * i];
                                        s[512 * (done + k) + 2 * i] = rx[k][2 + 2 * i]; }
        }
        done += m;
    }
    return 0;
slow:
    for (k = 0; k < n; k++) TRY(hdd_get(h, s + 512 * k));
    return 0;
}

/* register accesses in one batch: ops[i] = 0x1a (read, result into v[i]), 0x2a (write v[i]) or 0x32
   (PTR0).  Only for IDEMPOTENT sequences (task file reads, block size + PTR0): if one step is found
   unfinished, all of them are done again one verified step at a time.  The status write that arms
   DRQ / raises the interrupt is never batched (doing it twice would restart the CPU's transfer). */
static int regs_batch(struct hdd *h, const uint8_t *ops, uint16_t *v, int n)
{
    uint8_t tx[8][3], srx[8][5];
    struct hdd_seg seg[16];
    int i, r;
    if (!h->batch) goto slow;
    for (i = 0; i < n; i++) {
        tx[i][0] = ops[i]; tx[i][1] = (uint8_t)(v[i] >> 8); tx[i][2] = (uint8_t)v[i];
        seg[2 * i]     = (struct hdd_seg){tx[i], NULL, (uint16_t)((ops[i] & 0xF0) == 0x20 ? 3 : 1), DL(h, D_REG)};
        seg[2 * i + 1] = (struct hdd_seg){st_tx, srx[i], 5, 0};
    }
    if (batch(h, seg, 2 * n)) return -1;
    for (i = 0; i < n; i++) {
        uint16_t res;
        r = st_done(srx[i], &res);
        if (r < 0) return -1;
        if (r == 0) { TRY(engine_wait(h)); goto slow; }
        if (res == 0xDEAD) return -2;
        if ((ops[i] & 0xF0) == 0x10) v[i] = res;
    }
    return 0;
slow:
    for (i = 0; i < n; i++)
        TRY((ops[i] & 0xF0) == 0x20 ? hdd_engine(h, ops[i], 1, v[i], 0) : hdd_engine(h, ops[i], 0, 0, &v[i]));
    return 0;
}

/* IDENTIFY data is what a drive puts on the IDE bus: word values in the buffer as they are.  hdd_put
   loads buffer word i from bytes 2i | 2i+1 << 8 (the sector byte order, see the header), so the block
   is built little-endian here.  (The A1200 swaps the bytes between the IDE bus and the CPU -- gayle.v
   models it; scsi.device swaps IDENTIFY words back, sector data stays as the CPU reads it.) */
static void put16(uint8_t *b, unsigned w, unsigned v) { b[2 * w] = (uint8_t)v; b[2 * w + 1] = (uint8_t)(v >> 8); }

static void putstr(uint8_t *b, unsigned w, unsigned nw, const char *s)
{
    unsigned i, n = (unsigned)strlen(s);
    for (i = 0; i < nw; i++) {              /* ATA strings: first character in the high byte */
        unsigned c1 = 2 * i < n ? (uint8_t)s[2 * i] : ' ', c2 = 2 * i + 1 < n ? (uint8_t)s[2 * i + 1] : ' ';
        put16(b, w + i, c1 << 8 | c2);
    }
}

static void identify(struct hdd *h, uint8_t *b)
{
    uint64_t cap = (uint64_t)h->cyls * h->heads * h->spt;
    uint64_t curcap = (uint64_t)h->cyls * h->cur_heads * h->cur_spt;
    uint32_t lba = h->nblk > 0x0FFFFFFF ? 0x0FFFFFFF : (uint32_t)h->nblk;
    memset(b, 0, 512);
    put16(b, 0, 0x0040);                     /* fixed disk */
    put16(b, 1, h->cyls);
    put16(b, 3, h->heads);
    put16(b, 4, 512 * h->spt);
    put16(b, 5, 512);
    put16(b, 6, h->spt);
    putstr(b, 10, 10, "AEXP0001");
    put16(b, 20, 3);                         /* buffer type */
    put16(b, 21, 16);                        /* buffer size / 512 */
    putstr(b, 23, 4, "1.0");
    putstr(b, 27, 20, "AExp hddsrv");
    put16(b, 47, 0x8000 | HDD_MAX_MULTIPLE);
    put16(b, 49, 0x0200);                    /* LBA supported */
    put16(b, 51, 0x0200);                    /* PIO mode 2 */
    put16(b, 53, 0x0001);                    /* words 54..58 valid */
    put16(b, 54, h->cyls);
    put16(b, 55, h->cur_heads);
    put16(b, 56, h->cur_spt);
    put16(b, 57, (unsigned)(curcap & 0xFFFF));
    put16(b, 58, (unsigned)(curcap >> 16));
    put16(b, 59, h->multiple ? 0x0100 | h->multiple : 0);
    put16(b, 60, lba & 0xFFFF);
    put16(b, 61, lba >> 16);
    (void)cap;
}

static int finish(struct hdd *h, unsigned status, unsigned error)
{
    TRY(regwr(h, 0, (uint16_t)(error << 8 | 1)));     /* error register (0 = none) */
    return regwr(h, 5, (uint16_t)status);
}

static int fail(struct hdd *h, unsigned error)
{
    h->errors++;
    return finish(h, ST_DRDY | ST_DSC | ST_ERR | ST_IRQ, error);
}

/* wait for the CPU to finish a data block (request 101); -2 if a reset came instead */
static int wait_block(struct hdd *h)
{
    uint8_t fl;
    int i, r;
    for (i = 0; i < 200000; i++) {
        r = h->io.wait_att(h->io.ctx, 1000);
        if (r < 0) return -1;
        if (hdd_status(h, &fl, 0)) return -1;
        if ((fl & 7) == 5) return 0;
        if ((fl & 7) == 6 || (fl & 7) == 4) {   /* a reset, or a new command after a reset: give up
                                                   this one, the next round takes the new request */
            lg(h, "data phase ended by request %u (Amiga reset)", fl & 7, 0, 0, 0);
            return -2;
        }
        if (fl & 0x40) {                     /* a leftover done keeps att high: acknowledge it */
            uint8_t tx[1] = {0x01}, rx[1];
            h->io.xfer(h->io.ctx, tx, rx, 1);
        }
    }
    h->timeouts++;
    return -1;
}

static int do_reset(struct hdd *h)
{
    h->multiple = HDD_MAX_MULTIPLE;          /* see hdd_init */
    h->cur_heads = h->heads;
    h->cur_spt = h->spt;
    TRY(regwr(h, 6, 0x0009));      /* drive 0 present, no LBA48 */
    TRY(regwr(h, 5, ST_DRDY | ST_DSC));   /* -2 while the Amiga is still in reset: the caller retries */
    h->resets++;
    if (h->verbose) lg(h, "reset (request 110) answered", 0, 0, 0, 0);
    return 0;
}

static int command(struct hdd *h)
{
    uint16_t r1, r2, r5;
    unsigned cmd, drv, count, sector, cyl, head, block, n, i, total;
    uint64_t lba;
    uint8_t buf[HDD_MAX_MULTIPLE * 512];
    int lbamode, rc, write, multi;

    {
        static const uint8_t ops[3] = {0x11, 0x12, 0x15};
        uint16_t v[3] = {0, 0, 0};
        TRY(regs_batch(h, ops, v, 3));
        r1 = v[0]; r2 = v[1]; r5 = v[2];
    }
    cmd = r5 >> 8;
    drv = r5 & 0xFF;
    count = r1 & 0xFF;
    sector = r1 >> 8;
    cyl = r2;
    head = drv & 15;
    lbamode = (drv >> 6) & 1;
    h->cmds++;
    if (h->verbose)
        lg(h, "cmd %02x drv %02x count %u chs/lba %u", cmd, drv, count, lbamode ? (head << 24 | cyl << 8 | sector) : cyl);
    if (drv & 0x10)                          /* the slave drive does not exist */
        return finish(h, ST_ERR, ER_ABRT);

    switch (cmd) {
    case 0xEC:                               /* IDENTIFY DEVICE */
        identify(h, buf);
        TRY(regwr(h, 0, 1)); TRY(ptr0(h)); TRY(hdd_put(h, buf));
        return regwr(h, 5, ST_DRDY | ST_DSC | ST_DRQ | ST_IRQ | ST_LAST);
    case 0x91:                               /* INITIALIZE DEVICE PARAMETERS */
        h->cur_heads = head + 1;
        h->cur_spt = count ? count : 256;
        return finish(h, ST_DRDY | ST_DSC | ST_IRQ, 0);
    case 0xC6:                               /* SET MULTIPLE MODE */
        if (count > HDD_MAX_MULTIPLE || (count & (count - 1)))
            return fail(h, ER_ABRT);
        h->multiple = count;
        return finish(h, ST_DRDY | ST_DSC | ST_IRQ, 0);
    case 0x20: case 0x21: case 0xC4:         /* READ SECTORS / MULTIPLE */
    case 0x30: case 0x31: case 0xC5:         /* WRITE SECTORS / MULTIPLE */
        write = cmd == 0x30 || cmd == 0x31 || cmd == 0xC5;
        multi = cmd == 0xC4 || cmd == 0xC5;
        if (multi && !h->multiple) return fail(h, ER_ABRT);
        total = count ? count : 256;
        if (lbamode)
            lba = (uint64_t)head << 24 | (uint64_t)cyl << 8 | sector;
        else {
            if (!sector || sector > h->cur_spt || head >= h->cur_heads) return fail(h, ER_IDNF);
            lba = ((uint64_t)cyl * h->cur_heads + head) * h->cur_spt + sector - 1;
        }
        if (lba + total > h->nblk) return fail(h, ER_IDNF);
        if (write && h->ro) return fail(h, ER_ABRT);
        block = multi ? h->multiple : 1;
        for (i = 0; i < total; i += n) {
            unsigned last;
            n = total - i < block ? total - i : block;
            last = i + n >= total;
            if (!write) {
                if (h->io.rd(h->io.ctx, lba + i, n, buf)) return fail(h, ER_UNC);
                if (h->fast) {
                    /* fast read: block size + DRQ + interrupt first (the status write also zeroes
                       ide.v's buffer pointers), then the sectors; the CPU starts reading at once and
                       Gayle holds its bus cycle (nrdy) whenever it catches up with the data so far */
                    TRY(regwr(h, 0, (uint16_t)n));
                    TRY(regwr(h, 5, ST_DRDY | ST_DSC | ST_DRQ | ST_IRQ | ST_FAST | (last ? ST_LAST : 0)));
                    TRY(hdd_put_n(h, buf, n));
                } else {
                    TRY(regwr(h, 0, (uint16_t)n));
                    TRY(ptr0(h));
                    TRY(hdd_put_n(h, buf, n));
                    TRY(regwr(h, 5, ST_DRDY | ST_DSC | ST_DRQ | ST_IRQ | (last ? ST_LAST : 0)));
                }
                h->rd_sect += n;
                if (!last && (rc = wait_block(h))) return rc;
            } else {
                /* PIO out: DRQ for the block (no interrupt before the first block), the CPU fills
                   the buffer, request 101, the data comes back here */
                {
                    static const uint8_t ops[2] = {0x20, 0x32};          /* block size, PTR0 */
                    uint16_t v[2];
                    v[0] = (uint16_t)n; v[1] = 0;
                    TRY(regs_batch(h, ops, v, 2));
                }
                TRY(regwr(h, 5, ST_DRDY | ST_DSC | ST_DRQ | (i ? ST_IRQ : 0)));
                if ((rc = wait_block(h))) return rc;
                TRY(ptr0(h));
                TRY(hdd_get_n(h, buf, n));
                if (h->io.wr(h->io.ctx, lba + i, n, buf)) return fail(h, ER_UNC);
                h->wr_sect += n;
                if (last) return finish(h, ST_DRDY | ST_DSC | ST_IRQ, 0);
            }
        }
        return 0;
    case 0x40: case 0x41:                    /* READ VERIFY */
    case 0x10: case 0x11: case 0x12: case 0x13: case 0x14: case 0x15: case 0x16: case 0x17:
    case 0x18: case 0x19: case 0x1A: case 0x1B: case 0x1C: case 0x1D: case 0x1E: case 0x1F:
    case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
    case 0x78: case 0x79: case 0x7A: case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F:
    case 0xEF:                               /* SET FEATURES */
    case 0xE0: case 0xE1: case 0xE2: case 0xE3: case 0xE5: case 0xE6:   /* power management */
    case 0xE7:                               /* FLUSH CACHE */
    case 0xE8: case 0xE9: case 0xDA: case 0xDE: case 0xDF:              /* unused */
        return finish(h, ST_DRDY | ST_DSC | ST_IRQ, 0);
    default:
        lg(h, "unsupported command %02x (drv %02x)", cmd, drv, 0, 0);
        return fail(h, ER_ABRT);
    }
}

int hdd_init(struct hdd *h)
{
    uint8_t fl;
    h->heads = 16;
    h->spt = 63;
    h->cyls = (unsigned)(h->nblk / (16 * 63));
    if (h->cyls > 16383) h->cyls = 16383;
    h->cur_heads = h->heads;
    h->cur_spt = h->spt;
    h->multiple = HDD_MAX_MULTIPLE;   /* ATA allows multiple mode on at power-up (IDENTIFY word 59
                                         reports it); a server restarted under a running Amiga then
                                         still matches the SET MULTIPLE 16 Kickstart issued */
    /* the drive appears; an idle unit gets the ready status, a pending request (a command the Amiga
       issued while no server ran, or a reset) is left for the serve loop */
    if (regwr(h, 6, 0x0009) || hdd_status(h, &fl, 0)) return -1;
    if (fl & 7) return 0;
    /* idle unit: ready, but WITH the error bit (ABRT).  If this server replaces one that died in the
       middle of a fast read, the CPU is waiting inside the block (Gayle nrdy); this status write
       releases it with stale words, and the error makes the driver retry instead of taking them.
       Between commands the error bit is harmless: the next command's status replaces it. */
    if (regwr(h, 0, (uint16_t)(ER_ABRT << 8 | 1))) return -1;
    return regwr(h, 5, ST_DRDY | ST_DSC | ST_ERR);
}

int hdd_poll(struct hdd *h, int timeout_ms)
{
    uint8_t fl, tx[1] = {0x01}, rx[1];
    int r = h->io.wait_att(h->io.ctx, timeout_ms);
    if (r < 0) return -1;
    if (hdd_status(h, &fl, 0)) return -1;
    if (fl & 0x40) h->io.xfer(h->io.ctx, tx, rx, 1);   /* drop a leftover done */
    switch (fl & 7) {
    case 0:
        return 0;
    case 6:
        r = do_reset(h);                     /* -2: the reset is still on, the next round repeats it */
        return r == -1 ? -1 : 1;
    case 4:
        r = command(h);
        if (r == -2) return 1;               /* the Amiga reset in the middle: the next round sees it */
        return r ? -1 : 1;
    default:                                  /* 101 outside a command: a server restarted in the
                                                 middle of a data phase; end the command with an
                                                 error, the OS retries */
        lg(h, "stray request %u: command aborted", fl & 7, 0, 0, 0);
        return fail(h, ER_ABRT) == -1 ? -1 : 1;
    }
}

int hdd_serve(struct hdd *h, volatile int *stop)
{
    while (!*stop) {
        int r = hdd_poll(h, 100);
        if (r < 0) {
            lg(h, "link error (cmds %u)", (unsigned)h->cmds, 0, 0, 0);
            return -1;
        }
    }
    return 0;
}
