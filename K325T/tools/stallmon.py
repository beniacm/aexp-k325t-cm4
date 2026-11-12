#!/usr/bin/env python3
"""stallmon.py -- configure the stall injector of the stoppable Amiga clock (K325T/stall_ctrl.vhd)
and read its lag/debt monitor through the Rockchip bridge (run ON THE MODULE, next to m65d; needs
python3-spidev; writes nothing to the module's flash).

    stallmon.py preset NAME          off | rtl | mix | burst15 | budget | overload (table below)
    stallmon.py set mode=1 e=7 m=10 de=2 dm=4 j=0   (mode b0 injector, b1 native rate only,
                                     b2 avm_mig without the reset abort = the old behaviour)
    stallmon.py clear                lag max and event counters to 0
    stallmon.py read                 one snapshot, key=value
    stallmon.py log SECS [EVERY]     a snapshot every EVERY seconds (default 10), one line each
    stallmon.py cache on|off [SHRINK 0..3] [chip2m]   chip RAM through the cache (next full reset);
                                     overrides the machine profile (stage 3 P4)
    stallmon.py cache auto [SHRINK]  the profile decides (AGA = cache + 2 MB chip, else identity)
    stallmon.py cache                the memory mode in effect (read-back)
    stallmon.py pf [MASK [afifo]]           chip cache prefetch counters / set the enables (7 bits)
                                            and the audio FIFO
    stallmon.py mbox                        the Amiga's result block at $C0-$FF (16 longwords)
    stallmon.py avm                         Avalon debug: the write burst avm_mig waits in
    stallmon.py lat SECS [r|w|rw]    line latency meter (64-byte reads / writes on the MIG line port)
    stallmon.py fdbg                 stage 3: amiga_fastram / hr_core select state (debug)
    stallmon.py probe                debug builds: main_clk probe vector, RAM write/read counts
    stallmon.py rate SECS            machine frame rate (vsyncs against the ungated source clock),
                                     machine clock, stall statistics over SECS seconds

The bridge's VIDEO register (command 0x70; this core has no Linux picture) carries 1rrrvvvv
register writes, STATUS 60..71 the snapshot page selected with register 6 (stall_ctrl.vhd header).
Injector: start probability per source tick (m+1)/2^(e+8), duration ((dm+1) << de) + random
(0 .. 2^j - 1) source ticks of 1/31.310 MHz = 31.94 ns (stage 1: 34.14 ns).
"""
import sys
import time

F_SRC = 100e6 * 56.75 / 5 / 36.25          # 31.310345 MHz: the ungated source clock (stage 2;
                                           # stage 1 bitstreams: / 38.75 = 29.290 MHz)
F_MACH = 28.375e6                          # the machine clock's long-term average (native)
T_SRC = 1e6 / F_SRC                        # us per source tick
K_NAT = F_MACH / F_SRC                     # machine / source edges (29/32)
FRAME_TICKS = 313 * 227 * 8                # machine ticks per PAL frame (568,408)

PRESETS = {   # durations for the stage-2 source clock (31.94 ns ticks); the rates per frame are
              # ~7 % higher than in stage 1 (more ticks per frame)
    # name: (mode, e, m, de, dm, j, what)
    "off":      (0, 0, 0, 0, 0, 0, "injector off"),
    "rtl":      (1, 7, 10, 2, 4, 0, "0.64 us stalls, ~197 per frame (the study's worst RTL workload)"),
    "mix":      (1, 5, 4, 0, 8, 6, "0.29-2.3 us stalls, ~357 per frame, ~2.5 %"),
    "burst15":  (1, 10, 8, 5, 13, 0, "14.3 us stalls, ~20 per frame, ~1.6 %"),
    "budget":   (1, 3, 2, 2, 4, 0, "0.64 us stalls, ~858 per frame, ~2.9 % (just below 3.1 %)"),
    "overload": (1, 2, 2, 2, 4, 0, "0.64 us stalls, ~1716 per frame, ~5.9 % (beyond the 3.1 % budget)"),
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
            "fills": self.page(6)[1], "wbacks": self.page(6)[2],
            "mach": p4[1] << 32 | p4[2],
        }


