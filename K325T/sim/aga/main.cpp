// main.cpp -- Verilator driver for tb_top (AGA + 68020 bench, from the A1200 DDR3 study's driver):
// loads a Kickstart (256/512 KB, read in place), runs N frames, logs every chip-bus memory access
// (run-length: one record per access with its tick count), injects test programs into chip RAM,
// writes PPM frames, dumps chip RAM, logs the CPU's bus requests.  Simulation tooling only.
// New options: --cpu N (0xF4 payload: 0 = 68000 fx68k, 3 = 68020 TG68K), --shot-frames a,b,c,
// --px28 (sample the picture every 28 MHz tick: 1920 columns, for super-hires), --dump ADDR LEN FILE
// (chip RAM at the end), --stop ADDR VALUE (stop at the first frame end where the chip-RAM long
// at ADDR holds VALUE), --cputrace FILE FROM TO (CPU requests in frames FROM..TO), --preload FILE
// ADDR (into chip RAM before the start; with mk_agatest.py's boot ROM no Kickstart is needed).
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
static bool g_active = false;
static Rec g_cur;
static uint64_t g_nrec = 0;
static int g_phase = 0;       // ticks since clk7_en
static int g_debug_ticks = 0; // print per-tick state for this many ticks after cfg_done
static uint64_t g_debug_from = ~0ull;
static int g_last_vpos = -1;
static uint32_t g_frame = 0;

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
  bool use_cache = false; int shrink = 0, lat_min = 20, lat_span = 40;
  const char* preload_fn = nullptr; uint32_t preload_addr = 0;
  const char* dump_fn = nullptr; uint32_t dump_addr = 0, dump_len = 0;
  int64_t stop_addr = -1; uint32_t stop_val = 0;
  const char* cput_fn = nullptr; int cput_from = 0, cput_to = 0;
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
    else if (a == "--shrink") shrink = atoi(nx());
    else if (a == "--lat") { lat_min = atoi(nx()); lat_span = atoi(nx()); }
    else if (a == "--preload") { preload_fn = nx(); preload_addr = strtoul(nx(), 0, 0); }
    else if (a == "--dump") { dump_addr = strtoul(nx(), 0, 0); dump_len = strtoul(nx(), 0, 0); dump_fn = nx(); }
    else if (a == "--stop") { stop_addr = strtoll(nx(), 0, 0); stop_val = strtoul(nx(), 0, 0); }
    else if (a == "--cputrace") { cput_fn = nx(); cput_from = atoi(nx()); cput_to = atoi(nx()); }
    else if (a == "--debug") { g_debug_ticks = atoi(nx()); g_debug_from = strtoull(nx(), 0, 0); }
  }
  Vtb_top* top = new Vtb_top;
  auto* r = top->rootp;
  if (kick) load_rom(kick, (uint16_t*)&r->tb_top->kickmem[0], 262144);
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
  top->cfg_chipset = chipset; top->cfg_cpu = cpu; top->cfg_mem = mem;
  top->rst_ext = 1; top->bd_we = 0;
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
  top->use_cache = use_cache; top->cache_on = use_cache; top->shrink = shrink;
  top->lat_min = lat_min; top->lat_span = lat_span; top->cache_reset = use_cache;
  // stage 3, --cache: three clocks.  Source clock 31.310345 MHz (stall_clk.vhd), MIG ui_clk 100 MHz;
  // the machine clock is the source clock gated like the BUFGCE: a source edge reaches clk only
  // when the cache's combinational miss is low just before it.  Machine time (g_tick) counts the
  // machine edges only, so pictures and traces are in machine time as without the cache.
  const uint64_t SRC_H = 15969, UI_H = 5000;   // half periods in ps
  uint64_t t_src = SRC_H, t_ui = UI_H, src_edges = 0, stalled = 0;
  bool src_lvl = false, ui_lvl = false;
  auto machine_edge = [&]() {
    if (!use_cache) { top->clk = 0; top->eval(); top->clk = 1; top->eval(); return; }
    for (;;) {
      if (t_ui <= t_src) { ui_lvl = !ui_lvl; top->ui_clk = ui_lvl; top->eval(); t_ui += UI_H; continue; }
      src_lvl = !src_lvl; t_src += SRC_H;
      if (!src_lvl) { top->src_clk = 0; top->clk = 0; top->eval(); continue; }
      src_edges++;
      if (src_edges == 64) top->cache_reset = 0;      // the full reset: the cache latches its mode
      bool pass = !top->miss;
      top->src_clk = 1; if (pass) top->clk = 1; top->eval();
      if (pass) return;
      stalled++;
    }
  };
  for (uint64_t cyc = cyc0;; cyc++) {
    machine_edge();
    g_tick++;
    if (cyc == 200) top->rst_ext = 0;
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
        if (g_frame % 10 == 0) fprintf(stderr, "frame %u tick %llu recs %llu pc %06x\n", g_frame,
                                       (unsigned long long)g_tick, (unsigned long long)g_nrec,
                                       top->o_cpu_addr << 1);
        if ((int)g_frame == trace_from && out) {
          g_out = fopen(out, "wb");
          fprintf(stderr, "trace starts at frame %u tick %llu\n", g_frame,
                  (unsigned long long)g_tick);
        }
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
          if (v == stop_val) { fprintf(stderr, "stop word seen at frame %u\n", g_frame); break; }
        }
        if ((int)g_frame >= frames) break;
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
  delete top;
  return 0;
}
