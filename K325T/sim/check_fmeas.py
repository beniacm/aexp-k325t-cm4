#!/usr/bin/env python3
"""check_fmeas.py -- recompute what fmeas.v must report from the bench's pixel log (tb_fmeas.v)."""
import collections
import sys

XLO, XHI, YLO, YHI, GRAB = 3, 700, 2, 280, 7


def crc12(c, d):
    for i in range(12):
        c = (c >> 1) ^ 0xEDB88320 if (c ^ (d >> i)) & 1 else c >> 1
    return c


pix = collections.defaultdict(list)            # TB frame -> [(v, h, p)]
for ln in open("fmeas_pix.txt"):
    f, v, h, p = ln.split()
    pix[int(f)].append((int(v), int(h), int(p, 16)))
q = {}
for ln in open("fmeas_q.txt"):
    k, w = ln.split()
    q[k] = int(w.replace("x", "0"), 16)   # never-written RAM words (beyond the last frame) read x


def words(x):
    return (x >> 64) & 0xFFFFFFFF, (x >> 32) & 0xFFFFFFFF, x & 0xFFFFFFFF


def frame_crc(tbf):
    c = 0xFFFFFFFF
    for v, h, p in pix.get(tbf, []):
        if XLO <= h <= XHI and YLO <= v <= YHI:
            c = crc12(c, p)
    return c ^ 0xFFFFFFFF


bad = 0
def check(name, got, exp):
    global bad
    ok = got == exp
    bad += not ok
    if not ok or name.startswith("S"):
        print("%-14s got %08x exp %08x %s" % (name, got, exp, "ok" if ok else "MISMATCH"))


# ring: DUT frame n = TB frame n-1 (the first vsync comes in line 2 of TB frame 0)
for i in range(3):
    w0, w1, w2 = words(q["R%d" % i])
    check("ring[%d]" % (2 * i), w0, frame_crc(2 * i - 1))
    if 2 * i + 1 < 5:                          # 5 frames finished when the bench reads
        check("ring[%d]" % (2 * i + 1), w1, frame_crc(2 * i))
s0 = words(q["S0"]); s1 = words(q["S1"]); s2 = words(q["S2"]); s3 = words(q["S3"])
check("S0 frames", s0[0], 5)
check("S0 capframe", s0[1], 3)   # armed in TB frame 2 before its vsync
check("S0 flags", s0[2] >> 28, 0b1000)
check("S1 id", s1[0], 0xFEA50001)
win = sum(1 for v, h, p in pix[5] if XLO <= h <= XHI and YLO <= v <= YHI)
check("S1 wpix", s1[2], sum(1 for v, h, p in pix[3] if XLO <= h <= XHI and YLO <= v <= YHI))
check("S2 xlo/xhi", s2[0], XLO << 16 | XHI)
check("S2 ylo/yhi", s2[1], YLO << 16 | YHI)
check("S2 grab", s2[2] >> 16, GRAB)
check("S3 lastcrc", s3[0], frame_crc(3))
check("S0 hpix", s0[2] & 0xFFFF, 754)
check("S0 lines", (s0[2] >> 16) & 0x3FF, 287)
# line table of DUT frame 3 = TB frame 2
lines = collections.defaultdict(list)
for v, h, p in pix[2]:
    lines[v].append((h, p))
for a in range(144):
    w0, w1, w2 = words(q["L%d" % a])
    for k, got in ((0, w0), (1, w1)):
        v = 2 * a + k
        c = 0xFFFFFFFF
        for h, p in lines.get(v, []):
            if XLO <= h <= XHI and YLO <= v <= YHI:
                c = crc12(c, p)
        exp = c ^ 0xFFFFFFFF if v in lines else got
        check("line %d" % v, got, exp)
# grab of line GRAB in TB frame 2
gl = dict(lines[GRAB])
for a in range(128):
    x = q["G%d" % a]
    for k in range(8):
        h = 8 * a + k
        got = (x >> (84 - 12 * k)) & 0xFFF
        check("grab %d" % h, got, gl.get(h, 0) if h < len(gl) else got)
print("TB_FMEAS_%s (%d mismatches)" % ("PASS" if bad == 0 else "FAIL", bad))
sys.exit(1 if bad else 0)
