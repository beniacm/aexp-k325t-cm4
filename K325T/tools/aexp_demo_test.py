#!/usr/bin/python3
"""aexp_demo_test.py -- run Amiga demo ADFs on the AExp core (K325T board) one after the other
and record what the HDMI output shows.

Each demo starts from a full M2M reset (reset held > 1.5 s): disk ejected, menu closed.
Needs: the AExp core running (JTAG or flash slot 1), the user's Kickstart 1.3 as /amiga/kick.rom,
the ADFs in /amiga on the module's card image, the harness's m65d on the module (M65_HOST), the
MS2130 HDMI capture dongle on this PC.  Per demo: reset the core (the whole M2M system: the disk
is ejected, Kickstart reloaded), mount disk 1 from the on-screen menu (Help, Space = file browser,
cursor to the file, Return, Help closes the menu), record SECONDS of video (H.264, 1280x720) and
extract frames every --every seconds; two-disk demos get disk 2 mounted at --swap seconds.
Output: <out>/<demo>.mp4, <demo>_tNNN.png, results.csv (frame md5s, colour counts: a frozen or
black picture shows as identical md5s / few colours).

    tools/aexp_demo_test.py [--host 192.168.1.215] [--out DIR] [--only sota,arte] [--secs 120]

The demo list (DEMOS below) holds the file names in /amiga and, for two-disk demos, the second
disk and when to insert it.  The browser lists /amiga sorted by name; the script reads the card's
directory over ssh to find the cursor position of each file.
"""
import argparse
import csv
import hashlib
import os
import socket
import subprocess
import sys
import time

# name: (disk 1, disk 2 or None, seconds after boot to insert disk 2, total seconds)
DEMOS = {
    "sota":   ("sota.adf", None, None, 150),       # Spaceballs, State of the Art (1992)
    "enigma": ("enigma.adf", None, None, 150),     # Phenomena, Enigma (1991)
    "arte":   ("arte.adf", None, None, 180),       # Sanity, Arte (1993)
    "eon":    ("eon1.adf", "eon2.adf", 100, 240),  # The Black Lotus, Eon (2019, party version)
    "batman": ("batman1.adf", "batman2.adf", 120, 240),  # Batman Group, Batman Rises (2022)
}


def ctl(host, line, timeout=10):
    with socket.create_connection((host, 4511), timeout=timeout) as s:
        s.sendall((line + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            d = s.recv(65536)
            if not d:
                break
            buf += d
    return buf.decode().strip()


def key(host, name, hold_ms=80, gap=0.25):
    r = ctl(host, "key %s %d" % (name, hold_ms))
    time.sleep(hold_ms / 1000.0 + gap)
    return r


def full_reset(host):
    """the whole M2M system (reset held > 1.5 s, M2M's long press): the disk is ejected, the menu
    closed, Kickstart reloaded from the card.  A short reset (m65ctl reset) resets only the Amiga
    and keeps the disk mounted, like a real A500."""
    global BROWSER_POS
    BROWSER_POS = 0
    ctl(host, "hold_reset 1")
    time.sleep(2.2)
    ctl(host, "hold_reset 0")
    time.sleep(15)                                   # QNICE reloads Kickstart, the Amiga boots


def browser_list(host):
    """the .adf files in /amiga as the core's browser sorts them (case-insensitive)"""
    out = subprocess.run(["ssh", "root@" + host,
                          "MTOOLS_SKIP_CHECK=1 mdir -b -i /root/m65/card.img@@1M ::/amiga"],
                         capture_output=True, text=True, timeout=30).stdout
    names = [os.path.basename(l.strip()) for l in out.splitlines() if l.strip()]
    return sorted((n for n in names if n.lower().endswith(".adf")), key=str.lower)


BROWSER_POS = 0   # where the file browser's cursor starts: <..> after a full reset, else the
                  # line of the file mounted last (the browser remembers it)


def mount(host, fname, listing, eject_first=False):
    """open the menu, (eject,) open the browser, select fname, mount, close the menu"""
    global BROWSER_POS
    key(host, "HELP", gap=1.0)
    if eject_first:
        key(host, "SPACE", gap=1.0)                  # mounted disk + Space = eject
    key(host, "SPACE", gap=1.5)                      # empty drive + Space = file browser
    idx = listing.index(fname) + 1                   # the browser's first line is <..>
    if idx < BROWSER_POS:                            # only DOWN is reliable (m65d "UP" = SHIFT+DOWN)
        raise SystemExit("cannot move the browser cursor up (%s)" % fname)
    for _ in range(idx - BROWSER_POS):
        key(host, "DOWN", hold_ms=60, gap=0.12)
    BROWSER_POS = idx
    key(host, "RETURN", gap=10.0)                    # mount: the core loads the 880 KB image
    for _ in range(3):                               # close the menu (and make sure it is closed)
        key(host, "HELP", gap=1.0)
        if not menu_open():
            break


LIVE = None       # PNG that the running recording refreshes twice a second (record())


def menu_open():
    """the on-screen menu (720p: top-right box, blue body with a cyan frame) is showing,
    judged from the live frame of the running recording"""
    time.sleep(1.2)
    try:
        from PIL import Image
        im = Image.open(LIVE).convert("RGB")
        r, g, b = im.getpixel((1268, 200))           # the menu's right frame (cyan)
        r2, g2, b2 = im.getpixel((1000, 100))        # inside the menu (blue)
        return b > 180 and g > 180 and b2 > 180 and r2 < 80 and g2 < 80
    except Exception:
        return False


def capture_device():
    for v in sorted(os.listdir("/dev")):
        if v.startswith("video"):
            p = "/dev/" + v
            info = subprocess.run(["v4l2-ctl", "-d", p, "--info"], capture_output=True, text=True).stdout
            if any(k in info for k in ("MS2130", "MacroSilicon", "USB3 Video", "Capture")):
                if "Video Capture" in info:
                    return p
    return "/dev/video0"


def record(dev, path, secs):
    """H.264 clip of the HDMI input; returns the Popen (runs in the background)"""
    return subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                             "-f", "v4l2", "-input_format", "yuyv422", "-video_size", "1280x720",
                             "-framerate", "50", "-i", dev,
                             "-map", "0", "-t", str(secs), "-c:v", "libx264", "-preset", "veryfast",
                             "-crf", "20", path,
                             "-map", "0", "-t", str(secs), "-vf", "fps=2", "-update", "1", LIVE])


