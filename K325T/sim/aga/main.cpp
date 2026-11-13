// main.cpp -- Verilator driver for tb_top (AGA + 68020 bench, from the A1200 DDR3 study's driver):
// loads a Kickstart (256/512 KB, read in place), runs N frames, logs every chip-bus memory access
// (run-length: one record per access with its tick count), injects test programs into chip RAM,
// writes PPM frames, dumps chip RAM, logs the CPU's bus requests.  Simulation tooling only.
// New options: --cpu N (0xF4 payload: 0 = 68000 fx68k, 3 = 68020 TG68K), --shot-frames a,b,c,
// --px28 (sample the picture every 28 MHz tick: 1920 columns, for super-hires), --dump ADDR LEN FILE
// (chip RAM at the end), --stop ADDR VALUE (stop at the first frame end where the chip-RAM long
// at ADDR holds VALUE), --cputrace FILE FROM TO (CPU requests in frames FROM..TO), --preload FILE
// ADDR (into chip RAM before the start; with mk_agatest.py's boot ROM no Kickstart is needed).
// Floppy: --adf FILE (df0, served by the core's adf_track_engine), --adf2 FRAME FILE (eject at FRAME,
// insert FILE 25 frames later: multi-disk demos), --floppy-turbo (0xF7 bit 0, MiSTer's fast floppy).
// --shot-last: always write the picture of the last frame (also when --stop ends the run).
// --reset-at FRAME: an Amiga reset (the M2M reset line, 200 ticks) at the end of FRAME; the cache and
// the DDR3 model keep their contents, the CPU's held word A+1 (dout2_hold) keeps its value.
// Plusargs of tb_top.sv: +flpdbg (floppy-channel frames and image reads), +dskdbg (every disk DMA
// write to chip RAM, address and data: decode them as MFM to check what Paula received),
// +dout2init=HEX (start with that stale word A+1 of a 32-bit read, as after a reset on the board).
#include "Vtb_top.h"
#include "Vtb_top___024root.h"
#include "Vtb_top_tb_top.h"
#include "verilated.h"
#include "verilated_save.h"
#include "svdpi.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <chrono>
#include <unistd.h>
#include <fcntl.h>
#include "hddsrv_core.h"
#include <deque>

// a1200-lxshell bench link (--host-link REQ RSP): the Linux shell's bridge commands from a named pipe,
// one request per line, one answer line each (ext/aexp9_lxshell/PROTOCOL.md "bench link"):
//   S          -> the 82 STATUS bytes as hex (the bridge's layout: 0..2 signature, 52 core id,
//                 72 master version, 73/74 PUT free, 75/76 GET fill, 77 flags, 78..81 menu id)
//   P <hex>    -> HOST_PUT of those bytes (into the 8 KB PUT queue); answer "OK"
//   G <n>      -> HOST_GET of n bytes (0x00 past the fill level), as hex
//   R          -> HOST_RESET; answer "OK"
//   W <ticks>  -> run the machine clock (28.375 MHz ticks; the master's 50 MHz clock runs with it);
//                 answer "OK <frame> <tick>" when done
//   Q          -> quit; EOF on REQ quits too
// The bridge's SPI and FIFO RTL are not in this bench (sim tb_host_link.vhd covers them): the queues
// here stand in for its PUT / GET FIFOs, the master and the devices behind it are the real RTL.
static FILE *g_hreq = nullptr, *g_hrsp = nullptr;
static std::deque<uint8_t> g_putq, g_getq;
static bool g_hovf = false, g_hclr = false;
static uint64_t g_hbudget = 0; static bool g_hwait = false;
static uint32_t g_menu_id = 0;

struct Rec {               // 16 bytes
  uint32_t tick;           // 28 MHz tick of the first active tick
  uint32_t addr;           // banked word address (minimig ram_address[23:1])
  uint8_t  len;            // ticks the access was active
  uint8_t  flags;          // bit0 write, bits 7:4 fmode {sfm,bfm}
  uint8_t  src;            // 1 cpu 2 bpl 3 spr 4 cop 5 aud 6 dsk 7 blt 8 ref
  uint8_t  phase;          // tick position inside the 7 MHz cycle at start (0..3), +4*dbr
  uint16_t hpos, vpos;
};

static FILE* g_out = nullptr;
static uint64_t g_tick = 0;

// ---------------------------------------------------------------- a1200-ide: hard disk
// The server core (K325T/hddsrv/hddsrv_core.c, the same file as on the module) runs in its own thread;
// its SPI transactions are clocked out here, on the rising edges of hdd_spi's fclk (ui_clk with --cache,
// else the machine clock), SPI_H fclk cycles per half bit.
static const int SPI_H = 4;
struct SpiMaster {
  std::mutex m; std::condition_variable cv, att_cv;
  const uint8_t* tx = nullptr; uint8_t* rx = nullptr; int len = 0;
  std::atomic<int> pending{0}; int done = 0;
  int state = 0, byte = 0, bit = 0, cnt = 0; uint8_t inb = 0;
  std::atomic<int> att{0};
  uint64_t xfers = 0, bytes = 0;
  long idle = 0;                     // pending == 2: an idle wait of this many fclk cycles (batch delays)
} g_spi;
static int g_fclk_mhz = 100;         // fclk cycles per microsecond (ui_clk with --cache, else the machine clock)
static int g_hdd_fd = -1;
static std::atomic<int> g_hdd_stop{0};

