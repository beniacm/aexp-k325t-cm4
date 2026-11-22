#!/usr/bin/env python3
"""fmeas.py -- the frame measure (K325T/fmeas.v, branch a500-bacon): readout on the module, reference
CRCs and comparison on the PC.

On the module (next to m65d; python3-spidev; writes nothing to the module's flash; copy it to /run):
    fmeas.py status                    frame count, captured frame, flags, window, last CRC
    fmeas.py win XLO XHI YLO YHI       set the CRC window (pixel / line indices, inclusive)
    fmeas.py grabline N                line of the next capture's pixel grab
    fmeas.py gmask MASK                register groups the write recorder keeps (bit g = registers $g0-$gF
                                       word index, i.e. byte addresses $(2g)0-$(2g+1)E; default $0390)
    fmeas.py capture                   arm, wait for the captured frame, print its line table and grab
    fmeas.py capat PREV N [SECS]       wait (up to SECS, default 600) for the first frame f whose CRC differs
                                       from its predecessor's CRC PREV (hex), then capture frame f+N
                                       (N >= ~20) and print it as "capture" does, plus f
    fmeas.py capon CRC N [SECS]        the same, f = the first frame whose CRC is CRC (a unique frame)
    fmeas.py log SECS                  stream "frame crc" lines of every finished frame for SECS seconds
                                       (stdout: ssh ... log 600 > pc_file; reads the 2048-frame ring
                                       about 4 times a second)
On the PC:
    fmeas.py ppmcrc PPM X0 Y0 W H [--ys 2]   CRC of an emulator frame's window (the same reduction and
                                       CRC as fmeas.v; --ys 2: every 2nd row of a line-doubled frame)
    fmeas.py segments BOARD.log REF.log  the board run as runs of frames equal to the reference (with the
                                       reference offset of each run) and the differing stretches
    fmeas.py calib CAPTURE.txt PPM      align a "capture" print-out (line table + grab) with an emulator
                                       frame (line-doubled): best column / row offset of the grab line,
                                       then which line CRCs match for that offset
    fmeas.py compare BOARD.log REF.log [--sync CRC]   align two "frame crc" logs at the first frame with
                                       CRC SYNC (default: the first CRC both share after a run of 50
                                       equal frames) and report the first differing frame, matching runs
Protocol (fmeas.v header): page 7 (r6 = 7), idx = r4 & r5 with r3 as the low address nibble; commands
on changes of r5 with r4 = $D.  Keep the stall injector off (r0 b0 = 0): r3..r5 are also its registers.
"""
import sys
import time

POLY = 0xEDB88320


def crc12(c, d):
    for i in range(12):
        c = (c >> 1) ^ POLY if (c ^ (d >> i)) & 1 else c >> 1
    return c


# ------------------------------------------------------------------------------------- the module side
class Bridge:
    def __init__(self, hz=20000000):
        import spidev
        self.spi = spidev.SpiDev()
        self.spi.open(3, 0)
        self.spi.mode = 0
        self.spi.bits_per_word = 8
        self.spi.max_speed_hz = hz
        self.r = {}

    def wr(self, reg, val, force=False):
        if force or self.r.get(reg) != val:
            self.spi.xfer2([0x70, 0x80 | (reg & 7) << 4 | (val & 15)])
            self.r[reg] = val
            time.sleep(0.0003)

    def words(self):
        r = self.spi.xfer2([0x01, 0] + [0] * 72)[2:]
        if bytes(r[0:2]) != b"Me":
            raise SystemExit("no bridge (magic %r)" % bytes(r[0:2]))
        if r[52] != 3:
            raise SystemExit("not the Amiga core (core id %d)" % r[52])
        return [int.from_bytes(bytes(r[60 + 4 * i:64 + 4 * i]), "big") for i in range(3)]


