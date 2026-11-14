#!/usr/bin/env python3
"""audrec.py -- the audio flight recorder (K325T/aud_rec.v, branch a1200-audrec): control, dump, decode.

On the module (next to m65d and stallmon.py; python3-spidev; writes nothing to the module's flash):
    audrec.py status               trigger / freeze state, write pointer, time, lost events, mode; and the HDMI-input
                                   hold detector (aud_hold.vhd, $CC/$CD): hold flag, episodes, longest episode, the
                                   encoder's samples per second (48000), swallowed / repeated handshakes
    audrec.py arm                  clear the ring and the snapshot, record again (the trigger re-armed); also clears
                                   the HDMI-input hold detector
    audrec.py force                force a trigger now (tests the read path; the ring freezes after 384 more events)
    audrec.py mode M               trigger mode bits: b0 mix (default on), b1 channel stuck (on), b2 channel
                                   constant (off: fires in every rest), b3 record IPL changes of every level
    audrec.py dump FILE            read everything (status, snapshots, 1,024 entries) into FILE (text; "-" =
                                   stdout, so that nothing is written on the module: ssh ... dump - > pc_file)
    audrec.py wait SECS [EVERY]    poll the status until the recorder has frozen (or SECS passed); prints the time
Anywhere:
    audrec.py decode FILE [--all]  decode a dump (also the bench's --recdump files): status, the snapshot of
                                   the four channels at the trigger, then the ring in time order (oldest first);
                                   without --all only the last 600 ms before the trigger and everything after

Protocol (stall controller page 7, aud_rec.v header): r6 = 7 selects page 7; the recorder index is r4 & r5
(entries $80-$BF with r3 = address bits 9..6, snapshot words $C0-$CB with r3 = sub-word, commands $CE / $CF;
$CC / $CD = the HDMI-input hold detector K325T/aud_hold.vhd, a1200-audrec 2 bitstreams).
Keep the stall injector off (r0 b0 = 0) while using it: registers 3-5 are also the injector's.
"""
import sys
import time

CCK = 3546895.0
KIND = {0: "W", 1: "RD!", 2: "DMAW", 3: "ST", 4: "DMA1", 5: "DMAS", 6: "IPL", 7: "CIAB", 8: "TRIGGER",
        9: "HOLDEND", 10: "RESET", 11: "ARMED", 12: "LOST", 13: "COUNT"}
REGN = {0x096: "DMACON", 0x09A: "INTENA", 0x09C: "INTREQ", 0x09E: "ADKCON"}
for _c in range(4):
    for _o, _n in ((0, "LCH"), (2, "LCL"), (4, "LEN"), (6, "PER"), (8, "VOL"), (0xA, "DAT"), (0xC, "x0C"), (0xE, "x0E")):
        REGN[0xA0 + 16 * _c + _o] = "AUD%d%s" % (_c, _n)
CIAN = {4: "TALO", 5: "TAHI", 6: "TBLO", 7: "TBHI", 0xD: "ICR", 0xE: "CRA", 0xF: "CRB"}
STN = {0: "0", 1: "1", 3: "2", 2: "3", 6: "4"}    # aud_rec state codes -> Paula states 0..4


def stn(c):
    return STN.get(c, "?%d" % c)


# ------------------------------------------------------------------------------------- the module side
class Rec:
    def __init__(self):
        sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
        from stallmon import Bridge
        self.b = Bridge()
        self.r = {3: None, 4: None, 5: None}
        self.b.wr(6, 7)

    def reg(self, n, v):
        if self.r[n] != v:
            self.b.wr(n, v)
            self.r[n] = v

    def word(self, r4, r5, r3):
        # r4 changes last when going into $Cx: r5 / r3 are set while r4 is in the entry space (no stray command)
        if self.r[4] != 8 and (self.r[5] != r5 or self.r[3] != r3):
            self.reg(4, 8)
        self.reg(5, r5)
        self.reg(3, r3)
        self.reg(4, r4)
        for _ in range(3):
            r = self.b.status()
            w = [int.from_bytes(bytes(r[60 + 4 * i:64 + 4 * i]), "big") for i in range(3)]
            w2 = None
            r = self.b.status()
            w2 = [int.from_bytes(bytes(r[60 + 4 * i:64 + 4 * i]), "big") for i in range(3)]
            if w == w2:
                return w
        return w2

    def forget(self):
        # another writer (m65d writes registers 0..3) may have changed r3-r5: write them again next time
        self.r = {3: None, 4: None, 5: None}
        self.b.wr(6, 7)

    def cmd(self, r5, r3):
        self.word(8, r5, r3)
        self.word(12, r5, r3)
        self.word(8, r5, 0)

    def status(self):
        self.forget()
        return self.word(12, 0, 0)

    def hold(self):
        return self.word(12, 12, 0), self.word(12, 13, 0)


