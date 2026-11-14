#!/usr/bin/env python3
"""fccen.py -- the fast CPU's census counters (K325T/fc_cen.vhd, a1200-fc8 debug bitstreams built with FCCEN=1).

On the module (next to stallmon.py; python3-spidev; writes nothing to the module's flash):
    fccen.py snap                one coherent snapshot of all 32 counters, one line on stdout:
                                 "t=<unix time> seq=<n> opt=<hex> <name>=<value> ..." (48-bit counters, CPU clocks)
    fccen.py watch SECS [EVERY]  a snapshot line every EVERY seconds (default 1) for SECS seconds
    fccen.py opt P               set the fast CPU's speed options to preset P (0 fc7, 1 I side, 2 I + D, 3 all = +long
                                 stores, 4 long stores only, 5 I side + long stores); prints the new snapshot
Anywhere:
    fccen.py diff FILE A B       the split between two snapshot lines of FILE (line numbers A < B, 1-based): per
                                 category % of the clocks, core execution vs memory+bus, instructions, clocks per
                                 instruction (executing share and all), polling

Protocol (stall controller page 7, register 6 = 7): the index r4 & r5 = $D8..$DF / $E8..$EF selects slots 2i, 2i+1 /
16+2i, 17+2i of the snapshot as the 96-bit status word (status bytes 60..71); entering $D8 from another index latches
all counters at once; entering $E8 with register 3 = 8 + P sets preset P (the readout keeps register 3 = 0).  Keep the
stall injector off (its registers are 3..5 too).  m65d may rewrite registers 0..3: the tool writes every register it
needs on every call.
"""
import sys
import time

SLOTS = ["clocks", "instr", "fetch_lb", "fetch_arr", "read", "store", "internal", "stop", "lookup_i", "lookup_d",
         "ifill_fast", "ifill_rom", "ifill_chip", "dfill_fast", "dfill_rom", "qfull_fr", "qfull_mb", "drain_fr",
         "drain_mb", "mbrd_chip", "mbrd_custom", "mbrd_cia", "mbrd_other", "sync_custom", "sync_cia", "guard", "mbpre",
         "reset", "poll1", "irqmask", "seqopt", "magic"]
EXEC = ["fetch_lb", "fetch_arr", "read", "store", "internal"]
GROUPS = [("core: words at 1 clock (fetch/read/store hits)", ["fetch_lb", "fetch_arr", "read", "store"]),
          ("core: kernel-internal clocks", ["internal"]),
          ("I/D lookup clocks", ["lookup_i", "lookup_d"]),
          ("I fills", ["ifill_fast", "ifill_rom", "ifill_chip"]), ("D fills", ["dfill_fast", "dfill_rom"]),
          ("fast-RAM store waits", ["qfull_fr", "drain_fr"]), ("chip store waits", ["qfull_mb", "drain_mb"]),
          ("chip reads", ["mbrd_chip"]), ("custom/CIA/other reads", ["mbrd_custom", "mbrd_cia", "mbrd_other", "mbpre"]),
          ("sync interrupt registers", ["sync_custom", "sync_cia"]), ("audio guard", ["guard"]),
          ("STOP (idle)", ["stop"]), ("reset", ["reset"])]
PRESETS = {0: "00", 1: "03", 2: "0F", 3: "1F", 4: "10", 5: "13"}