class Meas:
    def __init__(self):
        self.b = Bridge()
        self.b.wr(6, 7, force=True)

    def sel(self, idx, a3, force=False):
        b = self.b
        if force:
            b.wr(6, 7, force=True)
        b.wr(4, idx >> 4, force)
        b.wr(5, idx & 15, force)
        b.wr(3, a3, force)

    def read(self, idx, a3, echo=None):
        """the 96-bit word at idx / a3; echo(w2) -> expected echo check"""
        for tries in range(8):
            self.sel(idx, a3, force=tries > 0)
            w = self.b.words()
            if echo is None or echo(w[2]):
                return w
        raise SystemExit("no echo for idx %02x a3 %x: %08x" % (idx, a3, w[2]))

    def status(self):
        s = [self.read(0xDC, k) for k in range(4)]
        if s[1][0] != 0xFEA50001:
            raise SystemExit("no frame measure in this bitstream (id %08x)" % s[1][0])
        f = s[0][2]
        return {"frames": s[0][0], "capframe": s[0][1], "captured": f >> 31 & 1, "armed": f >> 30 & 1,
                "capturing": f >> 29 & 1, "nib": f >> 28 & 1, "lines": f >> 16 & 0x3FF, "hpix": f & 0xFFFF,
                "resetframe": s[1][1], "wpix": s[1][2], "xlo": s[2][0] >> 16, "xhi": s[2][0] & 0xFFFF,
                "ylo": s[2][1] >> 16, "yhi": s[2][1] & 0xFFFF, "grab": s[2][2] >> 16, "sr": s[2][2] & 0xFFFF,
                "lastcrc": s[3][0], "wpix_cap": s[3][1], "lines_cap": s[3][2] >> 16,
                "rcnt": s[3][2] >> 4 & 0xFFF, "rovf": s[3][2] >> 3 & 1, "gmask": self.read(0xDC, 4)[0] >> 16}

    def cmd(self, r5, r3):
        """one command: r5 transition into r5 (from a neutral $C) with r4 = $D and r3 set first"""
        b = self.b
        b.wr(4, 0xD)
        b.wr(5, 0xC)
        b.wr(3, r3)
        b.wr(5, r5)
        b.wr(5, 0xC)

    def param(self, n, val):
        b = self.b
        b.wr(4, 0xD)
        b.wr(5, 0xC)
        b.wr(5, 9)
        for k in (3, 2, 1, 0):
            b.wr(3, val >> (4 * k) & 15, force=True)
            b.wr(5, 8 if k % 2 else 9)
        b.wr(3, n)
        b.wr(5, 0xA)
        b.wr(5, 0xC)

    def ring_pair(self, a):
        return self.read(0x80 | a >> 4, a & 15, echo=lambda w2: w2 >> 22 == a)

    def capture(self, timeout=5.0):
        st0 = self.status()
        self.cmd(0xB, 1)
        t = time.time()
        while time.time() - t < timeout:
            st = self.status()
            if st["captured"] and st["capframe"] != st0["capframe"] or (st["captured"] and not st0["captured"]):
                break
            time.sleep(0.02)
        else:
            raise SystemExit("no capture within %.1f s" % timeout)
        lt = []
        for a in range(256):
            w = self.read(0xC0 | a >> 4, a & 15, echo=lambda w2, a=a: w2 >> 24 == a)
            lt += [w[0], w[1]]
        px = []
        for a in range(128):
            w = self.read(0xD0 | a >> 4, a & 15)
            x = w[0] << 64 | w[1] << 32 | w[2]
            px += [(x >> (84 - 12 * k)) & 0xFFF for k in range(8)]
        st = self.status()
        rw = []
        for k in range(min(st["rcnt"], 2048)):
            for tries in range(8):
                self.sel(k >> 4, k & 15, force=tries > 0)
                w = self.b.words()
                if (w[1] >> 5) & 0x7FF == k:
                    break
            else:
                raise SystemExit("no echo for register write %d" % k)
            rw.append((w[0] >> 31, w[0] >> 16 & 0x1FF, w[0] >> 8 & 0xFF, (w[0] & 0xFF) << 1, w[1] >> 16))
        return st, lt, px, rw