def status_text(w0, w1, w2):
    if w0 >> 20 != 0xA19:
        return "no recorder (W0 %08x: not an a1200-audrec bitstream?)" % w0
    return ("mode %x fired %d frozen %d wrapped %d holdend %d wp %d  time %.3f s  lost %d  cause %x chmask %x" %
            (w0 >> 16 & 15, w0 >> 15 & 1, w0 >> 14 & 1, w0 >> 13 & 1, w0 >> 12 & 1, w0 & 1023, w1 / CCK,
             w2 >> 16, w2 >> 12 & 15, w2 >> 8 & 15))


def hold_text(c, d):
    """$CC / $CD of aud_hold.vhd (the audio entering the HDMI encoder, audio clock)"""
    if c[0] >> 20 != 0xA0D:
        return "hdmi input: no hold detector ($CC W0 %08x: not an a1200-audrec 2 bitstream?)" % c[0]
    return ("hdmi input: HOLD FLAG %s, episodes %d, longest episode %d ms, longest constant run (any kind) %d ms, "
            "current run %d ms, mix live %d, in an episode now %d\n"
            "hdmi handshakes: samples taken in the last second %d (must be 48000), encoder enables %d, swallowed %d, "
            "repeated %d, check active %d, seconds since arm %d" %
            ("SET" if c[0] >> 19 & 1 else "clear", c[0] & 0xFFFF, c[1] >> 16, c[1] & 0xFFFF, d[2] & 0xFFFF,
             c[0] >> 18 & 1, c[0] >> 17 & 1, c[2], d[1], d[0] >> 16, d[0] & 0xFFFF, c[0] >> 16 & 1, d[2] >> 16))


def module_main(argv):
    rec = Rec()
    cmd = argv[0]
    if cmd == "status":
        print(status_text(*rec.status()))
        print(hold_text(*rec.hold()))
    elif cmd == "arm":
        rec.cmd(15, 0xA)
        print(status_text(*rec.status()))
        print(hold_text(*rec.hold()))
    elif cmd == "force":
        rec.cmd(15, 0xC)
        print(status_text(*rec.status()))
    elif cmd == "mode":
        rec.cmd(14, int(argv[1], 0) & 15)
        print(status_text(*rec.status()))
    elif cmd == "wait":
        secs = float(argv[1]); every = float(argv[2]) if len(argv) > 2 else 5.0
        t0 = time.time()
        while True:
            w = rec.status()
            if w[0] >> 14 & 1:
                print("%s frozen after %.0f s: %s" % (time.strftime("%H:%M:%S"), time.time() - t0, status_text(*w)))
                return 0
            if time.time() - t0 > secs:
                print("%s not frozen after %.0f s: %s" % (time.strftime("%H:%M:%S"), secs, status_text(*w)))
                return 1
            time.sleep(every)
    elif cmd == "dump":
        out = []
        for k in range(12):
            for j in range(2):
                w = rec.word(12, k, j)
                out.append("S %x %d %08x %08x %08x" % (k, j, w[0], w[1], w[2]))
        for k in (12, 13):
            w = rec.word(12, k, 0)
            out.append("S %x 0 %08x %08x %08x" % (k, w[0], w[1], w[2]))
        for a in range(1024):
            w = rec.word(8 + ((a >> 4) & 3), a & 15, a >> 6)
            if (w[2] >> 2) & 1023 != a:
                rec.forget()                                         # the echo did not match: all again
                w = rec.word(8 + ((a >> 4) & 3), a & 15, a >> 6)
            out.append("E %d %08x %08x %08x" % (a, w[0], w[1], w[2]))
        rec.reg(4, 8); rec.reg(3, 0)
        f = sys.stdout if argv[1] == "-" else open(argv[1], "w")
        f.write("\n".join(out) + "\n")
        f.flush()
        bad = sum(1 for l in out if l[0] == "E" and (int(l.split()[4], 16) >> 2) & 1023 != int(l.split()[1]))
        print("dump: %s (%d lines, %d entries with a wrong address echo)" % (argv[1], len(out), bad), file=sys.stderr)
    else:
        print(__doc__)
        return 2
    return 0


