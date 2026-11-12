#!/usr/bin/python3
"""run_fsuae.py -- one FS-UAE run without a display (reference recordings for the A1200 line).

FS-UAE (distribution package, 3.1.66) with SDL_VIDEODRIVER=offscreen and fsuae_capture.so
(LD_PRELOAD, built from fsuae_capture.c) reading back every frame:

  run_fsuae.py NAME OUTDIR --frames N [--floppy ADF ...] [--hd DIR_OR_HDF [--hd-label NAME]]
               [--video] [--ppm-every K] [--window WxH] [--click [R]N,...] [--opt key=value ...]

A1200 quickstart model (68EC020 14 MHz cycle-exact, AGA, 2 MB chip, as FS-UAE's "A1200"),
the user's Kickstart 3.1 A1200 ROM read in place (~/Downloads/kick40068.A1200), window
1440x1152 with nearest-neighbour scaling (3.828125 px per lores pixel, zoom = full), no sound
output.  Results in OUTDIR: NAME.mkv (with --video, 25 fps = every 2nd frame), NAME_<frame>.ppm
every K frames (--click: scripted mouse button presses at those swaps, R = right button),
NAME.fs-uae (config), NAME.log (FS-UAE's log).  One emulator at a time, nice 19.
"""
import argparse, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KICK = os.path.expanduser("~/Downloads/kick40068.A1200")
CAP = os.path.expanduser("~/projects/mega65/ext/a1200_demos/tools/fsuae_capture.so")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("outdir")
    ap.add_argument("--frames", type=int, required=True)
    ap.add_argument("--floppy", nargs="*", default=[])
    ap.add_argument("--hd")
    ap.add_argument("--video", action="store_true")
    ap.add_argument("--ppm-every", type=int, default=0)
    ap.add_argument("--opt", nargs="*", default=[])
    ap.add_argument("--window", default="1440x1152")
    ap.add_argument("--hd-label")
    ap.add_argument("--click", default="")
    a = ap.parse_args()
    if not os.path.exists(CAP):
        subprocess.check_call(["gcc", "-O2", "-shared", "-fPIC", "-o", CAP,
                               os.path.join(HERE, "fsuae_capture.c"), "-ldl"])
    os.makedirs(a.outdir, exist_ok=True)
    base = tempfile.mkdtemp(prefix="fsuae_", dir=os.environ.get("FSUAE_TMP"))
    cfg = ["[config]", "amiga_model = A1200", "kickstart_file = " + KICK, "base_dir = " + base,
           "texture_filter = nearest", "window_width = " + a.window.split("x")[0],
           "window_height = " + a.window.split("x")[1],
           "zoom = full", "keep_aspect = 0", "floppies_dir = " + base]
    for i, f in enumerate(a.floppy[:4]):
        cfg.append("floppy_drive_%d = %s" % (i, os.path.abspath(f)))
    for i, f in enumerate(a.floppy):
        cfg.append("floppy_image_%d = %s" % (i, os.path.abspath(f)))
    if a.hd:
        cfg.append("hard_drive_0 = " + os.path.abspath(a.hd))
        if a.hd_label:
            cfg.append("hard_drive_0_label = " + a.hd_label)
    cfg += a.opt
    cfn = os.path.join(a.outdir, a.name + ".fs-uae")
    open(cfn, "w").write("\n".join(cfg) + "\n")
    env = dict(os.environ, SDL_VIDEODRIVER="offscreen", LD_PRELOAD=CAP,
               CAP_FRAMES=str(a.frames))
    if a.video:
        env.update(CAP_VIDEO=os.path.join(a.outdir, a.name + ".mkv"), CAP_SKIP="2")
    if a.click:
        env.update(CAP_CLICK=a.click)
    if a.ppm_every:
        env.update(CAP_PPM=os.path.join(a.outdir, a.name), CAP_PPM_EVERY=str(a.ppm_every))
    with open(os.path.join(a.outdir, a.name + ".stdout"), "w") as so:
        rc = subprocess.call(["nice", "-n", "19", "fs-uae", cfn], env=env, stdout=so,
                             stderr=subprocess.STDOUT, timeout=a.frames / 50 * 4 + 120)
    log = os.path.join(base, "Cache", "Logs", "fs-uae.log.txt")
    if os.path.exists(log):
        shutil.copy(log, os.path.join(a.outdir, a.name + ".log"))
    shutil.rmtree(base, ignore_errors=True)
    print("%s: rc %d" % (a.name, rc))


if __name__ == "__main__":
    main()