static void spi_step(Vtb_top* top) {
  SpiMaster& s = g_spi;
  int a = top->hd_att;
  if (a != s.att.load()) { s.att = a; if (a) { std::lock_guard<std::mutex> l(s.m); s.att_cv.notify_all(); } }
  switch (s.state) {
    case 0:
      if (s.pending.load() == 2) {
        if (--s.idle <= 0) { std::lock_guard<std::mutex> l(s.m); s.pending = 0; s.done = 1; s.cv.notify_all(); }
        break;
      }
      if (s.pending.load()) { top->hd_cs_n = 0; top->hd_sck = 0; s.cnt = 2 * SPI_H; s.byte = 0; s.bit = 0; s.state = 1; }
      break;
    case 1:
      if (--s.cnt == 0) { top->hd_mosi = (s.tx[0] >> 7) & 1; s.cnt = SPI_H; s.state = 2; }
      break;
    case 2:                                     // SCK low: sample MISO, then the rising edge
      if (--s.cnt == 0) { s.inb = (uint8_t)(s.inb << 1 | (top->hd_miso & 1)); top->hd_sck = 1; s.cnt = SPI_H; s.state = 3; }
      break;
    case 3:
      if (--s.cnt == 0) {
        top->hd_sck = 0;
        if (++s.bit == 8) { s.rx[s.byte] = s.inb; s.bit = 0; s.byte++; }
        if (s.byte == s.len) { s.cnt = SPI_H; s.state = 4; }
        else { top->hd_mosi = (s.tx[s.byte] >> (7 - s.bit)) & 1; s.cnt = SPI_H; s.state = 2; }
      }
      break;
    case 4:
      if (--s.cnt == 0) { top->hd_cs_n = 1; s.cnt = 4 * SPI_H; s.state = 5; }
      break;
    case 5:
      if (--s.cnt == 0) {
        s.state = 0; s.xfers++; s.bytes += s.len;
        std::lock_guard<std::mutex> l(s.m); s.pending = 0; s.done = 1; s.cv.notify_all();
      }
      break;
  }
}
static struct hdd g_hdd;
static long g_die_at = -1;            // HDD_DIE_AT_XFER: the server "crashes" at this transaction
static std::atomic<long> g_xfer_n{0};
static int b_xfer(void*, const uint8_t* tx, uint8_t* rx, int len) {
  static long die_cmd = getenv("HDD_DIE_AT_CMD") ? atol(getenv("HDD_DIE_AT_CMD")) : -1, die_from = -1;
  if (die_cmd > 0 && (long)g_hdd.cmds >= die_cmd && die_from < 0) die_from = g_xfer_n + 40;   // mid data phase
  if (die_from > 0 && g_xfer_n + 1 == die_from) { g_die_at = die_from; die_cmd = -1; die_from = 0; }
  static long die_put = getenv("HDD_DIE_IN_PUT") ? atol(getenv("HDD_DIE_IN_PUT")) : -1;
  static long die_get = getenv("HDD_DIE_IN_GET") ? atol(getenv("HDD_DIE_IN_GET")) : -1;
  if (die_get > 0 && (long)g_hdd.cmds >= die_get && len > 500 && tx[0] == 0x41) {   // draining a written block
    die_get = -1;
    fprintf(stderr, "hddsrv: simulated crash at the first GET of ATA command %llu (tick %llu)\n",
            (unsigned long long)g_hdd.cmds, (unsigned long long)g_tick);
    return -1;
  }
  if (die_put > 0 && (long)g_hdd.cmds >= die_put && len > 500 && tx[0] == 0x30) {   // inside a data block
    die_put = -1;
    fprintf(stderr, "hddsrv: simulated crash at the first PUT of ATA command %llu (tick %llu)\n",
            (unsigned long long)g_hdd.cmds, (unsigned long long)g_tick);
    return -1;
  }
  if (++g_xfer_n == g_die_at) { fprintf(stderr, "hddsrv: simulated crash at transaction %ld (tick %llu)\n", g_die_at,
                                        (unsigned long long)g_tick); return -1; }
  std::unique_lock<std::mutex> l(g_spi.m);
  g_spi.tx = tx; g_spi.rx = rx; g_spi.len = len; g_spi.done = 0; g_spi.pending = 1;
  g_spi.cv.wait(l, [] { return g_spi.done || g_hdd_stop.load(); });
  static int dbg = getenv("HDD_SPIDBG") ? atoi(getenv("HDD_SPIDBG")) : 0;
  if (dbg > 0) {                                  // the first HDD_SPIDBG transactions, for debugging
    dbg--;
    fprintf(stderr, "spi %d bytes tx", len);
    for (int i = 0; i < len && i < 6; i++) fprintf(stderr, " %02x", tx[i]);
    fprintf(stderr, " rx");
    for (int i = 0; i < len && i < 6; i++) fprintf(stderr, " %02x", rx[i]);
    fprintf(stderr, " (tick %llu)\n", (unsigned long long)g_tick);
  }
  return g_hdd_stop.load() ? -1 : 0;
}
static int b_xfer_batch(void* c, const struct hdd_seg* seg, int n) {
  for (int i = 0; i < n; i++) {
    static uint8_t scratch[4100];
    if (b_xfer(c, seg[i].tx, seg[i].rx ? seg[i].rx : scratch, seg[i].len)) return -1;
    if (seg[i].delay_us) {
      std::unique_lock<std::mutex> l(g_spi.m);
      g_spi.idle = (long)seg[i].delay_us * g_fclk_mhz; g_spi.done = 0; g_spi.pending = 2;
      g_spi.cv.wait(l, [] { return g_spi.done || g_hdd_stop.load(); });
      if (g_hdd_stop.load()) return -1;
    }
  }
  return 0;
}
static int b_wait_att(void*, int ms) {
  std::unique_lock<std::mutex> l(g_spi.m);
  if (g_spi.att.load()) return 1;
  g_spi.att_cv.wait_for(l, std::chrono::milliseconds(ms), [] { return g_spi.att.load() || g_hdd_stop.load(); });
  return g_hdd_stop.load() ? -1 : (g_spi.att.load() ? 1 : 0);
}
static int b_rd(void*, uint64_t lba, unsigned n, uint8_t* b) {
  return pread(g_hdd_fd, b, 512 * n, (off_t)(lba * 512)) == (ssize_t)(512 * n) ? 0 : -1;
}
static int b_wr(void*, uint64_t lba, unsigned n, const uint8_t* b) {
  return pwrite(g_hdd_fd, b, 512 * n, (off_t)(lba * 512)) == (ssize_t)(512 * n) ? 0 : -1;
}
static uint8_t g_state[64]; static int g_state_len = 0;     // the server's in-flight record (survives restarts)
static void b_persist(void*, const void* rec, int len) { memcpy(g_state, rec, len); g_state_len = len; }
static int b_restore(void*, void* rec, int len) { if (g_state_len != len) return -1; memcpy(rec, g_state, len); return 0; }
static void b_log(void*, const char* m) { fprintf(stderr, "hddsrv: %s (tick %llu)\n", m, (unsigned long long)g_tick); }
static std::atomic<unsigned> g_frame_a{0};
static void hdd_thread() {
  int r;
  if (getenv("HDD_START_FRAME")) {      // the server appears late (after Kickstart's probe)
    unsigned f = (unsigned)atoi(getenv("HDD_START_FRAME"));
    while (g_frame_a.load() < f && !g_hdd_stop.load()) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    fprintf(stderr, "hddsrv: starting at frame %u\n", g_frame_a.load());
  }
  if (getenv("HDD_DIE_AT_XFER")) g_die_at = atol(getenv("HDD_DIE_AT_XFER"));
restart:
  while ((r = hdd_init(&g_hdd)) != 0 && !g_hdd_stop.load())
    std::this_thread::sleep_for(std::chrono::milliseconds(20));      // until the Amiga's reset is over
  fprintf(stderr, "hddsrv: drive ready, %llu sectors, %u/%u/%u (tick %llu)\n", (unsigned long long)g_hdd.nblk,
          g_hdd.cyls, g_hdd.heads, g_hdd.spt, (unsigned long long)g_tick);
  if (getenv("HDD_LINKTEST")) {          // loopback through hdd_spi + ide.v's buffer, no Amiga involved
    int rounds = atoi(getenv("HDD_LINKTEST")), bad = 0, errs = 0;
    unsigned ns = getenv("HDD_LINKN") ? (unsigned)atoi(getenv("HDD_LINKN")) : 1;   // sectors per round (1..16)
    static uint8_t a[16 * 512], b[16 * 512];
    if (ns < 1 || ns > 16) ns = 1;
    for (int i = 0; i < rounds; i++) {
      for (unsigned k = 0; k < 512 * ns; k++) a[k] = (uint8_t)(k * 7 + i * 13 + (k >> 3) + (k >> 9) * 29);
      int r1 = hdd_engine(&g_hdd, 0x32, 0, 0, 0), r2 = r1 ? 9 : hdd_put_n(&g_hdd, a, ns);
      int r3 = r2 ? 9 : hdd_engine(&g_hdd, 0x32, 0, 0, 0), r4 = r3 ? 9 : hdd_get_n(&g_hdd, b, ns);
      if (r1 || r2 || r3 || r4) {
        errs++; fprintf(stderr, "linktest round %d: ptr0 %d put %d ptr0 %d get %d\n", i, r1, r2, r3, r4); continue;
      }
      for (unsigned k = 0; k < 512 * ns; k++) if (a[k] != b[k]) { if (bad < 8) fprintf(stderr, "  byte %u: %02x -> %02x\n", k, a[k], b[k]); bad++; }
    }
    fprintf(stderr, "linktest: %u sectors per round, batch retries %llu\n", ns, (unsigned long long)g_hdd.batch_retries);
    fprintf(stderr, "linktest: %d rounds, %d engine errors, %d bytes differ (tick %llu)\n", rounds, errs, bad,
            (unsigned long long)g_tick);
  }
  if (hdd_serve(&g_hdd, (volatile int*)&g_hdd_stop) < 0 && !g_hdd_stop.load()) {
    if (getenv("HDD_NORESTART")) {      // the server is gone for good (what does the Amiga do?)
      fprintf(stderr, "hddsrv: gone for good (tick %llu)\n", (unsigned long long)g_tick);
      return;
    }
    fprintf(stderr, "hddsrv: restarting after a link error (tick %llu)\n", (unsigned long long)g_tick);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    goto restart;
  }
}
static bool g_active = false;
static Rec g_cur;
static uint64_t g_nrec = 0;
static int g_phase = 0;       // ticks since clk7_en
static int g_debug_ticks = 0; // print per-tick state for this many ticks after cfg_done
static uint64_t g_debug_from = ~0ull;
static int g_last_vpos = -1;
static uint32_t g_frame = 0;

