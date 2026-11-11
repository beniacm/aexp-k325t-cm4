#!/usr/bin/env python3
"""stallmon.py -- configure the stall injector of the stoppable Amiga clock (K325T/stall_ctrl.vhd)
and read its lag/debt monitor through the Rockchip bridge (run ON THE MODULE, next to m65d; needs
python3-spidev; writes nothing to the module's flash).

    stallmon.py preset NAME          off | rtl | mix | burst15 | budget | overload (table below)
    stallmon.py set mode=1 e=7 m=10 de=2 dm=4 j=0
    stallmon.py clear                lag max and event counters to 0
    stallmon.py read                 one snapshot, key=value
    stallmon.py log SECS [EVERY]     a snapshot every EVERY seconds (default 10), one line each
    stallmon.py probe                debug builds: main_clk probe vector, RAM write/read counts
    stallmon.py rate SECS            machine frame rate (vsyncs against the ungated source clock),
                                     machine clock, stall statistics over SECS seconds

The bridge's VIDEO register (command 0x70; this core has no Linux picture) carries 1rrrvvvv
register writes, STATUS 60..71 the snapshot page selected with register 6 (stall_ctrl.vhd header).
Injector: start probability per source tick (m+1)/2^(e+8), duration ((dm+1) << de) + random
(0 .. 2^j - 1) source ticks of 1/29.290 MHz = 34.14 ns.
"""
import sys
import time

F_SRC = 100e6 * 56.75 / 5 / 38.75          # 29.290322 MHz: the ungated source clock
F_MACH = 28.375e6                          # the machine clock's long-term average (native)
T_SRC = 1e6 / F_SRC                        # us per source tick
FRAME_TICKS = 313 * 227 * 8                # machine ticks per PAL frame (568,408)

PRESETS = {
    # name: (mode, e, m, de, dm, j, what)
    "off":      (0, 0, 0, 0, 0, 0, "injector off"),
    "rtl":      (1, 7, 10, 2, 4, 0, "0.68 us stalls, ~197 per frame (the study's worst RTL workload)"),
    "mix":      (1, 5, 4, 0, 8, 6, "0.31-2.46 us stalls, ~357 per frame, ~2.5 %"),
    "burst15":  (1, 10, 8, 5, 13, 0, "15.3 us stalls, ~20 per frame, ~1.6 %"),
    "budget":   (1, 3, 2, 2, 4, 0, "0.68 us stalls, ~858 per frame, ~2.9 % (just below 3.1 %)"),
    "overload": (1, 2, 2, 2, 4, 0, "0.68 us stalls, ~1716 per frame, ~5.9 % (beyond the 3.1 % budget)"),
}
REG = {"mode": 0, "e": 1, "m": 2, "de": 3, "dm": 4, "j": 5}


class Bridge:
    def __init__(self, hz=20000000):
        import spidev
        self.spi = spidev.SpiDev()
        self.spi.open(3, 0)
        self.spi.mode = 0
        self.spi.bits_per_word = 8
        self.spi.max_speed_hz = hz
        self.tog = 0

    def wr(self, reg, val):
        self.spi.xfer2([0x70, 0x80 | (reg & 7) << 4 | (val & 15)])
        time.sleep(0.002)

    def status(self):
        r = self.spi.xfer2([0x01, 0] + [0] * 72)[2:]
        if bytes(r[0:2]) != b"Me":
            raise SystemExit("no bridge (magic %r)" % bytes(r[0:2]))
        if r[52] != 3:
            raise SystemExit("not the Amiga core (core id %d)" % r[52])
        return r

    def page(self, p):
        self.wr(6, self.tog << 3 | p)
        r = self.status()
        w = [int.from_bytes(bytes(r[60 + 4 * i:64 + 4 * i]), "big") for i in range(3)]
        return w

    def snapshot(self):
        """all pages of one snapshot (every change of register 6 bit 3 takes one; its state left by
        an earlier call is unknown: write 0, then 1 -- at least one of the two is a change)"""
        self.wr(6, 4)
        self.tog = 1
        self.wr(6, 8 | 4)
        p4 = self.page(4)
        if p4[0] != 0xA1200001:
            raise SystemExit("no stall controller in this bitstream (id %08x)" % p4[0])
        p0, p1, p2, p3 = self.page(0), self.page(1), self.page(2), self.page(3)
        cfg = p0[0] >> 8
        return {
            "e": cfg >> 20 & 15, "m": cfg >> 16 & 15, "de": cfg >> 12 & 15, "dm": cfg >> 8 & 15,
            "j": cfg >> 4 & 15, "mode": cfg & 15, "seq": p0[0] & 255,
            "lag_max": p0[1], "lag_now": p0[2],
            "stalls": p1[0], "stall_ticks": p1[1], "drops": p1[2],
            "vsyncs": p2[0], "vsync_ts": p2[1] << 32 | p2[2],
            "forgiven": p3[0], "src": p3[1] << 32 | p3[2],
            "mach": p4[1] << 32 | p4[2],
        }