def fmt(s):
    us = 1e6 / F_MACH
    return ("mode=%d e=%d m=%d de=%d dm=%d j=%d lag_now=%d (%.2f us) lag_max=%d (%.2f us) stalls=%d "
            "stall_ticks=%d drops=%d forgiven=%d vsyncs=%d src=%d mach=%d fills=%d wbacks=%d" %
            (s["mode"], s["e"], s["m"], s["de"], s["dm"], s["j"], s["lag_now"], s["lag_now"] * us,
             s["lag_max"], s["lag_max"] * us, s["stalls"], s["stall_ticks"], s["drops"], s["forgiven"],
             s["vsyncs"], s["src"], s["mach"], s["fills"], s["wbacks"]))


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
    print("machine clock %.3f Hz average (%+.2f ppm vs 28.375 MHz; machine/source = %.9f, nominal %.9f)" %
          (fm, (fm / F_MACH - 1) * 1e6, dm / dsrc, K_NAT))
    print("stalls %d (%.1f per 20 ms), stalled %.4f %% of real time, mean stall %.2f us; "
          "lag now %d max %d machine ticks (%.2f us); forgiven %d" %
          (dn, dn / frames_real if frames_real else 0, 100.0 * dst / dsrc, dst / dn * T_SRC if dn else 0,
           z["lag_now"], z["lag_max"], z["lag_max"] * 1e6 / F_MACH, z["forgiven"] - a["forgiven"]))
    df = (z["fills"] - a["fills"]) & 0xFFFFFFFF
    dw = (z["wbacks"] - a["wbacks"]) & 0xFFFFFFFF
    if df:
        print("chip cache: %d line fills (%.1f per 20 ms), %d write-backs (%.1f per 20 ms), %.2f us stalled per fill" %
              (df, df / frames_real, dw, dw / frames_real, dst / df * T_SRC))


def memstate(b):
    """stage 3 read-back (lat_meter $FB): None for bitstreams without it.  Uses page 7 and registers
    4/5 as the index (like mbox): leaves the injector's de/dm/j at 0 -- keep the injector off."""
    b.wr(6, 7)
    b.wr(4, 0xF)
    b.wr(5, 0xB)
    r = b.status()
    w0, w1, w2 = [int.from_bytes(bytes(r[60 + 4 * k:64 + 4 * k]), "big") for k in range(3)]
    b.wr(4, 0); b.wr(5, 0); b.wr(6, 0)
    if w1 >> 9:                                 # unused bits set: an older bitstream (histogram sums)
        return None
    return {"r": [w0 >> (4 * i) & 15 for i in range(8)], "pf": w1 >> 2 & 0x7F, "afifo": w1 >> 1 & 1,
            "ovr": w1 & 1, "topo": w2 >> 16 & 0x1FF, "shrink": w2 >> 8 & 3, "ovr_eff": w2 >> 7 & 1,
            "ecs": w2 >> 6 & 1, "aga": w2 >> 5 & 1, "chip2m": w2 >> 4 & 1, "cache_mode": w2 >> 3 & 1,
            "req_2m": w2 >> 2 & 1, "req_cache": w2 >> 1 & 1, "menu_aga": w2 & 1}


def memstate_str(m):
    if m is None:
        return "no read-back in this bitstream (before stage 3 P4)"
    return ("memory mode: %s; requested: cache %s, 2 MB chip %s; in effect (latched at the last reset or "
            "cold boot): cache mode %s, 2 MB chip %s, AGA %s, ECS %s; shrink %d (sets / %d); menu AGA radio %d; "
            "registers r7..r0 %s" %
            ("OVERRIDE (stallmon cache on|off)" if m["ovr"] else "follows the menu profile (cache auto)",
             "on" if m["req_cache"] else "off", "on" if m["req_2m"] else "off",
             "on" if m["cache_mode"] else "off (identity)", "on" if m["chip2m"] else "off",
             m["aga"], m["ecs"], m["shrink"], (1, 8, 64, 512)[m["shrink"]], m["menu_aga"],
             " ".join("%x" % v for v in m["r"][::-1])))