// df0 image (words as in the board's HyperRAM), read by tb_top's Avalon slave for adf_track_engine
static std::vector<uint16_t> g_adf;
static uint64_t g_adf_reads = 0;
extern "C" int adf_rd(int a) {
  if (g_adf_reads++ == 0) fprintf(stderr, "df0: first image read at frame %u (word %d)\n", g_frame, a);
  return (a >= 0 && (size_t)a < g_adf.size()) ? g_adf[a] : 0;
}
static int load_adf(const char* fn) {
  FILE* f = fopen(fn, "rb");
  if (!f) { perror(fn); exit(1); }
  std::vector<uint8_t> b(2 << 20); size_t n = fread(b.data(), 1, b.size(), f); fclose(f);
  if (n % 5632 || n / 5632 < 160 || n / 5632 > 166) { fprintf(stderr, "%s: not an ADF (%zu bytes)\n", fn, n); exit(1); }
  g_adf.assign(n / 2, 0);
  // HyperRAM layout of the board (adf_mount_wrapper): the first byte of each pair in bits 7:0
  for (size_t i = 0; i < n; i += 2) g_adf[i / 2] = (uint16_t)(b[i] | (b[i + 1] << 8));
  fprintf(stderr, "df0: %s, %zu tracks\n", fn, n / 5632);
  return (int)(n / 5632);
}

extern "C" void trace_tick(int phase, int addr, int oe_n, int we_n, int src, int fm, int hpos,
                           int vpos, int dbr, int c1c3) {
  if (phase & 2) g_phase = 0; else g_phase++;
  bool acc = (!oe_n) || (!we_n);
  if (g_debug_ticks > 0 && g_tick >= g_debug_from) {
    g_debug_ticks--;
    printf("t=%llu ph=%d c1c3=%d%d oe=%d we=%d a=%06x src=%d dbr=%d h=%d v=%d\n",
           (unsigned long long)g_tick, g_phase, (c1c3 >> 1) & 1, c1c3 & 1, oe_n, we_n,
           addr << 1, src, dbr, hpos, vpos);
  }
  if (g_active) {
    bool same = acc && (uint32_t)addr == g_cur.addr && ((g_cur.flags & 1) == (we_n ? 0 : 1)) &&
                g_cur.src == src && g_cur.len < 255;
    if (same) { g_cur.len++; return; }
    if (g_out) fwrite(&g_cur, sizeof g_cur, 1, g_out);
    g_nrec++;
    g_active = false;
  }
  if (acc) {
    g_active = true;
    g_cur.tick = (uint32_t)g_tick;
    g_cur.addr = addr;
    g_cur.len = 1;
    g_cur.flags = (we_n ? 0 : 1) | (fm << 4);
    g_cur.src = src;
    g_cur.phase = (g_phase & 3) | (dbr ? 4 : 0);
    g_cur.hpos = hpos;
    g_cur.vpos = vpos;
  }
}

