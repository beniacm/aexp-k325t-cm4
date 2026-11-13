/* hddsrv_linux.c -- the A1200 hard disk server on the Linux module (Radxa CM3), own code.
 *
 *   hddsrv IMAGE.hdf [-r] [-v] [-F] [-B] [-d /dev/spidev0.0] [-s HZ] [-g /dev/gpiochip4] [-l 21] [-L N]
 *
 * IMAGE: a hard disk image (whole 512-byte sectors, e.g. an RDB HDF from tools/mk_hdf.py); for tests
 * keep it in RAM (/dev/shm).  Writes are plain pwrite()s into the file: no fsync, no journal, nothing
 * periodic; -r opens it read-only (the Amiga gets an error for every write).
 * -d / -s: the SPI device and clock (default /dev/spidev0.0, 20 MHz requested = 19.8 MHz real; the link
 * is clean up to 19.8 MHz and fails at 24.75 MHz (SCK is oversampled at 100 MHz); the RK3568 divides
 * its 198 MHz SPI clock by an even number, so the real rate is reported).  -g / -l: the attention
 * line (BCM7 = GPIO4_C5 = gpiochip4 line 21); -l -1 polls instead (every 2 ms).
 * -L N: link test only (no Amiga needed, the menu's IDE bit must be on): N rounds of a random sector
 * through PUT -> COMMIT -> PTR0 -> FETCH -> GET, compared; errors and throughput are printed.
 * -B: no batches (every SPI transaction its own system call, as the first version); -n N: sectors
 *     per link-test round (1..16, ide.v's buffer).
 * -F: reads without ide.v's fast mode (the whole block into the buffer before DRQ; slower, for comparison).
 * Ctrl+C / SIGTERM ends the server cleanly (statistics printed).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <linux/gpio.h>
#include <linux/spi/spidev.h>
#include "hddsrv_core.h"

struct ctx {
    int spi, img, evfd;
    unsigned speed;
    uint64_t xfers, bytes, ioctls;
    /* latency of a request woken by the attention edge (kernel event timestamp, CLOCK_MONOTONIC):
       edge -> first SPI transaction done (the STATUS read), edge -> first sector transfer done */
    uint64_t ev_ns;                 /* timestamp of the pending edge, 0 = none */
    int ev_stat;                    /* the status read of this edge already counted */
    uint64_t n_wake, sum_wake, max_wake, n_data, sum_data, max_data;
    uint32_t hist_wake[8], hist_data[8];   /* < 50, 100, 200, 500 us, 1, 2, 5 ms, more */
};

static uint64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static void hist(uint32_t *hh, uint64_t ns)
{
    static const uint64_t lim[7] = {50000, 100000, 200000, 500000, 1000000, 2000000, 5000000};
    int i;
    for (i = 0; i < 7 && ns >= lim[i]; i++) ;
    hh[i]++;
}

static volatile int g_stop;
static void onsig(int s) { (void)s; g_stop = 1; }

static int l_xfer(void *c, const uint8_t *tx, uint8_t *rx, int len)
{
    struct ctx *x = c;
    struct spi_ioc_transfer t;
    memset(&t, 0, sizeof t);
    t.tx_buf = (unsigned long)tx;
    t.rx_buf = (unsigned long)rx;
    t.len = (unsigned)len;
    t.speed_hz = x->speed;
    t.bits_per_word = 8;
    if (ioctl(x->spi, SPI_IOC_MESSAGE(1), &t) < 0) return -1;
    x->xfers++;
    x->ioctls++;
    x->bytes += (unsigned)len;
    if (x->ev_ns) {
        uint64_t d = mono_ns() - x->ev_ns;
        if (!x->ev_stat) {
            x->ev_stat = 1; x->n_wake++; x->sum_wake += d; if (d > x->max_wake) x->max_wake = d;
            hist(x->hist_wake, d);
        }
        if (len >= 513) {                    /* the first sector moved (PUT or GET) */
            x->n_data++; x->sum_data += d; if (d > x->max_data) x->max_data = d;
            hist(x->hist_data, d);
            x->ev_ns = 0;
        }
    }
    return 0;
}

