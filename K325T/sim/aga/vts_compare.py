#!/usr/bin/env python3
"""vts_compare.py -- compare a bench picture with a vAmigaTS reference screenshot (own code).

  vts_compare.py OURS.ppm REF.tiff [--png OUT.png] [--json] [--offset DX,DY]

The bench samples one pixel per 14 MHz tick (hires pixels, rows from Denise's syncs, 960 x 320);
vAmiga's regression screenshots are hires pixels too (716 x 285, a crop of the visible area), with
4-bit colour channels scaled by 16 (ours by 17).  Both are reduced to 12-bit colour, the crop
position is searched (the offset with the most equal pixels), then the mismatching pixels are
counted.  --offset fixes the crop position instead (the bench's picture geometry is the same for
every test: 144,22 for vAmiga's 716 x 285 screenshots, found where a test matched exactly).  --png writes ours (cropped) | reference | difference (white = mismatch) side by side.
vAmiga's screenshots were taken with different palette settings over the years (4-bit F as 240 in
older ones, 236 with other levels in newer ones), so a second count ignores absolute colours: every
reference colour is mapped to the bench colour most often found under it, and pixels that do not
follow that mapping (or a mapping that joins two reference colours) count as mismatches
("mismatch_mapped").  The reference images are data from the vAmigaTS repository (GPL-3.0, read-only copy outside this
tree); they are made by vAmiga after its author matched them against photos of real machines.
"""
import json, sys
import numpy as np
from PIL import Image


def q12(a, scale):
    return ((a.astype(np.int32) + scale // 2) // scale).clip(0, 15)


def main():
    a = sys.argv[1:]
    png = None
    if "--png" in a:
        i = a.index("--png"); png = a[i + 1]; del a[i:i + 2]
    fixed = None
    if "--offset" in a:
        i = a.index("--offset"); fixed = tuple(int(x) for x in a[i + 1].split(",")); del a[i:i + 2]
    js = "--json" in a
    a = [x for x in a if x != "--json"]
    ours = np.asarray(Image.open(a[0]).convert("RGB"))
    ref = np.asarray(Image.open(a[1]).convert("RGB"))
    o = q12(ours, 17); r = q12(ref, 16)
    o1 = (o[..., 0] << 8) | (o[..., 1] << 4) | o[..., 2]
    r1 = (r[..., 0] << 8) | (r[..., 1] << 4) | r[..., 2]
    H, W = r1.shape
    oh, ow = o1.shape
    best = (-1, 0, 0)
    # coarse search on every 4th row/column, then exact around the best coarse offsets
    sub = r1[::4, ::4]
    cands = []
    for dy in (range(0) if fixed else range(0, oh - H + 1)):
        for dx in range(0, ow - W + 1):
            n = int(np.count_nonzero(o1[dy:dy + H:4, dx:dx + W:4] == sub))
            cands.append((n, dy, dx))
    cands.sort(reverse=True)
    if fixed:
        cands = [(0, fixed[1], fixed[0])]
    for _, dy, dx in cands[:8]:
        n = int(np.count_nonzero(o1[dy:dy + H, dx:dx + W] == r1))
        if n > best[0]:
            best = (n, dy, dx)
    n, dy, dx = best
    crop = o1[dy:dy + H, dx:dx + W]
    bad = crop != r1
    rows = np.nonzero(bad.any(axis=1))[0]
    # palette-independent count
    mapped_bad = 0
    used = {}
    for rc in np.unique(r1):
        m = r1 == rc
        vals, cnt = np.unique(crop[m], return_counts=True)
        best_c = vals[np.argmax(cnt)]
        mapped_bad += int(m.sum() - cnt.max())
        if best_c in used:            # two reference colours on one bench colour: count the smaller
            mapped_bad += int(min(cnt.max(), used[best_c]))
        used[best_c] = int(cnt.max())
    res = {"ours": a[0], "ref": a[1], "offset": [dx, dy], "pixels": int(H * W),
           "mismatch": int(bad.sum()), "mismatch_pct": round(100.0 * bad.sum() / (H * W), 3),
           "mismatch_mapped": mapped_bad,
           "bad_rows": [int(rows[0]), int(rows[-1])] if len(rows) else None,
           "colours_ours": int(len(np.unique(crop))), "colours_ref": int(len(np.unique(r1)))}
    if png:
        def rgb(x):
            return np.stack([((x >> 8) & 15) * 17, ((x >> 4) & 15) * 17, (x & 15) * 17], -1).astype(np.uint8)
        d = np.where(bad[..., None], 255, 0).astype(np.uint8).repeat(3, -1)
        Image.fromarray(np.concatenate([rgb(crop), rgb(r1), d], 1)).save(png)
    if js:
        print(json.dumps(res))
    else:
        print("%s: offset %s, %d of %d pixels differ (%.3f %%), rows %s" % (
            a[0].rsplit("/", 1)[-1], res["offset"], res["mismatch"], res["pixels"], res["mismatch_pct"], res["bad_rows"]))


if __name__ == "__main__":
    main()