static size_t g_rom_bytes = 0;
static bool load_rom(const char* fn, uint16_t* dst, size_t words) {
  FILE* f = fopen(fn, "rb");
  if (!f) { perror(fn); return false; }
  std::vector<uint8_t> b(words * 2, 0);
  size_t n = fread(b.data(), 1, b.size(), f);
  fclose(f);
  size_t nw = n / 2;
  for (size_t i = 0; i < words; i++) {
    size_t j = i % (nw ? nw : 1);   // mirror a 256 KB image
    dst[i] = (uint16_t)((b[2 * j] << 8) | b[2 * j + 1]);
  }
  fprintf(stderr, "loaded %s: %zu bytes\n", fn, n);
  g_rom_bytes = n;
  return true;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const char* kick = nullptr; const char* ext = nullptr; const char* out = nullptr;
  const char* inj = nullptr; uint32_t inj_addr = 0x40000; int inj_frame = -1;
  const char* shot = nullptr; int shot_every = 0;
  int frames = 10; int trace_from = 0;
  const char* save_fn = nullptr; int save_frame = -1; const char* restore_fn = nullptr;
  unsigned chipset = 0x00, mem = 0x03, cpu = 0x00;
  std::vector<int> shot_frames; bool px28 = false;
  bool use_cache = false, stock020 = false; int shrink = 0, lat_min = 20, lat_span = 40;
  const char* hreq_fn = nullptr; const char* hrsp_fn = nullptr;
  const char* preload_fn = nullptr; uint32_t preload_addr = 0;
  const char* dump_fn = nullptr; uint32_t dump_addr = 0, dump_len = 0;
  int64_t stop_addr = -1; uint32_t stop_val = 0;
  const char* cput_fn = nullptr; int cput_from = 0, cput_to = 0;
  const char* adf_fn = nullptr; const char* adf2_fn = nullptr; int adf2_frame = -1; bool fturbo = false;
  bool shot_last = false;
  int reset_at = -1; uint64_t reset_cyc = 0;
  const char* hdf_fn = nullptr; bool hdf_ro = false, ide_only = false, hdd_verbose = false;   // a1200-ide
  double inj_p = 0; int inj_k = 0;   // --reset-at FRAME: an Amiga reset (rst_ext) mid-run
  unsigned pf_mask = 0;          // --pf MASK: the cache's prefetch enables (b0 bpl .. b6 cpu)
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto nx = [&]() { return argv[++i]; };
    if (a == "--kick") kick = nx();
    else if (a == "--ext") ext = nx();
    else if (a == "--out") out = nx();
    else if (a == "--frames") frames = atoi(nx());
    else if (a == "--trace-from") trace_from = atoi(nx());
    else if (a == "--chipset") chipset = strtoul(nx(), 0, 0);
    else if (a == "--mem") mem = strtoul(nx(), 0, 0);
    else if (a == "--inject") inj = nx();
    else if (a == "--inject-addr") inj_addr = strtoul(nx(), 0, 0);
    else if (a == "--inject-frame") inj_frame = atoi(nx());
    else if (a == "--shot") shot = nx();
    else if (a == "--shot-every") shot_every = atoi(nx());
    else if (a == "--save") save_fn = nx();
    else if (a == "--save-frame") save_frame = atoi(nx());
    else if (a == "--restore") restore_fn = nx();
    else if (a == "--cpu") cpu = strtoul(nx(), 0, 0);
    else if (a == "--shot-frames") { std::string l = nx(); size_t p = 0;
      while (p < l.size()) { size_t q = l.find(',', p); if (q == std::string::npos) q = l.size();
        shot_frames.push_back(atoi(l.substr(p, q - p).c_str())); p = q + 1; } }
    else if (a == "--px28") px28 = true;
    else if (a == "--cache") use_cache = true;
    else if (a == "--host-link") { hreq_fn = nx(); hrsp_fn = nx(); }
    else if (a == "--menu-id") g_menu_id = strtoul(nx(), 0, 16);
    else if (a == "--stock") stock020 = true;
    else if (a == "--shrink") shrink = atoi(nx());
    else if (a == "--lat") { lat_min = atoi(nx()); lat_span = atoi(nx()); }
    else if (a == "--preload") { preload_fn = nx(); preload_addr = strtoul(nx(), 0, 0); }
    else if (a == "--dump") { dump_addr = strtoul(nx(), 0, 0); dump_len = strtoul(nx(), 0, 0); dump_fn = nx(); }
    else if (a == "--stop") { stop_addr = strtoll(nx(), 0, 0); stop_val = strtoul(nx(), 0, 0); }
    else if (a == "--cputrace") { cput_fn = nx(); cput_from = atoi(nx()); cput_to = atoi(nx()); }
    else if (a == "--adf") adf_fn = nx();
    else if (a == "--adf2") { adf2_frame = atoi(nx()); adf2_fn = nx(); }
    else if (a == "--floppy-turbo") fturbo = true;
    else if (a == "--hdf") hdf_fn = nx();
    else if (a == "--hdf-ro") hdf_ro = true;
    else if (a == "--ide") ide_only = true;
    else if (a == "--hdd-verbose") hdd_verbose = true;
    else if (a == "--stall-inject") { inj_p = atof(nx()); inj_k = atoi(nx()); }
    else if (a == "--shot-last") shot_last = true;
    else if (a == "--reset-at") reset_at = atoi(nx());
    else if (a == "--pf") pf_mask = strtoul(nx(), 0, 0);
    else if (a == "--debug") { g_debug_ticks = atoi(nx()); g_debug_from = strtoull(nx(), 0, 0); }
  }
  Vtb_top* top = new Vtb_top;
  auto* r = top->rootp;
  if (kick) {
    load_rom(kick, (uint16_t*)&r->tb_top->kickmem[0], 262144);
    // stage 2b: the Kickstart in the DDR3 model where the QNICE load port puts it (backing words
    // 1.25M.., the cache's kick lines); 256 KB images mirrored like the ROM model
    uint16_t* km = (uint16_t*)&r->tb_top->kickmem[0];
    uint16_t* dd = (uint16_t*)&r->tb_top->ddr[0];
    if (!hreq_fn) for (size_t i = 0; i < 262144; i++) dd[0x140000 + i] = km[i];
    else fprintf(stderr, "--host-link: %s only as the cache check's shadow; DDR3 gets the Kickstart from the master\n", kick);
    top->kick512 = g_rom_bytes > 262144;
  }
  if (ext)  load_rom(ext,  (uint16_t*)&r->tb_top->extmem[0], 262144);
  if (preload_fn) {   // a program in chip RAM before the machine starts (with a boot ROM that jumps to it)
    FILE* f = fopen(preload_fn, "rb");
    if (!f) { perror(preload_fn); return 1; }
    std::vector<uint8_t> b(2 << 20); size_t n = fread(b.data(), 1, b.size(), f); fclose(f);
    uint16_t* cm = (uint16_t*)&r->tb_top->chipmem[0];
    uint16_t* dd = (uint16_t*)&r->tb_top->ddr[0];
    for (size_t i = 0; i < n; i += 2) {
      uint16_t w = (uint16_t)((b[i] << 8) | b[i + 1]);
      cm[((preload_addr + i) >> 1) & 0xfffff] = w;          // shadow (C++ peeks, self-check)
      dd[((preload_addr + i) >> 1) & 0xfffff] = w;          // DDR3 model behind the cache
    }
    fprintf(stderr, "preloaded %s: %zu bytes at %06x\n", preload_fn, n, preload_addr);
  }
  top->cfg_chipset = chipset; top->cfg_cpu = cpu; top->cfg_mem = mem; top->cfg_floppy = fturbo ? 1 : 0;
  top->disk_mounted = 0; top->disk_tracks = 0;
  if (adf_fn) { top->disk_tracks = load_adf(adf_fn); top->disk_mounted = 1; }
  top->rst_ext = 1; top->bd_we = 0;
  // a1200-ide: Gayle on with --hdf (a drive) or --ide (the port without a drive)
  top->ide_on = (hdf_fn || ide_only) ? 1 : 0; top->hd_cs_n = 1; top->hd_sck = 0; top->hd_mosi = 0;
  std::thread hdd_th;
  if (hdf_fn) {
    g_hdd_fd = open(hdf_fn, hdf_ro ? O_RDONLY : O_RDWR);
    if (g_hdd_fd < 0) { fprintf(stderr, "cannot open %s\n", hdf_fn); return 1; }
    memset(&g_hdd, 0, sizeof g_hdd);
    g_hdd.io.xfer = b_xfer; g_hdd.io.wait_att = b_wait_att; g_hdd.io.rd = b_rd; g_hdd.io.wr = b_wr;
    g_hdd.io.log = b_log;
    g_hdd.io.persist = b_persist; g_hdd.io.restore = b_restore;
    g_hdd.nblk = (uint64_t)lseek(g_hdd_fd, 0, SEEK_END) / 512; g_hdd.ro = hdf_ro; g_hdd.verbose = getenv("HDD_VV") ? 2 : hdd_verbose;
    g_hdd.fast = getenv("HDD_SLOW") ? 0 : 1;          // HDD_SLOW: reads without ide.v's fast mode
    g_hdd.batch = getenv("HDD_NOBATCH") ? 0 : 1;      // HDD_NOBATCH: one transaction per call
    g_hdd.delay_cut = getenv("HDD_DELAYCUT") ? atoi(getenv("HDD_DELAYCUT")) : 0;   // tests of the batch fallback
    g_hdd.io.xfer_batch = b_xfer_batch;
    g_fclk_mhz = use_cache ? 100 : 28;
    hdd_th = std::thread(hdd_thread);
    fprintf(stderr, "hdf: %s, %llu sectors%s\n", hdf_fn, (unsigned long long)g_hdd.nblk, hdf_ro ? " (read-only)" : "");
  }
  std::vector<uint8_t> prog;
  if (inj) {
    FILE* f = fopen(inj, "rb");
    if (!f) { perror(inj); return 1; }
    uint8_t buf[65536]; size_t n = fread(buf, 1, sizeof buf, f); fclose(f);
    prog.assign(buf, buf + n);
    if (prog.size() & 1) prog.push_back(0);
  }
  // 320 x 2 (hires) x 313 screenshot buffer, sampled at 14 MHz
  const int W = px28 ? 1920 : 960, H = 320;
  FILE* cput = cput_fn ? fopen(cput_fn, "w") : nullptr;
  int prev_cs = 1; uint64_t req_tick = 0; uint32_t req_addr = 0;
  std::vector<uint8_t> fb(W * H * 3, 0);
  int col = 0, pcol = 0, prow = -1;
  bool g_prev_hs = true, g_prev_vs = true;
  uint64_t cyc0 = 0;
  if (restore_fn) {
    VerilatedRestore rs; rs.open(restore_fn); rs >> *top; rs.close();
    std::string sf = std::string(restore_fn) + ".cpp";
    FILE* f = fopen(sf.c_str(), "rb");
    if (!f || fread(&g_tick, 8, 1, f) != 1 || fread(&g_frame, 4, 1, f) != 1 || fread(&g_last_vpos, 4, 1, f) != 1 ||
        fread(&g_phase, 4, 1, f) != 1) { fprintf(stderr, "restore side file\n"); return 1; }
    fclose(f);
    top->rst_ext = 0; cyc0 = 1000;
    fprintf(stderr, "restored %s at frame %u tick %llu\n", restore_fn, g_frame, (unsigned long long)g_tick);
  }
  top->pf_en = pf_mask;
  top->stock020 = stock020; top->use_cache = use_cache; top->cache_on = use_cache; top->shrink = shrink;
  top->lat_min = lat_min; top->lat_span = lat_span; top->cache_reset = use_cache;
  // stage 3, --cache: three clocks.  Source clock 31.310345 MHz (stall_clk.vhd), MIG ui_clk 100 MHz;
  // the machine clock is the source clock gated like the BUFGCE: a source edge reaches clk only
  // when the cache's combinational miss is low just before it.  Machine time (g_tick) counts the
  // machine edges only, so pictures and traces are in machine time as without the cache.
  const uint64_t SRC_H = 15969, UI_H = 5000, Q_H = 10000;   // half periods in ps
  uint64_t t_src = SRC_H, t_ui = UI_H, t_q = Q_H, src_edges = 0, stalled = 0, q_edges = 0;
  bool src_lvl = false, ui_lvl = false, q_lvl = false;
  const bool host = hreq_fn != nullptr;
  if (host) {
    if (!use_cache) { fprintf(stderr, "--host-link needs --cache (the Kickstart port is the cache's)\n"); return 1; }
    fprintf(stderr, "--host-link: waiting for the client on %s / %s\n", hreq_fn, hrsp_fn);
    g_hreq = fopen(hreq_fn, "r"); g_hrsp = fopen(hrsp_fn, "w");
    if (!g_hreq || !g_hrsp) { perror("--host-link"); return 1; }
    top->host_on = 1; top->q_rst = 1;
    frames = 1 << 30;
  }
  // the master's clock: the PUT queue's front is presented first-word-fall-through; s_pop (set at the
  // previous edge) takes it, m_push (set at the previous edge) delivers an answer byte
  auto q_edge = [&]() {
    q_lvl = !q_lvl; t_q += Q_H;
    if (q_lvl) {
      if (top->hs_pop && !g_putq.empty()) g_putq.pop_front();
      if (top->hm_push) g_getq.push_back(top->hm_data);
      // HOST_RESET: as the bridge, the queue is empty in the cycle the master sees the clear (a request
      // after R may already be queued here, which on the board comes in a later SPI transaction)
      top->hs_valid = !g_putq.empty() && !g_hclr;
      top->hs_data = g_putq.empty() ? 0 : g_putq.front();
      top->hm_full = g_getq.size() >= 4092;
      top->h_clr = g_hclr; g_hclr = false;
      if (++q_edges == 16) top->q_rst = 0;
    }
    top->q_clk = q_lvl; top->eval();
  };
  int inj_left = 0; uint64_t inj_n = 0;
  auto machine_edge = [&]() {
    if (!use_cache) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); if (hdf_fn) spi_step(top); return; }
    for (;;) {
      if (host && t_q <= t_ui && t_q <= t_src) { q_edge(); continue; }
      if (t_ui <= t_src) {
        ui_lvl = !ui_lvl; top->ui_clk = ui_lvl; top->eval(); t_ui += UI_H;
        if (ui_lvl && hdf_fn) spi_step(top);
        continue;
      }
      src_lvl = !src_lvl; t_src += SRC_H;
      if (!src_lvl) { top->src_clk = 0; top->clk = 0; top->eval(); continue; }
      src_edges++;
      if (src_edges == 64) top->cache_reset = 0;      // the full reset: the cache latches its mode
      bool pass = !top->miss;
      // --stall-inject P K: the stall injector's effect in the bench: with probability P per source edge the
      // machine clock stops for K source edges (ui_clk and so the disk link keep running)
      if (pass && inj_left > 0) { inj_left--; pass = false; }
      else if (pass && inj_p > 0 && (double)rand() / RAND_MAX < inj_p) { inj_left = inj_k - 1; pass = false; inj_n++; }
      top->src_clk = 1; if (pass) top->clk = 1; top->eval();
      if (pass) return;
      stalled++;
    }
  };
  // HDD_RESET_AT_CMD=N[,S][,kbd|cpu]: once the server has started its N-th ATA command and moved S more
  // sectors (default 0: at the command's start), a reset for 200 ticks: full (rst_ext, hdd_spi too: the
  // board's M2M/menu reset), kbd (rst_ext but not hdd_spi's mrst: the board's keyboard reset, which is
  // amiga_rst only) or cpu (minimig _cpu_reset_in: the 68k RESET instruction; resets Gayle, not the CPU)
  const char* rs = getenv("HDD_RESET_AT_CMD");
  long rst_cmd = rs ? atol(rs) : -1, rst_sect = (rs && strchr(rs, ',')) ? atol(strchr(rs, ',') + 1) : 0, rst_base = -1;
  int rst_kind = !rs ? 0 : strstr(rs, "kbd") ? 1 : strstr(rs, "cpu") ? 2 : 0;
  uint64_t kbd_until = 0;
  top->kbd_rst = 0; top->cpu_rst = 0;
  auto hex_line = [&](const std::vector<uint8_t>& b) {
    std::string o; o.reserve(b.size() * 2 + 1);
    static const char* H = "0123456789ABCDEF";
    for (uint8_t v : b) { o += H[v >> 4]; o += H[v & 15]; }
    fprintf(g_hrsp, "%s\n", o.c_str()); fflush(g_hrsp);
  };
  // one request; false = quit
  auto host_cmd = [&]() -> bool {
    static std::vector<char> line(1 << 20);
    if (!fgets(line.data(), line.size(), g_hreq)) return false;
    char c = line[0]; const char* arg = line.data() + 1; while (*arg == ' ') arg++;
    if (c == 'S') {
      std::vector<uint8_t> st(82, 0);
      st[0] = 0x4D; st[1] = 0x65; st[2] = 0x04; st[52] = 0x03; st[72] = 0x01;
      unsigned fr = 8192 - g_putq.size(), fl = g_getq.size();
      st[73] = fr >> 8; st[74] = fr & 255; st[75] = fl >> 8; st[76] = fl & 255;
      st[77] = (top->h_flags & 0xFE) | (g_hovf ? 1 : 0);
      st[78] = g_menu_id >> 24; st[79] = g_menu_id >> 16; st[80] = g_menu_id >> 8; st[81] = g_menu_id;
      hex_line(st);
    } else if (c == 'P') {
      for (const char* p = arg; isxdigit(p[0]) && isxdigit(p[1]); p += 2) {
        unsigned v; sscanf(p, "%2x", &v);
        if (g_putq.size() < 8192) g_putq.push_back(v); else g_hovf = true;
      }
      fprintf(g_hrsp, "OK\n"); fflush(g_hrsp);
    } else if (c == 'G') {
      size_t n = strtoul(arg, 0, 0); std::vector<uint8_t> b(n, 0);
      for (size_t i = 0; i < n && !g_getq.empty(); i++) { b[i] = g_getq.front(); g_getq.pop_front(); }
      hex_line(b);
    } else if (c == 'R') {
      g_putq.clear(); g_getq.clear(); g_hovf = false; g_hclr = true;
      fprintf(g_hrsp, "OK\n"); fflush(g_hrsp);
    } else if (c == 'W') {
      g_hbudget = strtoull(arg, 0, 0); g_hwait = true;
      if (!g_hbudget) { fprintf(g_hrsp, "OK %u %llu\n", g_frame, (unsigned long long)g_tick); fflush(g_hrsp); g_hwait = false; }
    } else if (c == 'Q') return false;
    else { fprintf(g_hrsp, "ERR\n"); fflush(g_hrsp); }
    return true;
  };
  for (uint64_t cyc = cyc0;; cyc++) {
    if (host) {
      if (g_hwait && g_hbudget == 0) {
        fprintf(g_hrsp, "OK %u %llu\n", g_frame, (unsigned long long)g_tick); fflush(g_hrsp); g_hwait = false;
      }
      bool quit = false;
      while (g_hbudget == 0) if (!host_cmd()) { quit = true; break; }
      if (quit) { fprintf(stderr, "--host-link: client gone at frame %u tick %llu\n", g_frame, (unsigned long long)g_tick); break; }
      g_hbudget--;
    }
    machine_edge();
    if (rst_cmd > 0 && rst_base < 0 && (long)g_hdd.cmds >= rst_cmd) rst_base = (long)(g_hdd.rd_sect + g_hdd.wr_sect);
    if (rst_cmd > 0 && rst_base >= 0 && (long)(g_hdd.rd_sect + g_hdd.wr_sect) >= rst_base + rst_sect) {
      rst_cmd = -1;
      fprintf(stderr, "%s reset at ATA command %llu after %ld sectors of it, frame %u tick %llu\n",
              rst_kind == 1 ? "keyboard" : rst_kind == 2 ? "RESET-instruction" : "full", (unsigned long long)g_hdd.cmds,
              rst_sect, g_frame, (unsigned long long)g_tick);
      if (rst_kind == 1) { top->kbd_rst = 1; top->rst_ext = 1; reset_cyc = cyc; kbd_until = cyc + 200; }
      else if (rst_kind == 2) { top->cpu_rst = 1; kbd_until = cyc + 200; }
      else { top->rst_ext = 1; reset_cyc = cyc; }
    }
    if (kbd_until && cyc >= kbd_until) { top->kbd_rst = 0; top->cpu_rst = 0; kbd_until = 0; }
    g_tick++;
    if (cyc == 200) top->rst_ext = 0;
    // --host-link: the core is held while the master's CSR b0 is set (QNICE's csr_reset)
    if (host && !reset_cyc && cyc >= 200) top->rst_ext = top->h_csr & 1;
    // --host-link: at every release, the menu bits (CFM) must describe the machine the bench's options
    // configure (the bench does not decode CFM itself: mega65.vhd's decode is checked on the board);
    // the expected userio payloads as mega65.vhd p_topo + amiga_config.vhd derive them
    if (host) {
      static bool held = true;
      bool now = top->h_csr & 1;
      if (held && !now) {
        auto bit = [&](int n) -> unsigned { return (top->h_cfm[n / 32] >> (n % 32)) & 1; };
        unsigned c512 = bit(73), c1m = bit(74), ecs = bit(77), aga = bit(78), f2 = bit(80), f4 = bit(81),
                 f8 = bit(82), z3 = bit(83), c020 = bit(86), ide = bit(87);
        unsigned c2m = aga;                                  // AGA = 2 MB chip in the cache (stage 3)
        unsigned slow = !c512 && !c1m && !c2m;
        unsigned fs = f8 ? 3 : (f4 || z3) ? 2 : f2 ? 1 : 0;
        unsigned e_chip = ((ecs || c1m || c2m) ? 8 : 0) | ((aga && c2m) ? 16 : 0);
        unsigned e_cpu = c020 ? 3 : 0;
        unsigned e_mem = (slow ? 4 : 0) | ((c1m || c2m) ? 1 : 0) | (c2m ? 2 : 0) | (fs << 4);
        bool ok = e_chip == (top->cfg_chipset & 0x18) && e_cpu == (top->cfg_cpu & 3) &&
                  e_mem == (top->cfg_mem & 0x37) && (bool)ide == (bool)top->ide_on;
        fprintf(stderr, "--host-link: release at frame %u: CFM topology -> chipset %02x cpu %02x mem %02x ide %u; "
                "bench options chipset %02x cpu %02x mem %02x ide %u: %s\n", g_frame, e_chip, e_cpu, e_mem, ide,
                top->cfg_chipset, top->cfg_cpu, top->cfg_mem, top->ide_on, ok ? "match" : "MISMATCH");
        if (!ok) { fprintf(stderr, "FAIL: the menu bits and the bench configuration disagree\n"); exit(2); }
      }
      held = now;
    }
    if (reset_cyc && cyc == reset_cyc + 200) { top->rst_ext = 0; reset_cyc = 0; }
    int vpos = top->o_vpos;
    if (cput && (int)g_frame >= cput_from && (int)g_frame <= cput_to) {
      // one line per CPU request: start tick, ack tick, state, address, beam position at start
      int cs = top->o_cpustate;
      if (cs != 1 && prev_cs == 1) { req_tick = g_tick; req_addr = top->o_cpu_addr32; }
      if (cs != 1 && top->o_cpu_ack) {
        fprintf(cput, "%llu %llu %d %08x %d %d\n", (unsigned long long)req_tick, (unsigned long long)g_tick,
                cs, req_addr, (int)top->o_hpos, (int)top->o_vpos);
        prev_cs = 1;   // the next request starts in a later clock
      } else prev_cs = cs;
    }
    // picture rows follow Denise's syncs (a row starts at the falling edge of /HSYNC, row 0 is
    // the first line after the falling edge of /VSYNC), so the window never wraps into the next row
    {
      bool hs = top->o_hsync_n, vs = top->o_vsync_n;
      if (g_prev_hs && !hs) { pcol = 0; prow++; }
      if (g_prev_vs && !vs) prow = -1;
      g_prev_hs = hs; g_prev_vs = vs;
    }
    if (px28 || (g_tick & 1) == 0) {
      if (prow >= 0 && prow < H && pcol < W) {
        uint8_t* p = &fb[(prow * W + pcol) * 3];
        p[0] = top->o_red_green >> 16; p[1] = (top->o_red_green >> 8) & 0xff; p[2] = top->o_red_green & 0xff;
      }
      pcol++;
    }
    if (false) {
      int row = vpos;
      if (row < H && col < W) {
        uint8_t* p = &fb[(row * W + col) * 3];
        p[0] = top->o_red_green >> 16; p[1] = (top->o_red_green >> 8) & 0xff; p[2] = top->o_red_green & 0xff;
      }
      col++;
    }
    if (vpos != g_last_vpos) {
      col = 0;
      if (vpos == 0 && g_last_vpos > 0) {
        g_frame++;
        g_frame_a = g_frame;
        if (g_frame % 10 == 0) fprintf(stderr, "frame %u tick %llu recs %llu pc %06x\n", g_frame,
                                       (unsigned long long)g_tick, (unsigned long long)g_nrec,
                                       top->o_cpu_addr << 1);
        if ((int)g_frame == trace_from && out) {
          g_out = fopen(out, "wb");
          fprintf(stderr, "trace starts at frame %u tick %llu\n", g_frame,
                  (unsigned long long)g_tick);
        }
        if ((int)g_frame == reset_at) {
          top->rst_ext = 1; reset_cyc = cyc;
          fprintf(stderr, "reset at frame %u (rst_ext 200 ticks; the cache and the DDR3 model keep their state)\n", g_frame);
        }
        if (adf2_fn && (int)g_frame == adf2_frame) { top->disk_mounted = 0; fprintf(stderr, "df0 ejected (frame %u)\n", g_frame); }
        if (adf2_fn && (int)g_frame == adf2_frame + 25) { top->disk_tracks = load_adf(adf2_fn); top->disk_mounted = 1; }
        bool want = shot && shot_every && g_frame % shot_every == 0;
        for (int f : shot_frames) if (shot && (int)g_frame == f) want = true;
        if (want) {
          char fn[512]; snprintf(fn, sizeof fn, "%s_%04u.ppm", shot, g_frame);
          FILE* f = fopen(fn, "wb");
          fprintf(f, "P6 %d %d 255\n", W, H); fwrite(fb.data(), 1, fb.size(), f); fclose(f);
        }
        if ((int)g_frame == save_frame && save_fn) {
          VerilatedSave os; os.open(save_fn); os << *top; os.close();
          std::string sf = std::string(save_fn) + ".cpp";
          FILE* f = fopen(sf.c_str(), "wb");
          fwrite(&g_tick, 8, 1, f); fwrite(&g_frame, 4, 1, f); fwrite(&g_last_vpos, 4, 1, f); fwrite(&g_phase, 4, 1, f);
          fclose(f);
          fprintf(stderr, "saved state at frame %u\n", g_frame);
        }
        if ((int)g_frame == inj_frame && !prog.empty()) {
          uint16_t* cm = (uint16_t*)&r->tb_top->chipmem[0];
          for (size_t i = 0; i < prog.size(); i += 2)
            cm[(inj_addr + i) >> 1] = (uint16_t)((prog[i] << 8) | prog[i + 1]);
          // level 3 autovector ($6C) -> program entry; next vertical blank IRQ jumps there
          cm[0x6C >> 1] = inj_addr >> 16; cm[0x6E >> 1] = inj_addr & 0xffff;
          fprintf(stderr, "injected %zu bytes at %06x, vector $6C set (frame %u)\n", prog.size(),
                  inj_addr, g_frame);
        }
        if (stop_addr >= 0) {
          uint16_t* cm = (uint16_t*)&r->tb_top->chipmem[0];
          uint32_t v = ((uint32_t)cm[stop_addr >> 1] << 16) | cm[(stop_addr >> 1) + 1];
          if (v == stop_val) {
            fprintf(stderr, "stop word seen at frame %u\n", g_frame);
            if (shot_last && shot && !want) {
              char fn[512]; snprintf(fn, sizeof fn, "%s_%04u.ppm", shot, g_frame);
              FILE* f = fopen(fn, "wb");
              fprintf(f, "P6 %d %d 255\n", W, H); fwrite(fb.data(), 1, fb.size(), f); fclose(f);
            }
            break;
          }
        }
        if ((int)g_frame >= frames) {
          if (shot_last && shot && !want) {
            char fn[512]; snprintf(fn, sizeof fn, "%s_%04u.ppm", shot, g_frame);
            FILE* f = fopen(fn, "wb");
            fprintf(f, "P6 %d %d 255\n", W, H); fwrite(fb.data(), 1, fb.size(), f); fclose(f);
          }
          break;
        }
      }
      g_last_vpos = vpos;
    }
  }
  if (g_active && g_out) fwrite(&g_cur, sizeof g_cur, 1, g_out);
  if (use_cache)
    fprintf(stderr, "cache: shrink %d, %llu source edges, %llu stalled (%.3f %%), fills %u, write-backs %u, "
            "checked chip reads %u, wrong %u, wrong chip48 %u\n", shrink, (unsigned long long)src_edges,
            (unsigned long long)stalled, src_edges ? 100.0 * stalled / src_edges : 0.0, top->fills, top->wbacks,
            top->chk_n, top->chk_bad, top->chk48_bad);
  if (use_cache && pf_mask) {
    static const char* cls[7] = {"bpl", "spr", "aud", "dsk", "cop", "blt", "cpu"};
    for (int c = 0; c < 7; c++) {
      auto w = [&](int bit) { return (uint32_t)top->o_pf_stats[(96 * c + bit) / 32]; };
      fprintf(stderr, "prefetch %s: issued %u useful %u wasted %u\n", cls[c], w(64), w(32), w(0));
    }
  }
  if (cput) fclose(cput);
  if (dump_fn) {
    uint16_t* cm = (uint16_t*)&r->tb_top->chipmem[0];
    FILE* f = fopen(dump_fn, "wb");
    for (uint32_t i = 0; i < dump_len; i += 2) {
      uint16_t w = cm[((dump_addr + i) >> 1) & 0xfffff];
      uint8_t b[2] = {(uint8_t)(w >> 8), (uint8_t)w}; fwrite(b, 1, 2, f);
    }
    fclose(f);
  }
  if (g_out) fclose(g_out);
  fprintf(stderr, "done: %llu ticks, %llu records\n", (unsigned long long)g_tick,
          (unsigned long long)g_nrec);
  top->final();
  if (inj_p > 0) fprintf(stderr, "injector: %llu stalls of %d source edges\n", (unsigned long long)inj_n, inj_k);
  if (hdf_fn) {
    fprintf(stderr, "hddsrv: %llu commands, %llu sectors read, %llu written, %llu errors, %llu resets, "
            "%llu timeouts; SPI %llu transactions %llu bytes\n", (unsigned long long)g_hdd.cmds,
            (unsigned long long)g_hdd.rd_sect, (unsigned long long)g_hdd.wr_sect, (unsigned long long)g_hdd.errors,
            (unsigned long long)g_hdd.resets, (unsigned long long)g_hdd.timeouts,
            (unsigned long long)g_spi.xfers, (unsigned long long)g_spi.bytes);
    g_hdd_stop = 1; { std::lock_guard<std::mutex> l(g_spi.m); g_spi.cv.notify_all(); g_spi.att_cv.notify_all(); }
    hdd_th.join();
  }
  delete top;
  return 0;
}