def print_capture(st, lt, px, rw):
    print("captured frame %d lines %d wpix %d regwrites %d%s" % (st["capframe"], st["lines_cap"], st["wpix_cap"],
          st["rcnt"], " OVERFLOW" if st["rovf"] else ""))
    print("grab %d" % st["grab"])
    for v in range(st["lines_cap"]):
        print("L %d %08x" % (v, lt[v]))
    print("G " + " ".join("%03x" % p for p in px))
    for d, ln, c, rg, dt in rw:
        print("W %s %3d %3d %03X %04X" % ("cop" if d else "cpu", ln, c, rg, dt))


def main_module(a):
    m = Meas()
    if a[0] == "status":
        st = m.status()
        print(" ".join("%s=%s" % (k, ("%08x" % v) if k == "lastcrc" else v) for k, v in st.items()))
    elif a[0] == "win":
        for n, v in enumerate(int(x, 0) for x in a[1:5]):
            m.param(n, v)
        print(m.status())
    elif a[0] == "grabline":
        m.param(4, int(a[1], 0))
        print(m.status())
    elif a[0] == "capture":
        print_capture(*m.capture())
    elif a[0] == "gmask":
        m.param(5, int(a[1], 0))
        print(m.status())
    elif a[0] in ("capat", "capon"):
        prev, n = int(a[1], 16), int(a[2])
        on = a[0] == "capon"            # capon: f = the first frame whose CRC IS the given one
        secs = float(a[3]) if len(a) > 3 else 600.0
        t0 = time.time()
        nxt = m.read(0xDC, 0)[0]
        last = None
        f0 = None
        while f0 is None and time.time() - t0 < secs:
            fc = m.read(0xDC, 0)[0]
            if fc - nxt > 2000:
                nxt = fc - 2000
                last = None
            while nxt + 1 < fc and f0 is None:
                w = m.ring_pair((nxt >> 1) & 1023)
                for k in ((0, 1) if nxt & 1 == 0 else (1,)):
                    c = w[k]
                    fr = (nxt & ~1) + k
                    if (on and c == prev) or (not on and last == prev and c != prev):
                        f0 = fr
                        break
                    last = c
                nxt = (nxt & ~1) + 2
            time.sleep(0.005)
        if f0 is None:
            raise SystemExit("no change after %08x within %.0f s" % (prev, secs))
        target = f0 + n
        while m.read(0xDC, 0)[0] < target - 1:
            time.sleep(0.002)
        st0 = m.status()
        if st0["frames"] != target - 1:
            raise SystemExit("late: frames %d, target %d (choose a larger N)" % (st0["frames"], target))
        r = m.capture()
        print("change at frame %d (from %08x); target %d" % (f0, prev, target))
        print_capture(*r)
    elif a[0] == "regseries":
        # regseries SECS: capture frame after frame (as fast as the readout allows) and print only the
        # recorded register writes of each captured frame (no line table / grab)
        secs = float(a[1]); t0 = time.time()
        while time.time() - t0 < secs:
            st0 = m.status()
            m.cmd(0xB, 1)
            for _ in range(200):
                st = m.status()
                if st["captured"] and st["capframe"] != st0["capframe"]:
                    break
                time.sleep(0.005)
            n = min(st["rcnt"], 2048)
            out = []
            for k in range(n):
                for tries in range(8):
                    m.sel(k >> 4, k & 15, force=tries > 0)
                    w = m.b.words()
                    if (w[1] >> 5) & 0x7FF == k:
                        break
                out.append("%s %d %d %03X %04X" % ("cop" if w[0] >> 31 else "cpu", w[0] >> 16 & 0x1FF,
                                                   w[0] >> 8 & 0xFF, (w[0] & 0xFF) << 1, w[1] >> 16))
            cf = st["capframe"]
            while m.read(0xDC, 0)[0] <= cf:
                time.sleep(0.005)
            crc = m.ring_pair((cf >> 1) & 1023)[cf & 1]
            print("F %d crc %08x n %d%s | %s" % (cf, crc, st["rcnt"], " OVF" if st["rovf"] else "", "; ".join(out)), flush=True)
    elif a[0] == "log":
        secs = float(a[1])
        t0 = time.time()
        st = m.status()
        nxt = st["frames"]                     # the first frame that finishes from now on
        print("# start frames=%d resetframe=%d window %d-%d x %d-%d nib=%d" % (
            st["frames"], st["resetframe"], st["xlo"], st["xhi"], st["ylo"], st["yhi"], st["nib"]), flush=True)
        lost = 0
        while time.time() - t0 < secs:
            fc = m.read(0xDC, 0)[0]
            if fc - nxt > 2000:
                lost += fc - 2000 - nxt
                print("# LOST %d frames (%d .. %d)" % (fc - 2000 - nxt, nxt, fc - 2001), flush=True)
                nxt = fc - 2000
            while nxt + 1 < fc:                # whole pairs only (both frames finished)
                a2 = (nxt >> 1) & 1023
                w = m.ring_pair(a2)
                if nxt & 1 == 0:
                    print("%d %08x\n%d %08x" % (nxt, w[0], nxt + 1, w[1]))
                    nxt += 2
                else:
                    print("%d %08x" % (nxt, w[1]))
                    nxt += 1
            sys.stdout.flush()
            time.sleep(0.25)
        print("# end frames=%d lost=%d" % (nxt, lost), flush=True)


