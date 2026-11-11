#!/usr/bin/python3
"""cache_grid.py TRACEDIR OUT.jsonl -- the A1200 DDR3 study's cache model (cachesim.cpp, compiled into
the scratch area from ext/aexp3_a1200_ddr3_study/model) over the AGA + 68020 traces of this bench:

  ks31boot   Kickstart 3.1 (40.068) cold boot to the insert-disk screen, AGA, TG68K 68020, frames 1-400
  ks31idle   the same run, frames 300-400 (OS idle at the insert-disk screen)
  aga8cpu    the study's workload program: 8 planes hires FMODE 3, copper, 4 audio, CPU memcpy over 1 MB
             -- now with the TG68K 68020 instead of the fx68k
  worst      the study's worst case: + 8 sprites + random blits + CPU random R/W over 2 MB, TG68K
  cputime    tools/mk_cputime.py: CPU loops on chip RAM under 8-plane FMODE 0/3 DMA and blitter nasty

Grid: cache 512/1024/1536 KB x prefetch none/dma/all x latency A/B/C (study section 3.3) at
h = 1/31, plus h = 0.1 for 1536 KB.  At most 2 model runs at a time, nice 19.
"""
import json, os, subprocess, sys, itertools
from concurrent.futures import ThreadPoolExecutor

TR = sys.argv[1]
OUT = sys.argv[2]
SRC = os.path.expanduser("~/projects/mega65/ext/aexp3_a1200_ddr3_study/model/cachesim.cpp")
SIM = os.path.join(os.path.dirname(OUT), "cachesim")
if not os.path.exists(SIM):
    subprocess.check_call(["g++", "-O2", "-std=c++17", "-o", SIM, SRC])

WL = {
    "ks31boot": ("ks31_boot020.bin", 0),
    "ks31idle": ("ks31_boot020.bin", 300),
    "aga8cpu": ("aga8cpu_020.bin", 25),
    "worst": ("worst_020.bin", 25),
    "cputime": ("cputime_020.bin", 5),
}
LAT = {"A": ["--lat", "250", "--jit", "50"],
       "B": ["--lat", "650", "--jit", "100"],
       "C": ["--lat", "650", "--jit", "200", "--pasc", "0.45", "--asc", "700"]}


def run(job):
    wl, cache, pf, lat, h = job
    tr, skip = WL[wl]
    a = ["nice", "-n", "19", SIM, "--trace", os.path.join(TR, tr), "--skip", str(skip),
         "--cache", str(cache), "--pf", pf, "--h", str(h)] + LAT[lat]
    o = subprocess.run(a, capture_output=True, text=True)
    if o.returncode:
        return {"wl": wl, "error": o.stderr[-300:]}
    r = json.loads(o.stdout)
    r.update(wl=wl, pf_set=pf, lat_set=lat)
    return r


jobs = []
for wl in WL:
    if not os.path.exists(os.path.join(TR, WL[wl][0])):
        continue
    for cache, pf, lat in itertools.product([512, 1024, 1536], ["none", "dma", "all"], "ABC"):
        jobs.append((wl, cache, pf, lat, 1 / 31))
    for pf, lat in itertools.product(["none", "all"], "BC"):
        jobs.append((wl, 1536, pf, lat, 0.1))
with ThreadPoolExecutor(2) as ex, open(OUT, "w") as f:
    for r in ex.map(run, jobs):
        f.write(json.dumps(r) + "\n")
        f.flush()
print("%d runs -> %s" % (len(jobs), OUT))
