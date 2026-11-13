#!/usr/bin/env python3
"""bitcensus.py FILE.bit [FILE.bit ...] -- frame census of a 7-series configuration bitstream (own code).

Walks the packet stream (sync word AA995566, type-1/type-2 packets) and reports, per file:
  - the bytes of the configuration data and how they split into FDRI frame data, MFWR (multi-frame
    write: a frame repeated at another address = compression), and the rest (commands, CRC, padding);
  - FDRI frames per FAR block type (0 = CLB/IO/CLK: logic + routing, 1 = block-RAM content, 2 = CFG_CLB)
    and per top/bottom half and clock row, attributed to the FAR written before each FDRI burst
    (a burst that runs on across rows is counted at its start address; with --debug-bitstream files,
    which write the FAR before every frame, the attribution is exact);
  - MFWR writes per block type (frames that cost ~8 words each instead of 101);
  - with --cols: FDRI frames per (block type, half, row, column) of the burst start.
7-series frames are 101 words (404 bytes).  FAR: [25:23] block type, [22] bottom half, [21:17] row,
[16:7] column, [6:0] minor."""
import argparse, collections, struct, sys

REG = {0: "CRC", 1: "FAR", 2: "FDRI", 3: "FDRO", 4: "CMD", 5: "CTL0", 6: "MASK", 7: "STAT", 8: "LOUT",
       9: "COR0", 10: "MFWR", 11: "CBC", 12: "IDCODE", 13: "AXSS", 14: "COR1", 16: "WBSTAR", 17: "TIMER",
       22: "BOOTSTS", 24: "CTL1", 31: "BSPI"}
FRAME = 101


def config_data(path):
    raw = open(path, "rb").read()
    if path.endswith(".bit"):
        p = 13
        while p < len(raw):
            key = raw[p]
            if key == 0x65:
                n = int.from_bytes(raw[p + 1:p + 5], "big")
                return raw[p + 5:p + 5 + n]
            n = int.from_bytes(raw[p + 1:p + 3], "big")
            p += 3 + n
        sys.exit("%s: not a .bit file" % path)
    return raw


def far_fields(f):
    return (f >> 23) & 7, (f >> 22) & 1, (f >> 17) & 31, (f >> 7) & 1023, f & 127


def census(path, cols=False):
    d = config_data(path)
    sync = d.find(b"\xaa\x99\x55\x66")
    if sync < 0:
        sys.exit("%s: no sync word" % path)
    words = struct.unpack(">%dI" % ((len(d) - sync) // 4), d[sync:sync + (len(d) - sync) // 4 * 4])
    i, last_reg, far = 1, None, 0
    regbytes = collections.Counter()
    fdri_frames = collections.Counter()           # (type) -> frames
    fdri_rows = collections.Counter()             # (type, half, row) -> frames
    fdri_cols = collections.Counter()             # (type, half, row, col) -> frames
    mfwr = collections.Counter()                  # type -> MFWR writes
    bursts = collections.Counter()                # type -> FDRI bursts
    cmds = collections.Counter()
    while i < len(words):
        w = words[i]
        t = w >> 29
        if t == 1:
            op, reg, cnt = (w >> 27) & 3, (w >> 13) & 31, w & 2047
            i += 1
            data = words[i:i + cnt]
            i += cnt
            last_reg = reg
            if op != 2:
                continue
        elif t == 2:
            op, cnt = (w >> 27) & 3, w & 0x7FFFFFF
            i += 1
            data = words[i:i + cnt]
            i += cnt
            reg = last_reg
            if op != 2:
                continue
        else:
            i += 1                                # NOOP / padding
            regbytes["(noop/pad)"] += 4
            continue
        name = REG.get(reg, "R%d" % reg)
        regbytes[name] += 4 * (len(data) + 1)
        if name == "FAR" and data:
            far = data[-1]
        elif name == "CMD" and data:
            cmds[data[0]] += 1
        elif name == "FDRI" and data:
            # the first frame of a burst is a pipeline frame (written out when the next arrives), so a
            # burst of n words carries n/101 frames including one pad frame at its end
            n = len(data) // FRAME
            bt, half, row, col, minor = far_fields(far)
            fdri_frames[bt] += n
            fdri_rows[(bt, half, row)] += n
            bursts[bt] += 1
            if cols:
                fdri_cols[(bt, half, row, col)] += n
        elif name == "MFWR":
            bt = far_fields(far)[0]
            mfwr[bt] += 1
    return len(d), regbytes, fdri_frames, fdri_rows, fdri_cols, mfwr, bursts, cmds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--cols", action="store_true")
    a = ap.parse_args()
    for path in a.files:
        n, rb, ff, fr, fc, mf, bu, cmds = census(path, a.cols)
        print("== %s: %d bytes of configuration data" % (path, n))
        for k, v in sorted(rb.items(), key=lambda x: -x[1]):
            print("   %-10s %9d bytes" % (k, v))
        tot = sum(ff.values())
        print("   FDRI frames written: %d (= %d bytes); per block type:" % (tot, tot * FRAME * 4))
        for bt in sorted(ff):
            print("     type %d %-14s %6d frames %9d bytes in %5d bursts; MFWR repeats %6d" %
                  (bt, {0: "(logic/route)", 1: "(BRAM content)", 2: "(CFG_CLB)"}.get(bt, ""), ff[bt],
                   ff[bt] * FRAME * 4, bu[bt], mf.get(bt, 0)))
        for bt in sorted(set(mf) - set(ff)):
            print("     type %d MFWR repeats %d (no FDRI)" % (bt, mf[bt]))
        print("   FDRI frames per (type, half, row):")
        for k in sorted(fr):
            print("     type %d %s row %2d: %6d frames" % (k[0], "bot" if k[1] else "top", k[2], fr[k]))
        if a.cols:
            print("   FDRI frames per (type, half, row, column of the burst start):")
            for k in sorted(fc):
                print("     %d %s r%2d c%3d: %5d" % (k[0], "b" if k[1] else "t", k[2], k[3], fc[k]))


if __name__ == "__main__":
    main()