def frames(clip, out_prefix, every, secs):
    rows = []
    for t in range(every, secs, every):
        png = "%s_t%03d.png" % (out_prefix, t)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(t),
                        "-i", clip, "-frames:v", "1", png], timeout=60)
        if not os.path.exists(png):
            continue
        md5 = hashlib.md5(open(png, "rb").read()).hexdigest()
        cols = subprocess.run(["identify", "-format", "%k", png], capture_output=True,
                              text=True).stdout.strip()
        rows.append((t, os.path.basename(png), md5, cols))
    return rows


def main():
    global LIVE
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("M65_HOST", "192.168.1.215"))
    ap.add_argument("--out", default=os.path.join(here, "..", "demo_runs",
                                                  time.strftime("%Y%m%d_%H%M%S")))
    ap.add_argument("--only", default="")
    ap.add_argument("--secs", type=int, default=0, help="override each demo's length")
    ap.add_argument("--every", type=int, default=10, help="seconds between saved frames")
    ap.add_argument("--swap", type=int, default=-1,
                    help="seconds after boot to insert disk 2 (overrides the table; 0 = never)")
    ap.add_argument("--reset-only", action="store_true", help="just the full reset (eject, menu closed)")
    ap.add_argument("--mount", default="", help="full reset, mount this ADF from /amiga, exit")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    LIVE = os.path.join(a.out, "live.png")
    core = ctl(a.host, "core")
    if "amiga" not in core:
        sys.exit("the Amiga core is not running (%s)" % core)
    if a.reset_only:
        full_reset(a.host)
        return
    if a.mount:                                      # full reset, mount one ADF, leave it running
        listing = browser_list(a.host)
        full_reset(a.host)
        rec = record(capture_device(), os.path.join(a.out, "mount.mp4"), 40)
        mount(a.host, a.mount, listing)
        rec.wait()
        print("mounted", a.mount, "menu", "open" if menu_open() else "closed")
        return
    listing = browser_list(a.host)
    print("browser order:", " ".join(listing))
    dev = capture_device()
    sel = [d for d in DEMOS if not a.only or d in a.only.split(",")]
    with open(os.path.join(a.out, "results.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["demo", "t", "frame", "md5", "colours"])
        for name in sel:
            d1, d2, swap, secs = DEMOS[name]
            secs = a.secs or secs
            if a.swap >= 0:
                d2, swap = (d2 if a.swap else None), a.swap
            if d1 not in listing:
                print("%s: %s not on the card, skipped" % (name, d1))
                continue
            print("== %s (%s%s), %d s" % (name, d1, ", " + d2 if d2 else "", secs), flush=True)
            full_reset(a.host)
            clip = os.path.join(a.out, name + ".mp4")
            rec = record(dev, clip, secs + 5)
            t0 = time.time()
            mount(a.host, d1, listing)
            if d2:
                time.sleep(max(0, swap - (time.time() - t0)))
                print("   disk 2 at %.0f s" % (time.time() - t0), flush=True)
                mount(a.host, d2, listing, eject_first=True)
            rec.wait()
            for row in frames(clip, os.path.join(a.out, name), a.every, secs):
                w.writerow((name,) + row)
                print("   t=%3d s %s colours=%s" % (row[0], row[2][:8], row[3]), flush=True)
            f.flush()
    print("results:", os.path.abspath(a.out))


if __name__ == "__main__":
    main()