# ------------------------------------------------------------------------------------- decode
def chan(d):
    f = lambda lo, n: d >> lo & ((1 << n) - 1)
    smp = f(3, 8)
    return {"state": stn(f(0, 3)), "sample": smp - 256 if smp > 127 else smp, "dmaena": f(11, 1), "intpen": f(12, 1),
            "silence": f(13, 1), "silence_d": f(14, 1), "AUDxDAT": f(15, 1), "dmareq": f(16, 1), "dmas": f(17, 1),
            "intreq2": f(18, 1), "percnt": f(19, 16), "lencnt": f(35, 16), "AUDxPER": f(51, 16), "AUDxLEN": f(67, 16),
            "AUDxVOL": f(83, 7), "datbuf": "%04x" % f(90, 16), "auddat": "%04x" % f(106, 16), "penhi": f(122, 1)}


def decode(fn, show_all):
    S = {}; E = {}
    for l in open(fn):
        p = l.split()
        if not p:
            continue
        if p[0] == "S":
            S[(int(p[1], 16), int(p[2]))] = [int(x, 16) for x in p[3:6]]
        elif p[0] == "E":
            E[int(p[1])] = [int(x, 16) for x in p[2:5]]
    w0, w1, w2 = S[(0, 0)]
    print("status: " + status_text(w0, w1, w2))
    if (12, 0) in S and (13, 0) in S:
        print(hold_text(S[(12, 0)], S[(13, 0)]))
    if w0 >> 20 != 0xA19:
        return 1
    fired, wrapped, wp = w0 >> 15 & 1, w0 >> 13 & 1, w0 & 1023
    t_trig, t_mix, t_end = S[(1, 0)]
    lr, hold, mixcon = S[(2, 0)]
    L, R = lr >> 15 & 0x7FFF, lr & 0x7FFF
    sgn = lambda v: v - 0x8000 if v & 0x4000 else v
    if fired:
        print("trigger at %.6f s (CCK %d); the mix last changed (the cut) at %.6f s (%.1f ms before), L %d R %d at the trigger"
              % (t_trig / CCK, t_trig, t_mix / CCK, (t_trig - t_mix) / CCK * 1e3, sgn(L), sgn(R)))
        if w0 >> 12 & 1:
            print("hold end (mix changed) at %.6f s: the hold lasted %.1f ms (cut -> return)"
                  % (t_end / CCK, (t_end - t_mix) / CCK * 1e3))
        else:
            print("no hold end seen yet (mix unchanged for %.1f ms at the readout)" % (mixcon / 2 / CCK * 1e3))
        for ch in range(4):
            lo = S[(4 + 2 * ch, 0)]; hi = S[(5 + 2 * ch, 0)]; ex = S[(4 + 2 * ch, 1)]
            d = (hi[0] << 96) | (lo[0] << 64) | (lo[1] << 32) | lo[2]
            c = chan(d)
            print("  ch%d at the trigger: %s" % (ch, " ".join("%s=%s" % kv for kv in c.items())))
            print("       last DMA address $%06x; since the mix's last change: %d words fetched, %d of them zero; "
                  "output byte last changed at %.6f s (%.1f ms before the trigger)"
                  % (ex[0] << 1 & 0x1FFFFE, ex[1] >> 16, ex[1] & 0xFFFF, ex[2] / CCK, (t_trig - ex[2]) / CCK * 1e3))
    order = (list(range(wp, 1024)) if wrapped else []) + list(range(0, wp))
    ents = []
    for a in order:
        v = (E[a][0] << 64) | (E[a][1] << 32) | E[a][2]
        if (v >> 2) & 1023 != a:
            print("  (entry %d: address echo %d -- read error)" % (a, (v >> 2) & 1023))
        e = v >> 24
        ents.append((e >> 42, e >> 38 & 15, e >> 12 & ((1 << 26) - 1), e & 0xFFF))
    # 30-bit time stamps: unwrap (entries are in time order), then place the newest at or before the status time
    out = []
    prev = None
    hi = 0
    for ts, k, p, st in ents:
        if prev is not None and ts < prev:
            hi += 1 << 30
        prev = ts
        out.append([ts + hi, k, p, st])
    trig = [o for o in out if o[1] == 8]
    if out and fired and trig:
        # place the ring by its trigger entry (same time stamp as t_trig, mod 2^30): right across a wrap of the
        # 32-bit status time (1,210.9 s) or of the 30-bit entry time (302.7 s)
        shift = t_trig - trig[0][0]
        for o in out:
            o[0] += shift
    elif out:
        last = out[-1][0] & ((1 << 30) - 1)
        cand = (w1 & ~((1 << 30) - 1)) + last
        if cand > w1:
            cand -= 1 << 30
        shift = cand - out[-1][0]
        for o in out:
            o[0] += shift
    tref = t_trig if fired else (out[-1][0] if out else 0)
    print("ring: %d entries, times relative to the %s (ms)" % (len(out), "trigger" if fired else "last entry"))
    for ts, k, p, st in out:
        dt = (ts - tref) / CCK * 1e3
        if not show_all and fired and dt < -600:
            continue
        sts = "".join(stn(st >> 3 * c & 7) for c in range(4))
        name = KIND.get(k, "k%d" % k)
        if k in (0, 1, 2):
            reg = (p >> 18 & 0xFF) << 1
            txt = "%-8s %04x%s" % (REGN.get(reg, "$%03x" % reg), p >> 2 & 0xFFFF, " (CPU read: Minimig wrote $FFFF)" if k == 1 else "")
        elif k == 3:
            txt = "ch%d %s->%s dma %d ip %d sil %d/%d req %d byte %d percnt..%x" % (
                p >> 24, stn(p >> 21 & 7), stn(p >> 18 & 7), p >> 17 & 1, p >> 16 & 1, p >> 15 & 1, p >> 14 & 1,
                p >> 13 & 1, ((p >> 4 & 0xFF) ^ 0x80) - 0x80, p & 15)
        elif k == 4:
            txt = "ch%d fetch $%06x" % (p >> 24, (p >> 4 & 0xFFFFF) << 1)
        elif k == 5:
            txt = "ch%d word %04x at ..%03x" % (p >> 24, p >> 8 & 0xFFFF, (p & 0xFF) << 1)
        elif k == 6:
            txt = "level %d -> %d" % (p >> 23, p >> 20 & 7)
        elif k == 7:
            txt = "%s %s %02x" % (CIAN.get(p >> 22, "rs%x" % (p >> 22)), "wr" if p >> 21 & 1 else "rd", p >> 13 & 0xFF)
        elif k == 8:
            txt = "cause %x (b0 mix, b1 stuck, b2 constant, b3 forced) channels %x" % (p >> 22, p >> 18 & 15)
        elif k == 11:
            txt = "mode %x" % (p >> 22)
        elif k == 13:
            txt = "ch%d after the trigger: %d words, %d zero" % (p >> 24, p >> 12 & 0xFFF, p & 0xFFF)
        else:
            txt = ""
        print("%10.3f  %-7s %s  [%s]" % (dt, name, txt, sts))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__); sys.exit(2)
    if a[0] == "decode":
        sys.exit(decode(a[1], "--all" in a))
    sys.exit(module_main(a))
