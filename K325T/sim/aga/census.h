// census.h -- a1200-pistorm (aexp13 measurement M0): the CPU's bus requests counted by address class and
// kind, per frame, for the PiStorm-style study (ext/aexp13_pistorm/FEASIBILITY.md).  Bench tooling only.
//
// --census FILE: one CSV line per frame.  Every acknowledged CPU request (o_cpustate 0 fetch / 2 read /
// 3 write, address o_cpu_addr32, 24 bits used) is put in a class:
//   0 chip   $000000-$1FFFFF      1 custom $C00000-$D9FFFF, $DF0000-$DFFFFF (minimig decodes the
//   2 cia    $A00000-$BFFFFF        custom registers there when there is no slow RAM)
//   3 rom    $E00000-$E7FFFF, $F80000-$FFFFFF   4 fast $200000-$9FFFFF (Zorro II)
//   5 gayle  $DA0000-$DEFFFF (IDE, RTC, Gayle registers)   6 autoconfig $E80000-$EFFFFF   7 other
// For each request: gap = clocks from the previous acknowledge to this request (the CPU's own work,
// incl. throttle hold), wait = clocks from the request to its acknowledge (the bus or the cache).  A gap
// longer than IDLE_GAP clocks is idle time (STOP, nothing to do), not work.
// trans: word requests merged into 32-bit transactions -- a request of the same class and kind at A+2
// right after one at A (A on a long boundary) is the second half of the same transaction (the TG68K
// splits longs into words; sequential word accesses are merged too, so trans is a lower bound).
// spin: a read of an address that was read again within the last SPIN_WIN requests with no write in
// between marks itself and every request since that earlier read as a polling loop ("spin"); those
// requests (and their clocks) move from the work bucket to the spin bucket.
#pragma once
#include <cstdio>
#include <cstdint>
#include <cstring>

struct Census {
  static const int NC = 8, IDLE_GAP = 256, SPIN_WIN = 48, RING = 64;
  struct Acc { uint64_t words[NC][4], trans[NC][4], gap[NC][4], wait[NC][4]; };
  struct Ent { uint32_t frame, addr; uint8_t cls, typ, newtr, spin; uint32_t gap, wait; };
  FILE* f = nullptr;
  Acc a[2];                  // 0 work, 1 spin
  uint64_t idle = 0, clocks = 0;
  Ent ring[RING]; uint64_t n = 0;
  uint64_t req_tick = 0, last_ack = 0; int prev_cs = 1; bool started = false;
  uint32_t last_addr = 0; int last_cls = -1, last_typ = -1; bool last_first = false;

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
  void open(const char* fn) {
    f = fopen(fn, "w");
    memset(a, 0, sizeof a);
    static const char* C[NC] = {"chip", "custom", "cia", "rom", "fast", "gayle", "acfg", "other"};
    static const char* T[4] = {"f", "", "r", "w"};
    fprintf(f, "frame,clocks,idle");
    for (int b = 0; b < 2; b++) for (int c = 0; c < NC; c++) for (int t : {0, 2, 3})
      for (const char* q : {"words", "trans", "gap", "wait"})
        fprintf(f, ",%s_%s_%s_%s", b ? "spin" : "work", C[c], T[t], q);
    fprintf(f, "\n");
  }
  void add(int b, const Ent& e, int sign) {
    a[b].words[e.cls][e.typ] += sign; a[b].trans[e.cls][e.typ] += sign * e.newtr;
    a[b].gap[e.cls][e.typ] += (int64_t)sign * e.gap; a[b].wait[e.cls][e.typ] += (int64_t)sign * e.wait;
  }
  // once per machine clock, after eval
  void step(uint64_t tick, uint32_t frame, int cs, uint32_t addr, bool ack) {
    if (!f) return;
    clocks++;
    if (cs != 1 && prev_cs == 1) req_tick = tick;
    if (cs != 1 && ack) {
      Ent e; e.frame = frame; e.addr = addr & 0xFFFFFF; e.cls = cls_of(addr); e.typ = cs; e.spin = 0;
      uint64_t g = started ? req_tick - last_ack : 0;
      e.wait = (uint32_t)(tick - req_tick);
      if (g > IDLE_GAP) { idle += g; g = 0; }
      e.gap = (uint32_t)g;
      bool second = last_first && e.cls == last_cls && e.typ == last_typ && e.addr == last_addr + 2;
      e.newtr = second ? 0 : 1;
      last_first = !second && (e.addr & 3) == 0;
      last_addr = e.addr; last_cls = e.cls; last_typ = e.typ;
      add(0, e, 1);
      // polling loop?
      if (e.typ == 2) {
        for (int d = 1; d <= SPIN_WIN && (uint64_t)d <= n; d++) {
          Ent& p = ring[(n - d) % RING];
          if (p.typ == 3) break;
          if (p.typ == 2 && p.addr == e.addr) {
            for (int k = d - 1; k >= 1; k--) {
              Ent& q = ring[(n - k) % RING];
              if (!q.spin && q.frame == frame) { add(0, q, -1); add(1, q, 1); q.spin = 1; }
            }
            if (!p.spin && p.frame == frame) { add(0, p, -1); add(1, p, 1); p.spin = 1; }
            add(0, e, -1); add(1, e, 1); e.spin = 1;
            break;
          }
        }
      }
      ring[n % RING] = e; n++;
      last_ack = tick; started = true;
      prev_cs = 1;
    } else prev_cs = cs;
  }
  void frame_end(uint32_t frame) {
    if (!f) return;
    fprintf(f, "%u,%llu,%llu", frame, (unsigned long long)clocks, (unsigned long long)idle);
    for (int b = 0; b < 2; b++) for (int c = 0; c < NC; c++) for (int t : {0, 2, 3})
      fprintf(f, ",%llu,%llu,%llu,%llu", (unsigned long long)a[b].words[c][t], (unsigned long long)a[b].trans[c][t],
              (unsigned long long)a[b].gap[c][t], (unsigned long long)a[b].wait[c][t]);
    fprintf(f, "\n"); fflush(f);
    memset(a, 0, sizeof a); idle = 0; clocks = 0;
  }
  void close() { if (f) fclose(f); f = nullptr; }
};