# ------------------------------------------------------------------------------------- the PC side
def ppm_rgb(path):
    import numpy as np
    with open(path, "rb") as f:
        data = f.read()
    parts = data.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    a = np.frombuffer(parts[4][-w * h * 3:], dtype=np.uint8).reshape(h, w, 3)
    return a


def window_crc(a, x0, y0, w, h, ys=1):
    """CRC of a frame window as fmeas.v computes it: rows y0, y0+ys, ..; columns x0 .. x0+w-1"""
    c = 0xFFFFFFFF
    for y in range(y0, y0 + h * ys, ys):
        row = a[y, x0:x0 + w]
        for r, g, b in row:
            c = crc12(c, (int(r) >> 4) << 8 | (int(g) >> 4) << 4 | int(b) >> 4)
    return c ^ 0xFFFFFFFF


def read_log(p):
    d = {}
    for ln in open(p):
        if ln.startswith("#") or not ln.strip():
            continue
        f, c = ln.split()[:2]
        d[int(f)] = int(c, 16)
    return d


def compare(board, ref, sync=None, run=50):
    B = read_log(board)
    R = read_log(ref)
    bk = sorted(B)
    rk = sorted(R)
    if sync is None:
        # the first board frame that starts a run of `run` frames identical to some reference frames
        rpos = {}
        for f in rk:
            rpos.setdefault(R[f], f)
        for f in bk:
            if B[f] in rpos:
                r0 = rpos[B[f]]
                if all(B.get(f + i) == R.get(r0 + i) for i in range(run)):
                    return report(B, R, f, r0)
        return "no common run of %d frames" % run
    fb = next(f for f in bk if B[f] == sync)
    fr = next(f for f in rk if R[f] == sync)
    return report(B, R, fb, fr)


