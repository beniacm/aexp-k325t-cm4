/* hddsrv_linux.c -- the A1200 hard disk server on the Linux module (Radxa CM3), own code.
 *
 *   hddsrv IMAGE.hdf [-r] [-v] [-d /dev/spidev0.0] [-s HZ] [-g /dev/gpiochip4] [-l 21] [-L N]
 *
 * IMAGE: a hard disk image (whole 512-byte sectors, e.g. an RDB HDF from tools/mk_hdf.py); for tests
 * keep it in RAM (/dev/shm).  Writes are plain pwrite()s into the file: no fsync, no journal, nothing
 * periodic; -r opens it read-only (the Amiga gets an error for every write).
 * -d / -s: the SPI device and clock (default /dev/spidev0.0, 25 MHz requested; the RK3568 divides
 * its 198 MHz SPI clock by an even number, so the real rate is reported).  -g / -l: the attention
 * line (BCM7 = GPIO4_C5 = gpiochip4 line 21); -l -1 polls instead (every 2 ms).
 * -L N: link test only (no Amiga needed, the menu's IDE bit must be on): N rounds of a random sector
 * through PUT -> COMMIT -> PTR0 -> FETCH -> GET, compared; errors and throughput are printed.
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
    uint64_t xfers, bytes;
};

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
    x->bytes += (unsigned)len;
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
        if (read(x->evfd, ev, sizeof ev) < 0) return -1;
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

static int linktest(struct hdd *h, struct ctx *x, int rounds)
{
    uint8_t a[512], b[512], fl;
    uint16_t res;
    long errs = 0, bad = 0;
    int i, k;
    double t0;
    if (hdd_status(h, &fl, &res)) {
        fprintf(stderr, "linktest: no answer (version byte wrong): is the core loaded, the menu's IDE bit on?\n");
        return 1;
    }
    printf("linktest: status ok, flags %02x, %d rounds, SPI %u Hz requested\n", fl, rounds, x->speed);
    srand(12345);
    t0 = now();
    for (i = 0; i < rounds && !g_stop; i++) {
        for (k = 0; k < 512; k++) a[k] = (uint8_t)rand();
        if (hdd_engine(h, 0x32, 0, 0, 0) || hdd_put(h, a) || hdd_engine(h, 0x32, 0, 0, 0) || hdd_get(h, b)) {
            errs++;
            if (errs > 10) break;
            continue;
        }
        /* PTR0, PUT + COMMIT (256 words from pointer 0), PTR0, FETCH + GET: the same sector back */
        for (k = 0; k < 512; k++) bad += a[k] != b[k];
        if (i == 0 && bad) {
            printf("first round differs: ");
            for (k = 0; k < 16; k++) printf("%02x/%02x ", a[k], b[k]);
            printf("\n");
        }
    }
    {
        double t = now() - t0;
        printf("linktest: %d rounds, %ld transfer errors, %ld bytes differ, %.2f s, %.0f KB/s each way, "
               "%llu SPI transactions\n", i, errs, bad, t, i * 512.0 / 1024 / t, (unsigned long long)x->xfers);
    }
    return errs || bad;
}

int main(int argc, char **argv)
{
    const char *img = 0, *dev = "/dev/spidev0.0", *chip = "/dev/gpiochip4";
    int line = 21, ro = 0, verbose = 0, link = 0, i;
    unsigned speed = 25000000;
    struct ctx x = {.spi = -1, .img = -1, .evfd = -1};
    struct hdd h;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-r")) ro = 1;
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
    h.io.xfer = l_xfer; h.io.wait_att = l_wait_att; h.io.rd = l_rd; h.io.wr = l_wr; h.io.log = l_log;
    h.io.ctx = &x;
    h.verbose = verbose;
    if (link) return linktest(&h, &x, link);
    x.img = open(img, ro ? O_RDONLY : O_RDWR);
    if (x.img < 0) { perror(img); return 1; }
    h.nblk = (uint64_t)lseek(x.img, 0, SEEK_END) / 512;
    h.ro = ro;
    for (i = 0; hdd_init(&h) != 0; i++) {
        if (i == 50 || g_stop) { fprintf(stderr, "hddsrv: no answer from the core (IDE bit on?)\n"); return 1; }
        usleep(100000);
    }
    fprintf(stderr, "hddsrv: %s, %llu sectors (%u/%u/%u)%s, SPI %s %u Hz, attention %s\n", img,
            (unsigned long long)h.nblk, h.cyls, h.heads, h.spt, ro ? " read-only" : "", dev, speed,
            line >= 0 ? "line" : "polling");
    i = hdd_serve(&h, &g_stop);
    fprintf(stderr, "hddsrv: %llu commands, %llu sectors read, %llu written, %llu errors, %llu resets, "
            "%llu timeouts, %llu SPI transactions, %llu bytes\n", (unsigned long long)h.cmds,
            (unsigned long long)h.rd_sect, (unsigned long long)h.wr_sect, (unsigned long long)h.errors,
            (unsigned long long)h.resets, (unsigned long long)h.timeouts, (unsigned long long)x.xfers,
            (unsigned long long)x.bytes);
    return i ? 1 : 0;
}