def fmt(s):
    us = 1e6 / F_MACH
    return ("mode=%d e=%d m=%d de=%d dm=%d j=%d lag_now=%d (%.2f us) lag_max=%d (%.2f us) stalls=%d "
            "stall_ticks=%d drops=%d forgiven=%d vsyncs=%d src=%d mach=%d" %
            (s["mode"], s["e"], s["m"], s["de"], s["dm"], s["j"], s["lag_now"], s["lag_now"] * us,
             s["lag_max"], s["lag_max"] * us, s["stalls"], s["stall_ticks"], s["drops"], s["forgiven"],
             s["vsyncs"], s["src"], s["mach"]))


def rate(b, secs):
    a = b.snapshot()
    time.sleep(secs)
    z = b.snapshot()
    dsrc = (z["src"] - a["src"]) & (2**64 - 1)
    dv = (z["vsyncs"] - a["vsyncs"]) & 0xFFFFFFFF
    dts = (z["vsync_ts"] - a["vsync_ts"]) & (2**64 - 1)
    dm = (z["mach"] - a["mach"]) & (2**64 - 1)
    dst = (z["stall_ticks"] - a["stall_ticks"]) & 0xFFFFFFFF
    dn = (z["stalls"] - a["stalls"]) & 0xFFFFFFFF
    fr = dv / (dts / F_SRC) if dts else 0.0
    fm = dm / dsrc * F_SRC
    frames_real = dsrc / F_SRC * 50.0
    print("window %.1f s (%d source ticks): %d machine vsyncs, frame rate %.6f Hz "
          "(%+.2f ppm vs 50 Hz, %+.2f ppm vs native %.6f Hz)" %
          (dsrc / F_SRC, dsrc, dv, fr, (fr / 50.0 - 1) * 1e6,
           (fr / (F_MACH / FRAME_TICKS) - 1) * 1e6, F_MACH / FRAME_TICKS))
    print("machine clock %.3f Hz average (%+.2f ppm vs 28.375 MHz; machine/source = %.9f, 31/32 = %.9f)" %
          (fm, (fm / F_MACH - 1) * 1e6, dm / dsrc, 31 / 32))
    print("stalls %d (%.1f per 20 ms), stalled %.4f %% of real time, mean stall %.2f us; "
          "lag now %d max %d machine ticks (%.2f us); forgiven %d" %
          (dn, dn / frames_real if frames_real else 0, 100.0 * dst / dsrc, dst / dn * T_SRC if dn else 0,
           z["lag_now"], z["lag_max"], z["lag_max"] * 1e6 / F_MACH, z["forgiven"] - a["forgiven"]))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    b = Bridge()
    cmd = sys.argv[1]
    if cmd == "preset":
        p = PRESETS[sys.argv[2]]
        b.wr(0, 0)
        for k, v in zip(("e", "m", "de", "dm", "j"), p[1:6]):
            b.wr(REG[k], v)
        b.wr(0, p[0])
        print("preset %s: %s" % (sys.argv[2], p[6]))
    elif cmd == "set":
        for kv in sys.argv[2:]:
            k, v = kv.split("=")
            b.wr(REG[k], int(v))
    elif cmd == "clear":
        # every change of register 7 bit 0 clears; its state is unknown here: write 1, then 0
        b.wr(7, 1)
        b.wr(7, 0)
    elif cmd == "read":
        print(fmt(b.snapshot()))
    elif cmd == "log":
        secs = float(sys.argv[2])
        every = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
        t0 = time.time()
        while True:
            print("%s %s" % (time.strftime("%H:%M:%S"), fmt(b.snapshot())), flush=True)
            if time.time() - t0 >= secs:
                break
            time.sleep(every)
    elif cmd == "probe":
        # debug pages 5/6 (builds with the probe vector): main_clk signals at the snapshot
        b.snapshot()
        p5, p6 = b.page(5), b.page(6)
        v = p6[0] << 32 | p5[0]
        print("ram_addr=%06x (byte %06x) we_n=%d oe_n=%d cold_reset=%d reset_m2m=%d reset_core=%d vs=%d "
              "hblank=%d scrub=%d fdd_led=%d pwr_led=%d kick512=%d fast=%d slow=%d chip1m=%d ecs=%d "
              "ram_writes=%d ram_reads=%d reset_ticks=%d" %
              (v & 0x3FFFFF, (v & 0x3FFFFF) << 1, v >> 22 & 1, v >> 23 & 1, v >> 24 & 1, v >> 25 & 1,
               v >> 26 & 1, v >> 27 & 1, v >> 28 & 1, v >> 29 & 1, v >> 30 & 1, v >> 31 & 1, v >> 32 & 1,
               v >> 33 & 3, v >> 35 & 1, v >> 36 & 1, v >> 37 & 1, p5[1], p6[1], p5[2]))
    elif cmd == "rate":
        rate(b, float(sys.argv[2]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
