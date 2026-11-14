// fc_census.h -- a1200-fc8: where the fast 68020's (fc_cpu) clocks go, per frame.  Bench tooling only.
//
// --fcc FILE: one CSV line per frame.  Every cpu_clk is sampled just before its rising edge (tb_top's o_fcc_*
// probes into fc_cpu / fc_mbox) and put in exactly one category:
//   executing   fetch_lb / fetch_arr (a fetch answered from a line buffer / from an array; the array's one
//               lookup clock before it is lookup_i), read (data answered from the D side, or a discarded read),
//               store (a store taken into the queue), internal (the kernel enabled without a bus request: its
//               own multi-clock work), stop (the STOP state)
//   cache       lookup_i / lookup_d (the array read clock of a line-buffer miss), ifill_fast / ifill_rom /
//               ifill_chip, dfill_fast / dfill_rom (line fills, incl. their done clock)
//   stores      qfull_fr / qfull_mb (a store waits: the queue is full while a fast-RAM / mailbox entry drains),
//               drain_fr / drain_mb (a fill or mailbox access waits for the queue to empty)
//   mailbox     mbrd_chip / mbrd_custom / mbrd_cia / mbrd_other (uncached reads), sync_custom / sync_cia (the
//               synchronous interrupt-register accesses, incl. the IPL wait), guard (a DMACON write held by the
//               audio retrigger guard), mbpre (the decision clock before a mailbox access)
//   reset
// Requests answered (kernel boundary): counted per address class and kind (fetch / read / write), with 32-bit
// data accesses (long_ack) separately.  Instructions = decodeOPC clocks.
// spin (the demo's own polling / pacing): a data read of an address that was read again within the last SPIN_WIN
// answered requests with no write in between marks itself and every request since that earlier read as a polling
// loop; their clocks move from the work bucket to the spin bucket (the method of census.h at the kernel level).
// --fcc-ev FILE (gzip): the D side's event log for the miss analysis: "R clk line" a cached (fast / ROM) data read
// answered from another 16-byte line than the previous such read; "F t0 q f side src addr" a completed line fill (t0
// = its first clock after the lookup, q = clocks waiting for the store queue (S_FILLQ), f = clocks of the fill
// itself (S_FILL), side i/d, src fast/rom/chip, addr = the kernel's address of the miss); "N frame clk" at a frame end.
// Per frame (CSV, last columns): completed fills per side and source, their S_FILLQ / S_FILL clocks.
// --fcc-pc FILE: every PC_WIN frames, the hottest code (16-byte bins of exe_pc): clocks, of them waiting.
#pragma once
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>
#include <algorithm>

struct FcCensus {
  enum { E_FETCH_LB, E_FETCH_ARR, E_READ, E_STORE, E_INTERNAL, E_STOP,
         E_LOOKUP_I, E_LOOKUP_D, E_IFILL_FAST, E_IFILL_ROM, E_IFILL_CHIP, E_DFILL_FAST, E_DFILL_ROM,
         E_QFULL_FR, E_QFULL_MB, E_DRAIN_FR, E_DRAIN_MB,
         E_MBRD_CHIP, E_MBRD_CUSTOM, E_MBRD_CIA, E_MBRD_OTHER, E_SYNC_CUSTOM, E_SYNC_CIA, E_GUARD, E_MBPRE,
         E_RESET, NE };
  static constexpr const char* EN[NE] = {"fetch_lb", "fetch_arr", "read", "store", "internal", "stop",
         "lookup_i", "lookup_d", "ifill_fast", "ifill_rom", "ifill_chip", "dfill_fast", "dfill_rom",
         "qfull_fr", "qfull_mb", "drain_fr", "drain_mb",
         "mbrd_chip", "mbrd_custom", "mbrd_cia", "mbrd_other", "sync_custom", "sync_cia", "guard", "mbpre", "reset"};
  static const int NC = 8, SPIN_WIN = 48, RING = 64, PC_WIN = 25;
  static constexpr const char* CN[NC] = {"chip", "custom", "cia", "rom", "fast", "gayle", "acfg", "other"};
  struct Ent { uint32_t frame, addr; uint8_t typ, spin; uint32_t c[NE]; };
  FILE* f = nullptr; FILE* fp = nullptr; FILE* fev = nullptr;
  uint64_t tclk = 0, f_t0 = 0, nf[2][3], fq[2], ff[2]; uint32_t f_q = 0, f_f = 0, f_a = 0, last_rln = ~0u; int prev_st = 0;
  uint64_t work[NE], spin[NE], req[NC][3], longs[NC][3], instr, sup, clocks, mstate[8], mclocks, irq, irqw;
  uint32_t acc[NE];
  Ent ring[RING]; uint64_t n = 0;
  std::unordered_map<uint32_t, uint64_t> spin_addr;
  struct Pc { uint64_t clk, wait, instr; };
  std::unordered_map<uint32_t, Pc> pcs;
  uint32_t pc_from = 0;