def verify(b, want, what):
    """read back the stall controller and compare: want = {"r7": v, "r0b3": v, "ovr": v, "pf": v,
    "afifo": v}; a lost write is an error (exit 1), not a silent no-op"""
    m = memstate(b)
    if m is None:
        print("(%s: no read-back in this bitstream, not verified)" % what)
        return
    got = {"r7": m["r"][7] & 0xE, "r0b3": m["r"][0] >> 3 & 1, "ovr": m["ovr"], "pf": m["pf"],
           "afifo": m["afifo"]}
    bad = {k: (v, got[k]) for k, v in want.items() if got[k] != v}
    if bad:
        sys.exit("ERROR: %s: write(s) lost, read back %s (wanted, got)" % (what, bad))


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
        s0 = b.snapshot()                    # read back (page 0 holds registers 0..5)
        bad = [k for k, v in zip(("e", "m", "de", "dm", "j"), p[1:6]) if s0[k] != v]
        if bad:
            sys.exit("ERROR: preset %s: write(s) lost, read back %s" % (sys.argv[2], {k: s0[k] for k in bad}))
        print("preset %s: %s" % (sys.argv[2], p[6]))
    elif cmd == "set":
        want = {}
        for kv in sys.argv[2:]:
            k, v = kv.split("=")
            b.wr(REG[k], int(v))
            want[k] = int(v)
        s0 = b.snapshot()                    # read back (page 0 holds registers 0..5)
        bad = {k: s0.get(k) for k, v in want.items() if k in s0 and s0[k] != v}
        if bad:
            sys.exit("ERROR: set: write(s) lost, read back %s" % bad)
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
        m = v >> 38 & 0xFFFFFF
        st = ["IDLE", "RD", "RD_END", "WR", "FLUSH", "DRAIN"]
        print("avm_mig: state %s, beats_left %d, inflight %d, fifo %d, aborts %d (mod 16)" %
              (st[m >> 16 & 15] if (m >> 16 & 15) < 6 else m >> 16 & 15, m >> 8 & 255, m >> 4 & 15,
               m & 15, m >> 20 & 15))
    elif cmd == "pf":
        # chip cache prefetchers: "pf MASK" sets the enables (b0 bitplane, b1 sprite, b2 audio, b3 disk,
        # b4 copper, b5 blitter, b6 CPU; via page 5 + registers 3/4, injector off), "pf" reads the counters
        names = ["bitplane", "sprite", "audio", "disk", "copper", "blitter", "CPU"]
        if len(sys.argv) > 2:
            m = int(sys.argv[2], 0)
            af = "afifo" in sys.argv[3:]          # register 4 bit 3: the audio FIFO (audio_fifo.vhd)
            b.wr(6, 5)
            b.wr(3, m & 15)
            b.wr(4, (m >> 4 & 7) | (8 if af else 0))
            b.wr(6, 0)
            verify(b, {"pf": m & 0x7F, "afifo": 1 if af else 0}, "pf")
            print("prefetch enables %s; audio FIFO %s" %
                  (", ".join(n for i, n in enumerate(names) if m >> i & 1) or "none", "on" if af else "off"))
        else:
            b.wr(6, 7)
            for c, n in enumerate(names):
                b.wr(4, 0xD)
                b.wr(5, c)
                r = b.status()
                w = [int.from_bytes(bytes(r[60 + 4 * k:64 + 4 * k]), "big") for k in range(3)]
                print("%-9s issued %10d  useful %10d  wasted %10d  (hit rate %s)" %
                      (n, w[0], w[1], w[2], "%.1f %%" % (100.0 * w[1] / w[0]) if w[0] else "-"))
            b.wr(4, 0); b.wr(5, 0); b.wr(6, 0)
    elif cmd == "mbox":
        # the core's result mailbox: the longwords the Amiga last wrote to $C0-$FF (lat_meter $E0-$E5)
        pass                                # (register 0 kept: it holds the cache shrink bit 1;
        #  keep the stall injector off while reading these)
        b.wr(6, 7)
        out = []
        for i in range(6):
            b.wr(4, 0xE)
            b.wr(5, i)
            r = b.status()
            out += [int.from_bytes(bytes(r[60 + 4 * k:64 + 4 * k]), "big") for k in range(3)]
        b.wr(4, 0); b.wr(5, 0); b.wr(6, 0)
        print(" ".join("%08x" % v for v in out[:16]))
    elif cmd == "avm":
        # Avalon debug words of the top (lat_meter index $FF / $FE): the write burst avm_mig is in
        pass                                # (register 0 kept: it holds the cache shrink bit 1;
        #  keep the stall injector off while reading these)
        b.wr(6, 7)
        def rd(i):
            b.wr(4, i >> 4)
            b.wr(5, i & 15)
            r = b.status()
            return [int.from_bytes(bytes(r[60 + 4 * k:64 + 4 * k]), "big") for k in range(3)]
        a0, a1 = rd(0xFF), rd(0xFE)
        b.wr(4, 0); b.wr(5, 0); b.wr(6, 0)
        f = a0[2]                           # W0 = live address, W1 = burst start, W2 = flags
        st = ["IDLE", "RD", "RD_END", "WR", "FLUSH", "DRAIN"]
        print("live: write=%d read=%d waitrequest=%d avm_rst=%d st=%s burstcount=%d address=%08x" %
              (f >> 7 & 1, f >> 6 & 1, f >> 5 & 1, f >> 4 & 1, st[f & 15] if (f & 15) < 6 else f & 15,
               f >> 8 & 255, a0[0]))
        print("write burst: start %08x, burstcount %d, beats still expected %d, began %d ui ticks "
              "(%.3f ms) after the last memory reset" % (a0[1], f >> 16 & 255, f >> 24 & 255, a1[0],
                                                         a1[0] / 1e5))
        print("since the last memory reset: %d write bursts, %d read bursts; last read %08x" %
              (a1[2] >> 16, a1[2] & 0xFFFF, a1[1]))
    elif cmd == "fdbg":
        # stage 3: amiga_fastram + the hr_core select (lat_meter $FD / $FC)
        b.wr(6, 7)
        def rd(i):
            b.wr(4, i >> 4)
            b.wr(5, i & 15)
            r = b.status()
            return [int.from_bytes(bytes(r[60 + 4 * k:64 + 4 * k]), "big") for k in range(3)]
        w0, w1, w2 = rd(0xFD)
        w3, w4, w5 = rd(0xFC)
        b.wr(4, 0); b.wr(5, 0); b.wr(6, 0)
        ms = ["IDLE", "READ", "FILL", "SERVED"][w0 >> 30]
        print("core: m_state=%s busy=%d req_tgl=%d ack_dd=%d fill=%d hit=%d ready=%d orphan=%d sel=%d we=%d "
              "pulse=%d fix=%d requests=%d addr=%07x" %
              (ms, w0 >> 29 & 1, w0 >> 28 & 1, w0 >> 27 & 1, w0 >> 26 & 1, w0 >> 25 & 1, w0 >> 24 & 1,
               w0 >> 23 & 1, w0 >> 22 & 1, w0 >> 21 & 1, w0 >> 20 & 1, w0 >> 19 & 1, w0 & 0xFFFF, w1 & 0x7FFFFFF))
        hs = ["QUIET", "IDLE", "FILL_CMD", "FILL_DATA", "WRITE_CMD", "?5", "?6", "?7"][w2 >> 29]
        print("mem:  hr_state=%s req_dd=%d ack_tgl=%d beat=%d avm_read=%d avm_write=%d waitrequest=%d "
              "rdvalid=%d hr_rst=%d acks=%d quiet=%d aborts=%d stray_beats=%d state_age=%d%s" %
              (hs, w2 >> 28 & 1, w2 >> 27 & 1, w2 >> 24 & 7, w2 >> 23 & 1, w2 >> 22 & 1, w2 >> 21 & 1,
               w2 >> 20 & 1, w2 >> 19 & 1, w2 & 0xFFFF, w3 >> 24, w3 >> 16 & 255, w3 >> 8 & 255,
               w4 >> 16, "+" if w4 >> 16 == 0xFFFF else ""))
        print("sel:  hr_fast_on=%d hr_fast_sel=%d fix=%d quiet_cnt=%d select_changes=%d fast_on_falls=%d "
              "blocked_clocks=%d%s" %
              (w5 >> 31, w5 >> 30 & 1, w5 >> 29 & 1, w5 >> 20 & 63, w5 >> 12 & 255, w5 >> 4 & 255,
               w4 & 0xFFFF, "+" if w4 & 0xFFFF == 0xFFFF else ""))
    elif cmd == "rate":
        rate(b, float(sys.argv[2]))
    elif cmd == "cache":
        # memory mode, taken at the next FULL reset (or a cold boot of the Amiga):
        #   cache                               show what is in effect (read-back)
        #   cache auto [SHRINK]                 stage 3 P4: the machine profile decides (AGA = cache + 2 MB
        #                                       chip RAM, else identity) -- the state after a configuration
        #   cache off|on [SHRINK 0..3] [chip2m] override the profile (tests: shrink levels, the cache for
        #                                       the A500, 2 MB chip RAM with ECS)
        if len(sys.argv) == 2:
            print(memstate_str(memstate(b)))
            return
        auto = sys.argv[2] == "auto"
        on = sys.argv[2] == "on"
        shrink = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 0
        c2 = "chip2m" in sys.argv[3:] and not auto
        b.wr(0, (shrink >> 1 & 1) << 3)     # register 0: b3 = shrink bit 1 (injector off)
        r7 = (shrink & 1) << 3 | (4 if c2 else 0) | (2 if on else 0)
        b.wr(7, r7)
        b.wr(6, 5)                          # page 5: register 5 b1 = the override (b0 unused)
        b.wr(5, 0 if auto else 2)
        b.wr(6, 0)
        verify(b, {"r7": r7, "r0b3": shrink >> 1 & 1, "ovr": 0 if auto else 1}, "cache")
        if auto:
            print("cache auto (the machine profile decides), shrink %d (sets / %d) -- now a full reset" %
                  (shrink, (1, 8, 64, 512)[shrink]))
        else:
            print("cache %s, shrink %d (sets / %d), %s (override) -- now a full reset" %
                  ("on" if on else "off", shrink, (1, 8, 64, 512)[shrink],
                   "2 MB chip" if c2 else "chip as in the menu"))
    elif cmd == "lat":
        # line latency meter (lat_meter.vhd, page 7): lat SECS [r|w|rw]
        secs = float(sys.argv[2])
        what = sys.argv[3] if len(sys.argv) > 3 else "rw"
        en = (1 if "r" in what else 0) | (2 if "w" in what else 0)
        b.wr(0, 0)                          # injector off (registers 3..5 are shared)
        b.wr(6, 7)
        b.wr(3, 4)                          # clear
        b.wr(3, en)
        time.sleep(secs)
        b.wr(3, 8 | en)                     # freeze
        def rd(i):
            b.wr(4, i >> 4)
            b.wr(5, i & 15)
            r = b.status()
            return [int.from_bytes(bytes(r[60 + 4 * k:64 + 4 * k]), "big") for k in range(3)]
        for d, name in ((0, "read"), (1, "write")):
            if not en & (1 << d):
                continue
            hist = [rd(64 * d + i)[0] for i in range(64)]
            w = rd(64 * d)
            mn, mx, n = w[1] >> 16, w[1] & 0xFFFF, w[2]
            sv = rd(128 + 64 * d)
            tot = sv[2] << 32 | sv[0]
            if n == 0:
                print("%s: no samples" % name)
                continue
            def pct(p):
                c, lim = 0, p * n
                for i, h in enumerate(hist):
                    c += h
                    if c >= lim:
                        return i * 40, i * 40 + 40      # ns range of the bin
                return 2520, None
            md, p999 = pct(0.5), pct(0.999)
            print("%s: %d lines, min %d ns, median %d-%d ns, 99.9 %% %d-%s ns, max %d ns, mean %.0f ns" %
                  (name, n, mn * 10, md[0], md[1], p999[0], p999[1], mx * 10, tot * 10.0 / n))
            print("  histogram (40 ns bins, nonzero): " +
                  " ".join("%d:%d" % (i * 40, h) for i, h in enumerate(hist) if h))
        b.wr(3, 0)
        b.wr(6, 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
