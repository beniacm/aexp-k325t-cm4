#!/usr/bin/python3
"""mif2hex.py IN.mif OUT.hex -- Altera MIF (ranges [a..b] : v;  a : v;) to a $readmemh file (one word
per address).  MiSTer's cpu_cycles.v initialises its 68EC020 cycle tables with the Quartus-only
ram_init_file attribute; Verilator ignores it (the tables read 0), so the simulation copy loads them
with $readmemh instead."""
import re, sys
depth = None; mem = {}
body = False
for l in open(sys.argv[1]):
    l = l.split("--")[0].strip()
    m = re.match(r"DEPTH\s*=\s*(\d+)", l)
    if m: depth = int(m.group(1))
    if l.startswith("BEGIN"): body = True; continue
    if not body or not l or l.startswith("END"): continue
    m = re.match(r"\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]\s*:\s*([0-9A-Fa-f]+);", l) or \
        re.match(r"([0-9A-Fa-f]+)()\s*:\s*([0-9A-Fa-f]+);", l)
    a = int(m.group(1), 16); b = int(m.group(2), 16) if m.group(2) else a
    for i in range(a, b + 1): mem[i] = int(m.group(3), 16)
open(sys.argv[2], "w").write("\n".join("%x" % mem.get(i, 0) for i in range(depth)) + "\n")
print("%s: %d words, %d set" % (sys.argv[2], depth, len(mem)))