  static int cls_of(uint32_t a) {
    a &= 0xFFFFFF;
    if (a < 0x200000) return 0;
    if (a < 0xA00000) return 4;
    if (a < 0xC00000) return 2;
    if (a >= 0xDA0000 && a < 0xDF0000) return 5;
    if (a < 0xE00000) return 1;
    if (a < 0xE80000) return 3;
    if (a < 0xF00000) return 6;
    if (a >= 0xF80000) return 3;
    return 7;
  }
  void clear() {
    memset(work, 0, sizeof work); memset(spin, 0, sizeof spin); memset(req, 0, sizeof req);
    memset(longs, 0, sizeof longs); instr = sup = clocks = irq = irqw = 0; memset(mstate, 0, sizeof mstate); mclocks = 0; memset(lk, 0, sizeof lk);
    memset(nf, 0, sizeof nf); memset(fq, 0, sizeof fq); memset(ff, 0, sizeof ff);
    spin_addr.clear();
  }
  void open(const char* fn) {
    f = fopen(fn, "w"); clear(); memset(acc, 0, sizeof acc);
    fprintf(f, "frame,cpu_clocks,machine_clocks,instr,super,irq,irq_wait");
    for (int b = 0; b < 2; b++) for (int e = 0; e < NE; e++) fprintf(f, ",%s_%s", b ? "spin" : "work", EN[e]);
    static const char* T[3] = {"f", "r", "w"};
    for (int c = 0; c < NC; c++) for (int t = 0; t < 3; t++) fprintf(f, ",n_%s_%s", CN[c], T[t]);
    for (int c = 0; c < NC; c++) for (int t = 1; t < 3; t++) fprintf(f, ",l_%s_%s", CN[c], T[t]);
    static const char* M[5] = {"idle", "guard", "w1", "w2", "sync"};
    for (int m = 0; m < 5; m++) fprintf(f, ",mb_%s", M[m]);
    fprintf(f, ",lk_i_seq,lk_i_loop,lk_i_other,lk_d_seq,lk_d_loop,lk_d_other");
    fprintf(f, ",spin_top_addr,spin_top_n");
    fprintf(f, ",nf_i_fast,nf_i_rom,nf_i_chip,nf_d_fast,nf_d_rom,nf_d_chip,fq_i,ff_i,fq_d,ff_d\n");
  }
  void open_pc(const char* fn) { fp = fopen(fn, "w"); }
  void open_ev(const char* fn) { std::string c = std::string("gzip -1 > '") + fn + "'"; fev = popen(c.c_str(), "w"); }
  void close_ev() { if (fev) { pclose(fev); fev = nullptr; } }
  void move(const Ent& e) {   // work -> spin
    for (int k = 0; k < NE; k++) { work[k] -= e.c[k]; spin[k] += e.c[k]; }
  }
  // once per cpu_clk, before its rising edge
  // lookup clocks by the line they go to: 0 the next line (sequential), 1 one of the 3 lines visited before the
  // current one (a short loop), 2 another line; I and D separately
  uint64_t lk[2][3];
  uint32_t lines[2][4] = {{~0u, ~0u, ~0u, ~0u}, {~0u, ~0u, ~0u, ~0u}};
  // per opcode (exe_opcode): clocks, internal clocks, waiting clocks, instructions (--fcc-pc windows)
  std::vector<uint64_t> op_clk = std::vector<uint64_t>(65536), op_int = std::vector<uint64_t>(65536),
                        op_wait = std::vector<uint64_t>(65536), op_n = std::vector<uint64_t>(65536);
  void step(uint32_t frame, uint32_t b, uint32_t c, uint32_t a, uint32_t pc, uint32_t fa, uint32_t mba, uint32_t op) {
    if (!f) return;
    bool k_ena = b & 1, rq = (b >> 1) & 1, ack = (b >> 2) & 1;
    int bs = (b >> 3) & 3, st = (b >> 5) & 7;
    bool use_i = (b >> 8) & 1, use_d = (b >> 9) & 1, lbi = (b >> 10) & 1, lbd = (b >> 11) & 1;
    bool fill_i = (b >> 13) & 1, fill_mb = (b >> 14) & 1, q_full = (b >> 15) & 1;
    int dr = (b >> 16) & 3; bool sync_r = (b >> 18) & 1, rst = (b >> 19) & 1;
    bool lack = (b >> 23) & 1, dec = (b >> 24) & 1, clw = (b >> 25) & 1, stop = (b >> 26) & 1, S = (b >> 27) & 1;
    int mst = (b >> 28) & 7; bool mbopen = (b >> 31) & 1;
    bool fe = bs == 0, rd = bs == 2, wr = bs == 3;
    (void)k_ena; (void)mbopen;
    clocks++; tclk++;
    if (S) sup++;
    // fills: S_RUN -> S_FILLQ (1) -> S_FILL (2) -> S_FILLD (3), one clock in S_FILLD
    if (st == 1 && prev_st == 0) { f_t0 = tclk; f_q = 0; f_f = 0; f_a = a & 0xFFFFFF; }
    if (st == 1) f_q++;
    if (st == 2) f_f++;
    if (st == 3 && prev_st != 3) {
      int sd = !fill_i, k = cls_of(fa), src = !fill_mb ? 0 : k == 3 ? 1 : 2;
      nf[sd][src]++; fq[sd] += f_q; ff[sd] += f_f;
      if (fev) fprintf(fev, "F %llx %u %u %c %c %06x\n", (unsigned long long)f_t0, f_q, f_f, sd ? 'd' : 'i', "frc"[src], f_a);
    }
    prev_st = st;
    if (fev && rq && ack && !rst && rd) {
      int k = cls_of(a);
      uint32_t ln = (a & 0xFFFFFF) >> 4;
      if ((k == 4 || k == 3) && ln != last_rln) { fprintf(fev, "R %llx %05x\n", (unsigned long long)tclk, ln); last_rln = ln; }
    }
    bool in_irq = (c & 7) != 0;   // SR interrupt mask above 0: an interrupt handler (or code that masks)
    if (dec && clw) instr++;
    int e;
    auto mbcls = [&](uint32_t x) {
      int k = cls_of(x);
      return k == 0 ? E_MBRD_CHIP : k == 1 ? E_MBRD_CUSTOM : k == 2 ? E_MBRD_CIA : E_MBRD_OTHER;
    };
    if (rst) e = E_RESET;
    else if (!rq) e = stop ? E_STOP : E_INTERNAL;
    else if (ack && st == 3) {   // S_FILLD
      int k = cls_of(fa);
      e = fill_i ? (!fill_mb ? E_IFILL_FAST : k == 3 ? E_IFILL_ROM : E_IFILL_CHIP) : (!fill_mb ? E_DFILL_FAST : E_DFILL_ROM);
    } else if (ack && st == 7) {   // S_MBD
      e = sync_r ? (cls_of(mba) == 2 ? E_SYNC_CIA : E_SYNC_CUSTOM) : mbcls(mba);
    } else if (ack) {
      e = fe ? ((lbi || lbd || ((c >> 10) & 3)) ? E_FETCH_LB : E_FETCH_ARR) : rd ? E_READ : E_STORE;   // fc8: b0/b1 hits = buffers
    } else {
      switch (st) {
        case 0:   // S_RUN, not answered
          if (use_i) e = E_LOOKUP_I; else if (use_d) e = E_LOOKUP_D;
          else if (wr && q_full) e = dr == 3 ? E_QFULL_MB : E_QFULL_FR;
          else e = E_MBPRE;
          break;
        case 1: case 4:   // S_FILLQ, S_MBQ: the queue drains first
          e = (dr == 3 || (dr == 0 && mbopen)) ? E_DRAIN_MB : E_DRAIN_FR; break;
        case 2: {
          int k = cls_of(fa);
          e = fill_i ? (!fill_mb ? E_IFILL_FAST : k == 3 ? E_IFILL_ROM : E_IFILL_CHIP) : (!fill_mb ? E_DFILL_FAST : E_DFILL_ROM);
          break;
        }
        case 5: case 6:
          if (sync_r) e = mst == 1 ? E_GUARD : (cls_of(mba) == 2 ? E_SYNC_CIA : E_SYNC_CUSTOM);
          else e = mbcls(mba);
          break;
        default: e = E_MBPRE;
      }
    }
    work[e]++; acc[e]++;
    if (in_irq) { irq++; if (e >= E_LOOKUP_I && e != E_RESET) irqw++; }
    if (e == E_LOOKUP_I || e == E_LOOKUP_D) {
      int s2 = e == E_LOOKUP_D, k = 2; uint32_t ln = (a & 0xFFFFFF) >> 4;
      if (ln == lines[s2][0] + 1) k = 0;
      else if (ln == lines[s2][1] || ln == lines[s2][2] || ln == lines[s2][3]) k = 1;
      lk[s2][k]++;
    }
    if (rq && ack && !rst && (fe || rd)) {   // the line just answered from (I for fetches, D for reads)
      int s2 = !fe; uint32_t ln = (a & 0xFFFFFF) >> 4;
      if (ln != lines[s2][0]) {
        int j = 1; while (j < 3 && lines[s2][j] != ln) j++;
        for (; j > 0; j--) lines[s2][j] = lines[s2][j - 1];
        lines[s2][0] = ln;
      }
    }
    if (fp) {
      op_clk[op & 0xFFFF]++;
      if (e == E_INTERNAL) op_int[op & 0xFFFF]++;
      else if (e >= E_LOOKUP_I && e != E_RESET) op_wait[op & 0xFFFF]++;
      if (dec && clw) op_n[op & 0xFFFF]++;
    }
    if (fp) {
      Pc& p = pcs[pc >> 4]; p.clk++;
      if (e >= E_LOOKUP_I && e != E_RESET) p.wait++;
      if (dec && clw) p.instr++;
    }
    if (rq && ack && !rst) {
      int k = cls_of(a), t = fe ? 0 : rd ? 1 : 2;
      req[k][t]++; if (lack && t) longs[k][t]++;
      Ent en; en.frame = frame; en.addr = a & 0xFFFFFF; en.typ = t; en.spin = 0;
      for (int q = 0; q < NE; q++) { en.c[q] = acc[q]; acc[q] = 0; }
      if (t == 1) {
        for (int d = 1; d <= SPIN_WIN && (uint64_t)d <= n; d++) {
          Ent& p = ring[(n - d) % RING];
          if (p.typ == 2) break;
          if (p.typ == 1 && p.addr == en.addr) {
            for (int q = d - 1; q >= 1; q--) {
              Ent& r = ring[(n - q) % RING];
              if (!r.spin && r.frame == frame) { move(r); r.spin = 1; }
            }
            if (!p.spin && p.frame == frame) { move(p); p.spin = 1; }
            move(en); en.spin = 1; spin_addr[en.addr]++;
            break;
          }
        }
      }
      ring[n % RING] = en; n++;
    }
  }
  // once per machine clock: fc_mbox's state
  void mstep(int mst) { if (f) { mstate[mst & 7]++; mclocks++; } }
  void frame_end(uint32_t frame) {
    if (!f) return;
    fprintf(f, "%u,%llu,%llu,%llu,%llu,%llu,%llu", frame, (unsigned long long)clocks, (unsigned long long)mclocks,
            (unsigned long long)instr, (unsigned long long)sup, (unsigned long long)irq, (unsigned long long)irqw);
    for (int e = 0; e < NE; e++) fprintf(f, ",%llu", (unsigned long long)work[e]);
    for (int e = 0; e < NE; e++) fprintf(f, ",%llu", (unsigned long long)spin[e]);
    for (int c = 0; c < NC; c++) for (int t = 0; t < 3; t++) fprintf(f, ",%llu", (unsigned long long)req[c][t]);
    for (int c = 0; c < NC; c++) for (int t = 1; t < 3; t++) fprintf(f, ",%llu", (unsigned long long)longs[c][t]);
    for (int m = 0; m < 5; m++) fprintf(f, ",%llu", (unsigned long long)mstate[m]);
    for (int s2 = 0; s2 < 2; s2++) for (int k = 0; k < 3; k++) fprintf(f, ",%llu", (unsigned long long)lk[s2][k]);
    uint32_t ta = 0; uint64_t tn = 0;
    for (auto& kv : spin_addr) if (kv.second > tn) { tn = kv.second; ta = kv.first; }
    fprintf(f, ",%06x,%llu", ta, (unsigned long long)tn);
    for (int s2 = 0; s2 < 2; s2++) for (int k = 0; k < 3; k++) fprintf(f, ",%llu", (unsigned long long)nf[s2][k]);
    fprintf(f, ",%llu,%llu,%llu,%llu\n", (unsigned long long)fq[0], (unsigned long long)ff[0], (unsigned long long)fq[1],
            (unsigned long long)ff[1]);
    fflush(f);
    if (fev) fprintf(fev, "N %u %llx\n", frame, (unsigned long long)tclk);
    clear(); memset(acc, 0, sizeof acc);   // the clocks so far are this frame's (work); a later spin move must not take them
    if (fp && frame + 1 - pc_from >= (uint32_t)PC_WIN) {
      std::vector<std::pair<uint32_t, Pc>> v(pcs.begin(), pcs.end());
      std::sort(v.begin(), v.end(), [](const std::pair<uint32_t, Pc>& x, const std::pair<uint32_t, Pc>& y) { return x.second.clk > y.second.clk; });
      uint64_t tot = 0; for (auto& kv : v) tot += kv.second.clk;
      fprintf(fp, "frames %u-%u: %llu cpu clocks\n", pc_from, frame, (unsigned long long)tot);
      for (size_t i = 0; i < v.size() && i < 48; i++)
        fprintf(fp, "  %06x %6.2f %% clocks %10llu wait %5.1f %% instr %9llu\n", v[i].first << 4, 100.0 * v[i].second.clk / tot,
                (unsigned long long)v[i].second.clk, 100.0 * v[i].second.wait / std::max<uint64_t>(1, v[i].second.clk),
                (unsigned long long)v[i].second.instr);
      fflush(fp);
      std::vector<uint32_t> ix(65536); for (uint32_t i = 0; i < 65536; i++) ix[i] = i;
      std::sort(ix.begin(), ix.end(), [&](uint32_t x, uint32_t y) { return op_clk[x] > op_clk[y]; });
      fprintf(fp, " opcodes (clocks, internal, waiting, executed):\n");
      for (int i = 0; i < 40 && op_clk[ix[i]]; i++)
        fprintf(fp, "  op %04x %6.2f %% clocks %10llu internal %10llu wait %10llu n %9llu\n", ix[i], 100.0 * op_clk[ix[i]] / tot,
                (unsigned long long)op_clk[ix[i]], (unsigned long long)op_int[ix[i]], (unsigned long long)op_wait[ix[i]],
                (unsigned long long)op_n[ix[i]]);
      fflush(fp);
      std::fill(op_clk.begin(), op_clk.end(), 0); std::fill(op_int.begin(), op_int.end(), 0);
      std::fill(op_wait.begin(), op_wait.end(), 0); std::fill(op_n.begin(), op_n.end(), 0);
      pcs.clear(); pc_from = frame + 1;
    }
  }
};