class Cen:
    def __init__(self):
        sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
        from stallmon import Bridge
        self.b = Bridge()

    def word(self):
        for _ in range(4):
            r = self.b.status()
            w = [int.from_bytes(bytes(r[60 + 4 * i:64 + 4 * i]), "big") for i in range(3)]
            r = self.b.status()
            w2 = [int.from_bytes(bytes(r[60 + 4 * i:64 + 4 * i]), "big") for i in range(3)]
            if w == w2:
                return w
        return w2

    def snap(self):
        b = self.b
        b.wr(6, 7)                       # page 7 (r6 bit 3, the stall monitor's snapshot toggle, untouched = 0)
        b.wr(3, 0)
        b.wr(4, 0); b.wr(5, 8)           # index $08: leave the range
        b.wr(4, 0xD)                     # $D8 entered: the counters are latched
        self.t = time.time()
        sl = [0] * 32
        for hi in range(2):
            b.wr(4, 0xD if hi == 0 else 0xE)
            for i in range(8):
                b.wr(5, 8 + i)
                w = self.word()
                v = (w[0] << 64) | (w[1] << 32) | w[2]
                sl[16 * hi + 2 * i] = v >> 48
                sl[16 * hi + 2 * i + 1] = v & ((1 << 48) - 1)
        if sl[31] >> 32 != 0xFCCE:
            raise SystemExit("no census counters (slot 31 = %012x): not an FCCEN=1 bitstream?" % sl[31])
        return sl

    def opt(self, p):
        b = self.b
        b.wr(6, 7)
        b.wr(4, 0); b.wr(5, 8)           # $08
        b.wr(3, 8 | p)
        b.wr(4, 0xE)                     # $E8 entered with r3 = 8 + p: the preset
        b.wr(3, 0)
        b.wr(4, 0)


def line(sl, t):
    so = sl[30]
    return "t=%.3f seq=%d opt=%02x " % (t, so & ((1 << 40) - 1), so >> 40) + " ".join(
        "%s=%d" % (SLOTS[k], sl[k]) for k in range(30))


def parse(l):
    d = {}
    for f in l.split():
        if "=" in f:
            k, v = f.split("=", 1)
            d[k] = float(v) if k == "t" else (int(v, 16) if k == "opt" else int(v))
    return d


def diff(a, b):
    d = {k: b[k] - a[k] for k in SLOTS[:30] if k in a and k in b}
    tot = d["clocks"]
    print("%.1f s, %d CPU clocks (%.2f MHz), options %02x -> %02x" % (b["t"] - a["t"], tot, tot / max(1e-9, b["t"] - a["t"]) / 1e6,
                                                                       a["opt"], b["opt"]))
    for n, ks in GROUPS:
        v = sum(d[k] for k in ks)
        print("  %-46s %6.2f %%" % (n, 100.0 * v / tot))
    ex = sum(d[k] for k in EXEC)
    work = tot - d["stop"] - d["reset"]
    print("SPLIT (of the clocks that are not STOP/reset): core execution %.1f %% / memory+bus %.1f %%; polling (one address) "
          "%.1f %%" % (100.0 * ex / max(1, work), 100.0 * (work - ex) / max(1, work), 100.0 * d["poll1"] / max(1, work)))
    print("instructions %d: executing clocks per instruction %.2f, all non-idle clocks per instruction %.2f; "
          "interrupt mask > 0 for %.1f %% of the clocks" % (d["instr"], ex / max(1, d["instr"]), work / max(1, d["instr"]),
                                                            100.0 * d["irqmask"] / tot))


def main(argv):
    if not argv:
        print(__doc__); return
    if argv[0] == "diff":
        ls = [l for l in open(argv[1]) if l.startswith("t=")]
        diff(parse(ls[int(argv[2]) - 1]), parse(ls[int(argv[3]) - 1]))
        return
    c = Cen()
    if argv[0] == "snap":
        sl = c.snap(); print(line(sl, c.t), flush=True)
    elif argv[0] == "watch":
        secs = float(argv[1]); every = float(argv[2]) if len(argv) > 2 else 1.0
        t0 = time.time()
        while time.time() - t0 < secs:
            t = time.time()
            sl = c.snap(); print(line(sl, c.t), flush=True)
            time.sleep(max(0.0, every - (time.time() - t)))
    elif argv[0] == "opt":
        p = int(argv[1])
        if p not in PRESETS:
            raise SystemExit("preset 0..5")
        c.opt(p)
        sl = c.snap(); print(line(sl, c.t), flush=True)
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
