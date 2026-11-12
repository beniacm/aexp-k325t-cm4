#!/usr/bin/python3
"""demo_sheets.py RUNDIR [--refs DIR] [--every 10] -- contact sheets of a board run of the A1200 demo set
(aexp_demo_test.py --set a1200: RUNDIR/<demo>_tNNN.png every --every seconds) next to the FS-UAE and
WinUAE reference stills (ext/a1200_demos/ref, ref_winuae: <demo>_<swap>.ppm/.png every 500 swaps =
10 s): one row per 10 s, columns board | FS-UAE | WinUAE.  Not a pixel comparison: the time origins
differ (board: from the first mount; emulators: from power-on, plus their own load times), so the
sheet is for looking at whether the same parts appear and look the same.  Own code.
Output: RUNDIR/<demo>_sheet3.png.
"""
import glob, os, re, sys
from PIL import Image, ImageDraw

A = sys.argv[1:]
run = A[0]
refs = os.path.expanduser("~/projects/mega65/ext/a1200_demos")
if "--refs" in A:
    refs = A[A.index("--refs") + 1]
every = int(A[A.index("--every") + 1]) if "--every" in A else 10
W, H = 320, 240


def ref_stills(d, demo):
    fs = glob.glob(os.path.join(refs, d, demo + "_[0-9]*.p[np][mg]"))
    out = {}
    for f in fs:
        m = re.search(r"_(\d+)\.p[np][mg]$", f)
        if m:
            out[int(m.group(1)) // 50] = f          # swaps -> seconds
    return out


demos = sorted({re.sub(r"_t\d+\.png$", "", os.path.basename(f)) for f in glob.glob(os.path.join(run, "*_t[0-9]*.png"))})
for demo in demos:
    board = {int(re.search(r"_t(\d+)\.png$", f).group(1)): f for f in glob.glob(os.path.join(run, demo + "_t[0-9]*.png"))}
    fs, wu = ref_stills("ref", demo), ref_stills("ref_winuae", demo)
    times = sorted(set(board) | set(fs) | set(wu))
    times = [t for t in times if t % every == 0]
    sheet = Image.new("RGB", (3 * W, H * len(times) + 20), (40, 40, 40))
    dr = ImageDraw.Draw(sheet)
    for i, name in enumerate(["board", "FS-UAE 3.1.66", "WinUAE 6.1b10"]):
        dr.text((i * W + 4, 4), name, fill=(255, 255, 0))
    for r, t in enumerate(times):
        for c, src in enumerate([board, fs, wu]):
            if t in src:
                im = Image.open(src[t]).convert("RGB").resize((W, H))
                sheet.paste(im, (c * W, 20 + r * H))
            dr.text((c * W + 4, 20 + r * H + 4), "%d s" % t, fill=(255, 255, 0))
    out = os.path.join(run, demo + "_sheet3.png")
    sheet.save(out)
    print(out, len(times), "rows")