static int l_xfer_batch(void *c, const struct hdd_seg *seg, int n)
{
    struct ctx *x = c;
    struct spi_ioc_transfer t[48];
    int i;
    uint64_t len = 0;
    if (n > 48) return -1;
    memset(t, 0, sizeof t[0] * (size_t)n);
    for (i = 0; i < n; i++) {
        t[i].tx_buf = (unsigned long)seg[i].tx;
        t[i].rx_buf = (unsigned long)seg[i].rx;
        t[i].len = seg[i].len;
        t[i].speed_hz = x->speed;
        t[i].bits_per_word = 8;
        t[i].delay_usecs = seg[i].delay_us;     /* after the transfer, CS still low */
        t[i].cs_change = i < n - 1;             /* CS high between the transactions */
        len += seg[i].len;
    }
    if (ioctl(x->spi, SPI_IOC_MESSAGE(n), t) < 0) {
        fprintf(stderr, "hddsrv: batch of %d transfers (%llu bytes): %s\n", n, (unsigned long long)len, strerror(errno));
        return -1;
    }
    x->xfers += (unsigned)n;
    x->ioctls++;
    x->bytes += len;
    if (x->ev_ns) {                              /* latency bookkeeping as in l_xfer */
        uint64_t d = mono_ns() - x->ev_ns;
        int big = 0;
        for (i = 0; i < n; i++) big |= seg[i].len >= 513;
        if (!x->ev_stat) {
            x->ev_stat = 1; x->n_wake++; x->sum_wake += d; if (d > x->max_wake) x->max_wake = d;
            hist(x->hist_wake, d);
        }
        if (big) {
            x->n_data++; x->sum_data += d; if (d > x->max_data) x->max_data = d;
            hist(x->hist_data, d);
            x->ev_ns = 0;
        }
    }
    return 0;
}