def segments(board, ref, run=25, maxgap=3000):
    """walk the board log and describe it as runs of frames equal to the reference at a fixed offset
    (reference frame = board frame + offset), with the mismatching stretches between them"""
    B = read_log(board)
    R = read_log(ref)
    pos = {}
    for f in sorted(R):
        pos.setdefault(R[f], []).append(f)
    bk = sorted(B)
    out = []
    off = None
    i = 0
    seg = None
    bad = None
    while i < len(bk):
        f = bk[i]
        if off is not None and R.get(f + off) == B[f]:
            if bad is not None:
                out.append(("DIFF", bad[0], bad[1], off, bad[1] - bad[0] + 1))
                bad = None
            if seg is None:
                seg = [f, f]
            seg[1] = f
            i += 1
            continue
        # a mismatch, or no offset yet: look for a new run starting here
        cand = None
        for r0 in pos.get(B[f], []):
            o = r0 - f
            if all(B.get(f + k) == R.get(f + k + o) for k in range(run)):
                if cand is None or (off is not None and abs(o - off) < abs(cand - off)):
                    cand = o
                    if off is None:
                        break
        if cand is not None and cand != off:
            if seg is not None:
                out.append(("EQUAL", seg[0], seg[1], off, seg[1] - seg[0] + 1))
                seg = None
            if bad is not None:
                out.append(("DIFF", bad[0], bad[1], off, bad[1] - bad[0] + 1))
                bad = None
            off = cand
            continue
        if seg is not None:
            out.append(("EQUAL", seg[0], seg[1], off, seg[1] - seg[0] + 1))
            seg = None
        if bad is None:
            bad = [f, f]
        bad[1] = f
        i += 1
    if seg is not None:
        out.append(("EQUAL", seg[0], seg[1], off, seg[1] - seg[0] + 1))
    if bad is not None:
        out.append(("DIFF", bad[0], bad[1], off, bad[1] - bad[0] + 1))
    lines = ["%-5s board %6d..%6d  ref offset %s  (%d frames)" % x for x in out]
    return "\n".join(lines)


def report(B, R, fb, fr):
    out = ["sync: board frame %d = reference frame %d" % (fb, fr)]
    n = 0
    first = None
    same = 0
    while fb + n in B and fr + n in R:
        if B[fb + n] != R[fr + n]:
            if first is None:
                first = n
        else:
            same += 1
        n += 1
    out.append("compared %d frames from the sync on: %d equal, first difference at sync+%s" % (
        n, same, first))
    return "\n".join(out)


def read_capture(p):
    lt, px, grab = {}, [], None
    for ln in open(p):
        w = ln.split()
        if not w:
            continue
        if w[0] == "L":
            lt[int(w[1])] = int(w[2], 16)
        elif w[0] == "G":
            px = [int(x, 16) for x in w[1:]]
        elif w[0] == "grab":
            grab = int(w[1])
    return lt, px, grab


def calib(cap, ppm, grab=None, ys=2):
    import numpy as np
    a = ppm_rgb(ppm).astype(int)
    lt, px, g2 = read_capture(cap)
    grab = grab if grab is not None else g2
    e = (a[:, :, 0] >> 4) << 8 | (a[:, :, 1] >> 4) << 4 | (a[:, :, 2] >> 4)
    H, W = e.shape
    n = max(lt) + 1 if lt else 0
    best = []
    for dy in range(-6, 7):
        y = (grab + dy) * ys
        if not 0 <= y < H:
            continue
        for dx in range(-12, 13):
            m = t = 0
            for h in range(len(px)):
                x = h + dx
                if 0 <= x < W and h < 760:
                    t += 1
                    m += px[h] == e[y, x]
            best.append((m / max(t, 1), m, t, dx, dy))
    best.sort(reverse=True)
    out = ["grab line %d: best (share, matches, compared, dx, dy) %s" % (grab, best[:4])]
    return "\n".join(out)


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__)
    elif a[0] == "ppmcrc":
        ys = 2 if "--ys" in a and a[a.index("--ys") + 1] == "2" else 1
        x0, y0, w, h = (int(x) for x in a[2:6])
        print("%08x" % window_crc(ppm_rgb(a[1]), x0, y0, w, h, ys))
    elif a[0] == "segments":
        print(segments(a[1], a[2]))
    elif a[0] == "calib":
        print(calib(a[1], a[2], int(a[3]) if len(a) > 3 else None))
    elif a[0] == "compare":
        sync = int(a[a.index("--sync") + 1], 16) if "--sync" in a else None
        print(compare(a[1], a[2], sync))
    else:
        main_module(a)
