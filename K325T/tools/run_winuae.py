#!/usr/bin/python3
"""run_winuae.py -- one WinUAE 6.1 run without a display (second reference emulator for the A1200 line).

The Unix port of WinUAE 6.1.0 beta 10 (the AppImage the user provided, unpacked in
~/projects/mega65/ext/winuae/squashfs-root; nothing else is installed or updated) on Xvfb, with the
same LD_PRELOAD frame capture as FS-UAE (fsuae_capture.so: SDL3 + OpenGL presenter):

  run_winuae.py NAME OUTDIR --frames N [--floppy ADF ...] [--hd DIR [--hd-label NAME]] [--fast MB]
                [--video] [--ppm-every K] [--click N,N] [--set key=value ...]

A1200 model as accurate as WinUAE offers: AGA, chipset_compatible=A1200, 68020 with 24-bit
addressing (= 68EC020), cpu_compatible + cpu_cycle_exact + cpu_memory_cycle_exact (cycle-exact
CPU and memory), blitter_cycle_exact, cpu_speed=real, 2 MB chip, no slow RAM, no JIT; --fast MB
adds Zorro II fast RAM (the trapdoor card of a real A1200 has no WinUAE equivalent; Zorro II fast
RAM in the 24-bit window is the nearest).  Kickstart 3.1 A1200 ROM read in place
(~/Downloads/kick40068.A1200, the user's own file, never copied).  No sound output.  OUTDIR gets
NAME.uae (the configuration), NAME.log (stdout+stderr), NAME.mkv (--video: every 2nd frame),
NAME_<frame>.ppm every K frames.  HOME is a scratch directory below OUTDIR (WinUAE writes its
settings there).  One emulator at a time, nice 19.
"""
import argparse, os, shutil, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
KICK = os.path.expanduser("~/Downloads/kick40068.A1200")
CAP = os.path.expanduser("~/projects/mega65/ext/a1200_demos/tools/fsuae_capture.so")
WINUAE = os.path.expanduser("~/projects/mega65/ext/winuae/squashfs-root")

ACCURACY = [  # the accuracy options, recorded in every NAME.uae
    "chipset=aga", "chipset_compatible=A1200", "cpu_model=68020", "cpu_24bit_addressing=true",
    "cpu_compatible=true", "cpu_cycle_exact=true", "cpu_memory_cycle_exact=true",
    "blitter_cycle_exact=true", "cpu_speed=real", "cachesize=0", "chipmem_size=4",
    "bogomem_size=0", "collision_level=full", "immediate_blits=false", "waiting_blits=disabled",
    "ntsc=false",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name"); ap.add_argument("outdir")
    ap.add_argument("--frames", type=int, required=True)
    ap.add_argument("--floppy", nargs="*", default=[])
    ap.add_argument("--hd"); ap.add_argument("--hd-label", default="DH0")
    ap.add_argument("--fast", type=int, default=0, help="Zorro II fast RAM in MB (0, 1, 2, 4, 8)")
    ap.add_argument("--video", action="store_true")
    ap.add_argument("--ppm-every", type=int, default=0)
    ap.add_argument("--click", default="", help="swap numbers of scripted mouse clicks (R prefix: right button)")
    ap.add_argument("--set", nargs="*", default=[], help="more key=value configuration lines")
    ap.add_argument("--swap", default="", help="N:I,...: one drive; the floppies are WinUAE's disk swapper "
                    "list and at swap N image I (0..) goes into DF0 (End+digit hotkey, CAP_HOTKEY)")
    ap.add_argument("--hotkey", default="", help="raw CAP_HOTKEY (e.g. 3600:F6), replaces the one --swap makes")
    a = ap.parse_args()
    if not os.path.exists(CAP):
        subprocess.check_call(["gcc", "-O2", "-shared", "-fPIC", "-o", CAP,
                               os.path.join(HERE, "fsuae_capture.c"), "-ldl"])
    os.makedirs(a.outdir, exist_ok=True)
    home = os.path.join(os.path.abspath(a.outdir), ".home_" + a.name)
    os.makedirs(home, exist_ok=True)
    cfg = ["use_gui=no", "kickstart_rom_file=" + KICK] + ACCURACY + [
        "fastmem_size=%d" % a.fast, "sound_output=none", "floppy_speed=100",
        "nr_floppies=%d" % (1 if a.swap else max(1, min(4, len(a.floppy))))]
    for i, f in enumerate(a.floppy[:1] if a.swap else a.floppy[:4]):
        cfg.append("floppy%d=%s" % (i, os.path.abspath(f)))
        cfg.append("floppy%dtype=0" % i)
    if a.swap:
        for i, f in enumerate(a.floppy):
            cfg.append("diskimage%d=%s" % (i, os.path.abspath(f)))
        for i in range(1, 4):
            cfg.append("floppy%dtype=-1" % i)
    if a.hd:
        cfg.append("filesystem2=rw,DH0:%s:%s,0" % (a.hd_label, os.path.abspath(a.hd)))
    cfg += a.set
    cfn = os.path.join(os.path.abspath(a.outdir), a.name + ".uae")
    open(cfn, "w").write("\n".join(cfg) + "\n")
    env = dict(os.environ, HOME=home, LD_PRELOAD=CAP, CAP_FRAMES=str(a.frames))
    if a.video:
        env.update(CAP_VIDEO=os.path.join(os.path.abspath(a.outdir), a.name + ".mkv"), CAP_SKIP="2")
    if a.ppm_every:
        env.update(CAP_PPM=os.path.join(os.path.abspath(a.outdir), a.name), CAP_PPM_EVERY=str(a.ppm_every))
    if a.click:
        env.update(CAP_CLICK=a.click)
    if a.swap:
        env.update(CAP_HOTKEY=",".join("%s:%d" % (n, (int(i) + 1) % 10) for n, i in (x.split(":") for x in a.swap.split(","))))
    if a.hotkey:
        env.update(CAP_HOTKEY=a.hotkey)
    with open(os.path.join(a.outdir, a.name + ".log"), "w") as so:
        try:
            rc = subprocess.call(["nice", "-n", "19", "xvfb-run", "-a", "-s", "-screen 0 1280x1024x24",
                                  "./AppRun", "-f", cfn], cwd=WINUAE, env=env, stdout=so,
                                 stderr=subprocess.STDOUT, timeout=a.frames / 50 * 4 + 120)
        except subprocess.TimeoutExpired:
            rc = -1
    shutil.rmtree(home, ignore_errors=True)
    print("%s: rc %d" % (a.name, rc))


if __name__ == "__main__":
    main()
