#!/usr/bin/python3
"""frame_counter_clip.py CLIP.mp4 -- read the live frame counter (row 1 of mk_stalltest_adf.py's
screen) from every frame of a clip of the HDMI output (aexp_demo_test.py / ffmpeg at 50 fps) and
count how it advances from one captured frame to the next: +1 = every Amiga frame shown once;
0 = a frame shown twice (ascal repeated it, or the capture dongle duplicated one); +2 = a frame
skipped.  Also the mismatch row (4) of the first and the last frame.  (numpy: /usr/bin/python3.)
The capture dongle runs on its own crystal: at 50 fps it slips one frame every 1/(50 x ppm) s
against the board, so isolated 0 / +2 steps with a regular spacing come from the dongle.
"""
import collections
import subprocess
import sys

import numpy as np


def frames(clip, w=1280, h=720):
    p = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", clip, "-f", "rawvideo",
                          "-pix_fmt", "gray", "-"], stdout=subprocess.PIPE)
    n = w * h
    while True:
        b = p.stdout.read(n)
        if len(b) < n:
            break
        yield np.frombuffer(b, dtype=np.uint8).reshape(h, w)


def geometry(im):
    white = im > 128
    rows = np.where(white[:, ::4].sum(axis=1) > im.shape[1] // 64)[0]
    y0 = rows[0]
    xs = np.where(white[y0 + 2])[0]
    x0, x1 = xs[0], xs[-1] + 1
    y1 = y0                                  # the marker row's height: most of its span white
    while white[y1, x0:x1].mean() > 0.5:
        y1 += 1
    return y0, x0, (y1 - y0) / 6.0, (x1 - x0) / 32.0


def row(im, g, r):
    y0, x0, lh, cw = g
    y = int(y0 + (8 * r + 3) * lh)
    v = 0
    for b in range(32):
        v = (v << 1) | (1 if im[y, int(x0 + (b + 0.5) * cw)] > 128 else 0)
    return v


def main():
    clip = sys.argv[1]
    g = None
    counts, steps = [], collections.Counter()
    first = last = None
    for im in frames(clip):
        if g is None:
            try:
                g = geometry(im)
            except Exception:
                continue
        if row(im, g, 0) != 0xFFFFFFFF:          # the first frames can be scaled differently
            try:
                g = geometry(im)
            except Exception:
                pass
            if row(im, g, 0) != 0xFFFFFFFF:
                counts.append(None)
                continue
        c = row(im, g, 1)
        counts.append(c)
        mm = row(im, g, 4)
        if first is None:
            first = mm
        last = mm
    good = [c for c in counts if c is not None]
    odd = []
    for i in range(1, len(counts)):
        a, b = counts[i - 1], counts[i]
        if a is None or b is None:
            continue
        d = (b - a) & 0xFFFFFFFF
        steps[d if d < 8 else "big"] += 1
        if d != 1:
            odd.append((i, d))
    print("%s: %d frames, %d decoded; counter %s .. %s; steps %s; mismatch row first %s last %s" %
          (clip.rsplit("/", 1)[-1], len(counts), len(good), good[0] if good else "-",
           good[-1] if good else "-", dict(steps), first, last))
    if odd:
        print("  non-1 steps at captured frame (index, step): %s%s" %
              (odd[:40], " ..." if len(odd) > 40 else ""))


if __name__ == "__main__":
    main()
