#!/usr/bin/python3
"""aga_board_test.py -- the stage-3 AGA tests and the Kickstart 3.1 boot on the board (Radxa rig),
compared with the bench pictures block for block.  Own code; not run yet (no board in this work).

Needs: the AGA bitstream running (JTAG with M65_JTAG=<cable> or flash), Kickstart 3.1 (40.068, the
user's own ROM) as /amiga/kick.rom, the test ADFs of tools/mk_agatest.py (agaNAME.adf, e.g.
agapal256.adf) in /amiga on the card, "AGA Chipset" + "68020" chosen in the RAM submenu, m65d on the
module, the HDMI capture dongle (default /dev/video0, 1280x720 at 50 fps; it cannot be opened twice:
one capture at a time).  Per test: chip RAM through the cache with 2 MB (stallmon on the module), a
full reset, mount the ADF, record SECS seconds, drop the first second of the stream, take the last
frame, find the picture's scale from its own block grid and run mk_agatest's checker on it (the same
expected colours as on the bench).  The bench's PNG of the same test is put next to it.

    tools/aga_board_test.py [--host 192.168.1.215] [--out DIR] [--only pal256,ham8] [--secs 25]
                            [--bench DIR (the bench's run_agatests.sh output, for the side-by-side)]
    tools/aga_board_test.py --ks31 [--secs 40]   Kickstart 3.1 boot without a disk: the insert-disk
                            screen, compared with the bench's frame (--bench-ks31 PPM) cell by cell
Output: DIR/<test>.png (capture), DIR/<test>.check.json, DIR/<test>_side.png, results.txt.
"""
import argparse, json, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import aexp_demo_test as D      # ctl/key/full_reset/mount/browser_list (m65d + the OSM)
import mk_agatest as M

TESTS = ["pal256", "fmode1", "fmode2", "fmode3", "ddf3c", "hires8f3", "xor", "ham8", "spr16", "spr32", "spr64"]


def grab(dev, secs, png):
    """record secs seconds of the HDMI input, discard the first second, keep the last frame"""
    tmp = png + ".mkv"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "v4l2", "-use_wallclock_as_timestamps", "1", "-input_format",
                    "yuyv422", "-video_size", "1280x720", "-framerate", "50", "-i", dev, "-t", str(secs),
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "12", tmp], timeout=secs + 30)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "1", "-sseof", "-0.1",
                    "-i", tmp, "-frames:v", "1", png], timeout=60)
    return os.path.exists(png)


