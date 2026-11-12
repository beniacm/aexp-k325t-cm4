#!/usr/bin/python3
"""aexp_demo_test.py -- run Amiga demo ADFs on the AExp core (K325T board) one after the other
and record what the HDMI output shows.

Each demo starts from a full M2M reset (reset held > 1.5 s): disk ejected, menu closed.
Needs: the AExp core running (JTAG or flash slot 1), the user's Kickstart 1.3 as /amiga/kick.rom,
the ADFs in /amiga on the module's card image, the harness's m65d on the module (M65_HOST), the
MS2130 HDMI capture dongle on this PC.  Per demo: reset the core (the whole M2M system: the disk
is ejected, Kickstart reloaded), mount disk 1 from the on-screen menu (Help, Space = file browser,
cursor to the file, Return, Help closes the menu), record SECONDS of video (H.264, 1280x720) and
extract frames every --every seconds; multi-disk demos get disk N mounted at the N-1th swap time
(seconds after the first mount; df0 swapping through the menu, the drive is ejected first).
Output: <out>/<demo>.mp4, <demo>_tNNN.png, results.csv (frame md5s, colour counts: a frozen or
black picture shows as identical md5s / few colours).

    tools/aexp_demo_test.py [--host 192.168.1.215] [--out DIR] [--only sota,arte] [--secs 120]
    tools/aexp_demo_test.py --set a1200 [--only nexus7,origin] [--swaps 120,240]

--set a1200: the A1200 demo set (stage 3).  Needs the AGA bitstream, Kickstart 3.1 (40.068, the
user's own A1200 ROM) as /amiga/kick.rom on the card instead of 1.3, "AGA Chipset" and "68020"
chosen in the RAM submenu (saved in the core's settings file), and chip RAM through the cache with
2 MB before every full reset (--setup, run over ssh on the module; default
"python3 $STALLMON cache on 0 chip2m", STALLMON = path of K325T/tools/stallmon.py on the module,
default /root/m65/stallmon.py).  File-based releases need a bootable ADF made with
tools/mk_bootadf.py (Mindflow, Domination, the Nexus 7 executable); DMS images need converting
to ADF first.  Swap times of the A1200 set are first guesses (the FS-UAE baselines ran with all
disks in df0-df3): check them against the first recording and pass --swaps.

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

# name: ([disk 1, disk 2, ...], [seconds after the first mount to insert disk 2, disk 3, ...],
#        total seconds)
DEMOS = {
    "sota":   (["sota.adf"], [], 150),             # Spaceballs, State of the Art (1992; the amigascne
                                                   # image: the scene.org party-archive DMS hangs)
    "enigma": (["enigma.adf"], [], 150),           # Phenomena, Enigma (1991)
    "arte":   (["arte.adf"], [], 180),             # Sanity, Arte (1993)
    "eon":    (["eon1.adf", "eon2.adf"], [170], 330),  # The Black Lotus, Eon (2019, party version); disk-2 icon ~165 s
    "batman": (["batman1.adf", "batman2.adf"], [290], 450),  # Batman Group, Batman Rises (2022); "INSERT DISK 2" ~270 s (waits)
}

# the A1200 set (ext/a1200_demos/manifest.md); card names in /amiga, ADFs only (DMS converted,
# executables on mk_bootadf.py disks).  The browser cursor only moves down: later disks of a demo
# must sort after the earlier ones (they do with these names).
DEMOS_A1200 = {
    "nexus7":   (["n7.adf"], [], 180),                         # Andromeda, Nexus 7 (1994), the trackloader ADF
    "fullmoon": (["fullmoon.adf"], [], 180),                   # Virtual Dreams & Fairlight (1993); loads ~50 s
    "origin":   (["origin1.adf", "origin2.adf"], [120], 300),  # Complex (1993), 2 DMS
    "motion":   (["motion1.adf", "motion2.adf"], [120], 300),  # Bomb (1994), 2 DMS, wants fast RAM
    "mindflow": (["mindflow.adf"], [], 150),                   # Stellar (1994), mk_bootadf disk (setchiprev)
    "roots":    (["roots.adf"], [], 180),                      # Sanity (1994), DMS
    "roots2":   (["roots2.adf"], [], 240),                     # Sanity (1995), DMS, ECS part wants fast RAM
    "twisted":  (["twisted1.adf", "twisted2.adf", "twisted3.adf", "twisted4.adf"], [90, 180, 270], 360),
    "domination": (["domination.adf"], [], 180),               # Contraz (1996), mk_bootadf disk, 4 MB fast
    "csc":      (["csc.adf"], [], 150),                        # Essence, Crazy Sexy Cool (1995): waits for a
                                                               # mouse click after its system check
    "artparadise": (["artpar1.adf", "artpar2.adf"], [120], 300),  # New Generation Crew (1994)
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
    ap.add_argument("--swaps", default="", help="comma list: seconds to insert disk 2, 3, ... (overrides)")
    ap.add_argument("--set", default="a500", choices=["a500", "a1200"], help="demo set / machine")
    ap.add_argument("--setup", default=None,
                    help="command run on the module (ssh) before every full reset; a1200 default: "
                         "chip RAM through the cache, 2 MB (AGA itself is the menu's chipset radio)")
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
    table = DEMOS_A1200 if a.set == "a1200" else DEMOS
    setup = a.setup
    if setup is None and a.set == "a1200":
        setup = "python3 %s cache on 0 chip2m" % os.environ.get("STALLMON", "/root/m65/stallmon.py")
    sel = [d for d in table if not a.only or d in a.only.split(",")]
    with open(os.path.join(a.out, "results.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["demo", "t", "frame", "md5", "colours"])
        for name in sel:
            disks, swaps, secs = table[name]
            disks, swaps = list(disks), list(swaps)
            secs = a.secs or secs
            if a.swaps:
                swaps = [int(x) for x in a.swaps.split(",")]
            elif a.swap >= 0:
                swaps = [a.swap] if a.swap else []
            disks = disks[:len(swaps) + 1]
            missing = [d for d in disks if d not in listing]
            if missing:
                print("%s: %s not on the card, skipped" % (name, " ".join(missing)))
                continue
            print("== %s (%s), %d s" % (name, ", ".join(disks), secs), flush=True)
            if setup:
                subprocess.run(["ssh", "root@" + a.host, setup], timeout=30)
            full_reset(a.host)
            clip = os.path.join(a.out, name + ".mp4")
            rec = record(dev, clip, secs + 5)
            t0 = time.time()
            mount(a.host, disks[0], listing)
            for n, (dn, at) in enumerate(zip(disks[1:], swaps), 2):
                time.sleep(max(0, at - (time.time() - t0)))
                print("   disk %d at %.0f s" % (n, time.time() - t0), flush=True)
                mount(a.host, dn, listing, eject_first=True)
            rec.wait()
            for row in frames(clip, os.path.join(a.out, name), a.every, secs):
                w.writerow((name,) + row)
                print("   t=%3d s %s colours=%s" % (row[0], row[2][:8], row[3]), flush=True)
            f.flush()
    print("results:", os.path.abspath(a.out))


if __name__ == "__main__":
    main()