static int att_level(struct ctx *x)
{
    struct gpio_v2_line_values v = {.bits = 0, .mask = 1};
    if (ioctl(x->evfd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0) return -1;
    return (int)(v.bits & 1);
}

static int l_wait_att(void *c, int ms)
{
    struct ctx *x = c;
    struct pollfd p;
    int r;
    if (g_stop) return -1;
    if (x->evfd < 0) {                        /* no attention line: poll the status every 2 ms */
        struct timespec ts = {0, 2000000};
        nanosleep(&ts, 0);
        return 1;
    }
    r = att_level(x);
    if (r) return r;
    p.fd = x->evfd;
    p.events = POLLIN;
    r = poll(&p, 1, ms);
    if (r < 0) return errno == EINTR ? (g_stop ? -1 : 0) : -1;
    if (r > 0) {
        struct gpio_v2_line_event ev[16];
        ssize_t n = read(x->evfd, ev, sizeof ev);
        if (n < (ssize_t)sizeof ev[0]) return -1;
        x->ev_ns = ev[n / sizeof ev[0] - 1].timestamp_ns;   /* the latest edge */
        x->ev_stat = 0;
        return 1;
    }
    return 0;
}

static int l_rd(void *c, uint64_t lba, unsigned n, uint8_t *b)
{
    struct ctx *x = c;
    return pread(x->img, b, 512u * n, (off_t)(lba * 512)) == (ssize_t)(512u * n) ? 0 : -1;
}

static int l_wr(void *c, uint64_t lba, unsigned n, const uint8_t *b)
{
    struct ctx *x = c;
    return pwrite(x->img, b, 512u * n, (off_t)(lba * 512)) == (ssize_t)(512u * n) ? 0 : -1;
}

static void l_log(void *c, const char *m) { (void)c; fprintf(stderr, "hddsrv: %s\n", m); }

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int linktest(struct hdd *h, struct ctx *x, int rounds, int nsec)
{
    static uint8_t a[16 * 512], b[16 * 512];
    uint8_t fl;
    uint16_t res;
    long errs = 0, bad = 0;
    int i, k;
    double t0, t;
    if (hdd_status(h, &fl, &res)) {
        fprintf(stderr, "linktest: no answer (version byte wrong): is the core loaded, the menu's IDE bit on?\n");
        return 1;
    }
    printf("linktest: status ok, flags %02x, %d rounds of %d sector(s), SPI %u Hz requested, %s\n", fl, rounds,
           nsec, x->speed, h->batch ? "batched" : "one call per step");
    srand(12345);
    t0 = now();
    for (i = 0; i < rounds && !g_stop; i++) {
        for (k = 0; k < 512 * nsec; k++) a[k] = (uint8_t)rand();
        /* PTR0, n x (PUT + COMMIT), PTR0, n x (FETCH + GET): the same sectors back through ide.v's buffer */
        if (hdd_engine(h, 0x32, 0, 0, 0) || hdd_put_n(h, a, (unsigned)nsec) || hdd_engine(h, 0x32, 0, 0, 0) ||
            hdd_get_n(h, b, (unsigned)nsec)) {
            errs++;
            if (errs > 10) break;
            continue;
        }
        for (k = 0; k < 512 * nsec; k++) bad += a[k] != b[k];
        if (i == 0 && bad) {
            printf("first round differs: ");
            for (k = 0; k < 16; k++) printf("%02x/%02x ", a[k], b[k]);
            printf("\n");
        }
    }
    t = now() - t0;
    printf("linktest: %d rounds, %ld transfer errors, %ld bytes differ, %.2f s, %.0f KB/s each way, "
           "%llu SPI transactions in %llu system calls, %llu batch resumes\n", i, errs, bad, t,
           (double)i * nsec * 512.0 / 1024 / t, (unsigned long long)x->xfers, (unsigned long long)x->ioctls,
           (unsigned long long)h->batch_retries);
    return errs || bad;
}

int main(int argc, char **argv)
{
    const char *img = 0, *dev = "/dev/spidev0.0", *chip = "/dev/gpiochip4";
    int line = 21, ro = 0, verbose = 0, link = 0, slow = 0, nobatch = 0, nsec = 1, i;
    unsigned speed = 20000000;
    struct ctx x = {.spi = -1, .img = -1, .evfd = -1};
    struct hdd h;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-r")) ro = 1;
        else if (!strcmp(argv[i], "-F")) slow = 1;
        else if (!strcmp(argv[i], "-B")) nobatch = 1;
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) nsec = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) dev = argv[++i];
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) speed = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "-g") && i + 1 < argc) chip = argv[++i];
        else if (!strcmp(argv[i], "-l") && i + 1 < argc) line = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-L") && i + 1 < argc) link = atoi(argv[++i]);
        else if (argv[i][0] != '-' && !img) img = argv[i];
        else { fprintf(stderr, "usage: hddsrv IMAGE [-r] [-v] [-d SPIDEV] [-s HZ] [-g GPIOCHIP] [-l LINE] [-L N]\n"); return 2; }
    }
    if (!img && !link) { fprintf(stderr, "no image\n"); return 2; }
    x.speed = speed;
    x.spi = open(dev, O_RDWR);
    if (x.spi < 0) { perror(dev); return 1; }
    {
        uint8_t mode = SPI_MODE_0, bits = 8;
        ioctl(x.spi, SPI_IOC_WR_MODE, &mode);
        ioctl(x.spi, SPI_IOC_WR_BITS_PER_WORD, &bits);
        ioctl(x.spi, SPI_IOC_WR_MAX_SPEED_HZ, &speed);
    }
    if (line >= 0) {
        int cfd = open(chip, O_RDONLY);
        struct gpio_v2_line_request rq;
        if (cfd < 0) { perror(chip); return 1; }
        memset(&rq, 0, sizeof rq);
        rq.offsets[0] = (unsigned)line;
        rq.num_lines = 1;
        strcpy(rq.consumer, "hddsrv-att");
        rq.config.flags = GPIO_V2_LINE_FLAG_INPUT | GPIO_V2_LINE_FLAG_EDGE_RISING;
        if (ioctl(cfd, GPIO_V2_GET_LINE_IOCTL, &rq) < 0) { perror("attention line"); return 1; }
        x.evfd = rq.fd;
        close(cfd);
    }
    signal(SIGINT, onsig);
    signal(SIGTERM, onsig);
    memset(&h, 0, sizeof h);
    h.io.xfer = l_xfer; h.io.xfer_batch = l_xfer_batch; h.io.wait_att = l_wait_att; h.io.rd = l_rd; h.io.wr = l_wr; h.io.log = l_log;
    h.io.ctx = &x;
    h.verbose = verbose;
    h.fast = !slow;
    h.batch = !nobatch;
    if (nsec < 1 || nsec > 16) nsec = 1;
    if (link) return linktest(&h, &x, link, nsec);
    x.img = open(img, ro ? O_RDONLY : O_RDWR);
    if (x.img < 0) { perror(img); return 1; }
    h.nblk = (uint64_t)lseek(x.img, 0, SEEK_END) / 512;
    h.ro = ro;
    fprintf(stderr, "hddsrv: %s, %llu sectors, SPI %s %u Hz, attention %s%s\n", img, (unsigned long long)h.nblk,
            dev, speed, line >= 0 ? "line" : "polling", ro ? ", read-only" : "");
    /* the core may be absent (another core, a JTAG load, the menu's IDE bit off, an M2M reset: the
       menu bits drop while QNICE restarts): wait for it, serve, and wait again when the link is lost */
    for (i = 0; !g_stop; ) {
        int waited = 0;
        while (!g_stop && hdd_init(&h) != 0) {
            if (!waited++) fprintf(stderr, "hddsrv: waiting for the core (Amiga core loaded, IDE bit on?)\n");
            usleep(100000);
        }
        if (g_stop) break;
        fprintf(stderr, "hddsrv: drive online (%u/%u/%u)\n", h.cyls, h.heads, h.spt);
        i = hdd_serve(&h, &g_stop);
        if (i && !g_stop) {
            fprintf(stderr, "hddsrv: link lost (core reset or gone)\n");
            h.links_lost++;
        }
    }
    i = 0;
    if (x.n_wake) {
        int k;
        fprintf(stderr, "hddsrv: attention edge -> status read: %llu requests, mean %.0f us, max %.0f us;"
                " edge -> first sector moved: %llu, mean %.0f us, max %.0f us\n", (unsigned long long)x.n_wake,
                x.sum_wake / 1e3 / x.n_wake, x.max_wake / 1e3, (unsigned long long)x.n_data,
                x.n_data ? x.sum_data / 1e3 / x.n_data : 0.0, x.max_data / 1e3);
        fprintf(stderr, "hddsrv: histogram (<50us <100 <200 <500 <1ms <2 <5 more) status:");
        for (k = 0; k < 8; k++) fprintf(stderr, " %u", x.hist_wake[k]);
        fprintf(stderr, "  sector:");
        for (k = 0; k < 8; k++) fprintf(stderr, " %u", x.hist_data[k]);
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "hddsrv: %llu commands, %llu sectors read, %llu written, %llu errors, %llu resets, "
            "%llu timeouts, %llu link losses, %llu SPI transactions, %llu bytes\n", (unsigned long long)h.cmds,
            (unsigned long long)h.rd_sect, (unsigned long long)h.wr_sect, (unsigned long long)h.errors,
            (unsigned long long)h.resets, (unsigned long long)h.timeouts, (unsigned long long)h.links_lost,
            (unsigned long long)x.xfers,
            (unsigned long long)x.bytes);
    return i ? 1 : 0;
}