def grid_scale(png, test, testdir):
    """columns per lores pixel and rows per line from the picture itself: the block (1,0) and
    (2,0) left edges (16 lores pixels apart) and block rows 0 and 1 (16 lines apart)"""
    from PIL import Image
    exp = json.load(open(os.path.join(testdir, test + ".json")))
    if "blocks" not in exp:
        return None
    b = {tuple(map(int, k.split(","))): tuple(v) for k, v in exp["blocks"].items()}
    im = Image.open(png).convert("RGB"); px = im.load(); W, H = im.size

    def near(c, d):
        return all(abs(c[i] - d[i]) <= 24 for i in range(3))
    for y in range(H):
        row = [px[x, y] for x in range(W)]
        xs1 = [x for x in range(W) if near(row[x], b[(1, 0)])]
        xs2 = [x for x in range(W) if near(row[x], b[(2, 0)])]
        if len(xs1) > 8 and len(xs2) > 8:
            xscale = (xs2[0] - xs1[0]) / 16.0
            x = xs1[len(xs1) // 2]
            ys0 = [yy for yy in range(H) if near(px[x, yy], b[(1, 0)])]
            ys1 = [yy for yy in range(H) if near(px[x, yy], b[(1, 1)])]
            if ys0 and ys1:
                return xscale, (ys1[0] - ys0[0]) / 16.0
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("M65_HOST", "192.168.1.215"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "aga_runs", time.strftime("%Y%m%d_%H%M%S")))
    ap.add_argument("--only", default="")
    ap.add_argument("--secs", type=int, default=25)
    ap.add_argument("--dev", default="/dev/video0")
    ap.add_argument("--tests", default=os.path.expanduser("~/projects/mega65/ext/aga_groundwork/tests"),
                    help="mk_agatest.py build output (expected colours)")
    ap.add_argument("--bench", default="", help="bench pictures (run_agatests.sh output) for the side-by-side")
    ap.add_argument("--setup", default="python3 %s cache on 0 chip2m" % os.environ.get("STALLMON", "/root/m65/stallmon.py"))
    ap.add_argument("--ks31", action="store_true")
    ap.add_argument("--bench-ks31", default="")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if "amiga" not in D.ctl(a.host, "core"):
        sys.exit("the Amiga core is not running")
    res = open(os.path.join(a.out, "results.txt"), "w")
    if a.ks31:
        subprocess.run(["ssh", "root@" + a.host, a.setup], timeout=30)
        D.full_reset(a.host)
        png = os.path.join(a.out, "ks31.png")
        grab(a.dev, a.secs, png)
        if a.bench_ks31:
            print(compare_cells(png, a.bench_ks31), file=res)
        return
    listing = D.browser_list(a.host)
    for t in [t for t in TESTS if not a.only or t in a.only.split(",")]:
        adf = "aga%s.adf" % t
        if adf not in listing:
            print("%s: %s not on the card" % (t, adf), file=res); continue
        subprocess.run(["ssh", "root@" + a.host, a.setup], timeout=30)
        D.full_reset(a.host)
        D.LIVE = os.path.join(a.out, "live.png")
        D.mount(a.host, adf, listing)
        png = os.path.join(a.out, t + ".png")
        if not grab(a.dev, a.secs, png):
            print("%s: no capture" % t, file=res); continue
        sc = grid_scale(png, t, a.tests)
        if sc is None and t.startswith("spr"):
            sc = grid_scale(os.path.join(a.out, "pal256.png"), "pal256", a.tests) if os.path.exists(os.path.join(a.out, "pal256.png")) else None
        r = M.check(t, png, sc[0] if sc else 2, sc[1] if sc else 1, a.tests, settle=2) if sc else {"error": "no grid"}
        json.dump(r, open(os.path.join(a.out, t + ".check.json"), "w"), default=str)
        line = "%-9s scale %s ok %s bad %s origin %s %s" % (t, sc, r.get("ok"), r.get("bad"), r.get("origin"), r.get("error", ""))
        print(line); print(line, file=res); res.flush()
        if a.bench and os.path.exists(os.path.join(a.bench, t + ".png")):
            side(png, os.path.join(a.bench, t + ".png"), os.path.join(a.out, t + "_side.png"))


def side(board, bench, out):
    from PIL import Image
    a = Image.open(board).convert("RGB"); b = Image.open(bench).convert("RGB")
    b = b.resize((int(b.width * a.height / b.height), a.height))
    c = Image.new("RGB", (a.width + b.width, a.height)); c.paste(a, (0, 0)); c.paste(b, (a.width, 0)); c.save(out)


def compare_cells(board_png, bench_ppm, cells=(40, 32)):
    """both pictures reduced to a grid of cells (mean colour per cell over the non-black bounding box);
    reports the cells whose colours differ by more than 24 per channel"""
    from PIL import Image
    def norm(fn):
        im = Image.open(fn).convert("RGB")
        bb = im.point(lambda v: 255 if v > 16 else 0).getbbox() or (0, 0, im.width, im.height)
        return im.crop(bb).resize(cells, Image.BOX)
    a, b = norm(board_png), norm(bench_ppm)
    pa, pb = a.load(), b.load()
    bad = [(x, y) for y in range(cells[1]) for x in range(cells[0])
           if any(abs(pa[x, y][i] - pb[x, y][i]) > 24 for i in range(3))]
    return "cells %dx%d, differing %d" % (cells[0], cells[1], len(bad))


if __name__ == "__main__":
    main()
