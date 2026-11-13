#!/bin/sh
# build.sh [RTL_DIR] -- Verilator build of the AGA + 68020 bench (stage-3 groundwork).
#
#   RTL_DIR   Minimig rtl directory to simulate (default: this tree's submodule with the
#             K325T patches applied, i.e. CORE/Minimig_MiSTerMEGA65/rtl after build.sh's patch
#             step).  Pass MiSTer's Minimig-AGA rtl to compare against MiSTer's chipset.
#   OUT       build directory (default: ext/aga_groundwork/build, outside the repository)
#   EXTRA     more Verilog files (MiSTer's rtl needs some of its new modules)
#
# The RTL is copied into OUT and three simulation-only fixes are applied to the copy (event-ordering
# races in Verilator, synthesis semantics unchanged, as in the A1200 DDR3 study): blocking
# assignments in separate clocked blocks of agnus_copper.v, paula_floppy_fifo.v and userio.v become
# non-blocking.  The TG68K (VHDL) is converted to Verilog with GHDL's synthesis
# (ghdl --synth --out=verilog, the generics of cpu_wrapper's instance fixed), its ports renamed to the
# lower-case names cpu_wrapper uses.  Verilator 5.054 (brew), nice 19, at most 4 jobs.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
RTL="${1:-$root/CORE/Minimig_MiSTerMEGA65/rtl}"
TG="${TG:-$root/CORE/Minimig_MiSTerMEGA65/rtl/tg68k}"
FX="${FX:-$root/CORE/Minimig_MiSTerMEGA65/rtl/fx68k}"
: "${SCRATCH:=$HOME/projects/mega65/ext/aga_groundwork}"
OUT="${OUT:-$SCRATCH/build}"
V=/home/linuxbrew/.linuxbrew/bin/verilator
mkdir -p "$OUT/rtl/fx68k"
cp "$RTL"/*.v "$RTL"/*.vh "$OUT/rtl/" 2>/dev/null || true
cp "$FX"/*.sv "$FX"/*.mem "$OUT/rtl/fx68k/"
R="$OUT/rtl"
# CPUW=FILE: another cpu_wrapper.v (e.g. this tree's, when RTL_DIR is MiSTer's newer rtl whose
# cpu_wrapper needs MiSTer's newer TG68K and Minimig.sv glue)
[ -z "${CPUW:-}" ] || cp "$CPUW" "$R/cpu_wrapper.v"
# simulation-only fixes (see header)
sed -i -E 's/^(\s*)(copjmp1|copjmp2|strobe1|strobe2) = ([01]);/\1\2 <= \3;/; s/^(\s*)strobe = copjmp1 \| copjmp2;/\1strobe <= copjmp1 | copjmp2;/' "$R/agnus_copper.v"
sed -i -E 's/^(\s*)out=mem\[out_ptr\[10:0\]\];/\1out<=mem[out_ptr[10:0]];/' "$R/paula_floppy_fifo.v"
sed -i -E 's/joy1enable = ([01]);/joy1enable <= \1;/' "$R/userio.v"
n=$(grep -cE '(copjmp1|copjmp2|strobe1|strobe2|strobe) <= ' "$R/agnus_copper.v"); [ "$n" -ge 9 ] || { echo "copper fix: $n" >&2; exit 1; }
grep -q 'out<=mem\[out_ptr' "$R/paula_floppy_fifo.v" || { echo "fifo fix" >&2; exit 1; }
[ "$(grep -c 'joy1enable <= ' "$R/userio.v")" -ge 2 ] || { echo "userio fix" >&2; exit 1; }
# TG68K -> Verilog (generics as cpu_wrapper's instance)
(cd "$OUT" && nice -n 19 ghdl --synth --latches --std=08 -fsynopsys -gsr_read=2 -gvbr_stackframe=2 \
    -gextaddr_mode=2 -gmul_mode=2 -gdiv_mode=2 -gbitfield=2 --out=verilog \
    "$TG/TG68K_Pack.vhd" "$TG/TG68K_ALU.vhd" "$root/K325T/cpu020/TG68K_MMU030.vhd" "$TG/TG68KdotC_Kernel.vhd" -e TG68KdotC_Kernel \
    > tg68k_raw.v 2> ghdl.log) || { cat "$OUT/ghdl.log" >&2; exit 1; }
# VHDL names are case-insensitive: the kernel's ports as cpu_wrapper names them (lower case), and
# its generics as parameters (the method of MiSTer's rtl/sim/system/build.sh)
/usr/bin/python3 - "$OUT/tg68k_raw.v" "$OUT/tg68k.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
i = s.index('module TG68KdotC_Kernel'); j = s.index('endmodule', i)
m = s[i:j]; hdr = m[:m.index(');')]
for name in set(re.findall(r'(?:input|output|inout)\s+(?:\[[^\]]*\]\s*)?(\w+)', hdr)):
    if name != name.lower():
        m = re.sub(r'\b' + name + r'\b', name.lower(), m)
m = m.replace('module TG68KdotC_Kernel', 'module TG68KdotC_Kernel\n  #(parameter sr_read = 2, vbr_stackframe = 2, extaddr_mode = 2, mul_mode = 2, div_mode = 2, bitfield = 2)', 1)
open(sys.argv[2], 'w').write(s[:i] + m + s[j:])
PY
# stage 3: the stage-2 chip_cache (with the AGA 64-bit read) -> Verilog, for --cache
(cd "$OUT" && nice -n 19 ghdl --synth --latches --std=08 --out=verilog "$root/M2M/vhdl/tdp_ram.vhd" \
    "$root/K325T/chip_cache.vhd" -e chip_cache > chip_cache.v 2> ghdl_cache.log) || { cat "$OUT/ghdl_cache.log" >&2; exit 1; }
# VHDL names that are SystemVerilog keywords (stage 2b: chip_cache's signal "tagged")
sed -i -E 's/\btagged\b/tagged_v/g' "$OUT/chip_cache.v"
# the core's floppy service (adf_track_engine) -> Verilog, df0 for --adf
(cd "$OUT" && nice -n 19 ghdl --synth --latches --std=08 --out=verilog "$root/CORE/vhdl/adf_track_engine.vhd" \
    "$here/adf_engine_tb.vhd" -e adf_engine_tb > adf_engine.v 2> ghdl_adf.log) || { cat "$OUT/ghdl_adf.log" >&2; exit 1; }
# a1200-ide: the hard disk SPI slave + engine -> Verilog
(cd "$OUT" && nice -n 19 ghdl --synth --latches --std=08 -frelaxed --out=verilog "$root/K325T/hdd_spi.vhd" \
    -e hdd_spi > hdd_spi.v 2> ghdl_hdd.log) || { cat "$OUT/ghdl_hdd.log" >&2; exit 1; }
# FAST_A500=1: the 68020 (TG68K) and the chip cache replaced by stubs -- for A500 runs (fx68k, ideal
# memory) only; --cpu 3 and --cache do not work in such a build
if [ -n "${FAST_A500:-}" ]; then
  /usr/bin/python3 "$here/stubgen.py" "$OUT/tg68k.v" TG68KdotC_Kernel "$OUT/tg68k_stub.v"
  /usr/bin/python3 "$here/stubgen.py" "$OUT/chip_cache.v" chip_cache "$OUT/chip_cache_stub.v"
  mv "$OUT/tg68k_stub.v" "$OUT/tg68k.v"; mv "$OUT/chip_cache_stub.v" "$OUT/chip_cache.v"
fi
SRCS="$R/minimig.v $R/agnus*.v $R/denise*.v $R/paula*.v $R/cia*.v $R/gary.v $R/userio.v \
 $R/minimig_bankmapper.v $R/minimig_sram_bridge.v $R/minimig_m68k_bridge.v $R/minimig_syscontrol.v \
 $R/cart.v $R/gayle.v $R/ide.v $R/amiga_clk.v $R/cpu_wrapper.v $R/fx68k/fx68k.sv $R/fx68k/fx68kAlu.sv \
 $R/fx68k/uaddrPla.sv $OUT/tg68k.v $OUT/chip_cache.v $OUT/adf_engine.v $OUT/hdd_spi.v $root/K325T/cpu020/cpu_cycles.v ${EXTRA:-}"
cd "$OUT"
nice -n 19 $V --savable --cc --exe --build -j ${JOBS:-4} -O3 --top-module tb_top -Wno-fatal -Wno-lint -Wno-style \
  -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-COMBDLY -Wno-INITIALDLY \
  -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-IMPLICIT -Wno-SELRANGE -Wno-LATCH -Wno-BLKANDNBLK \
  --no-timing --no-assert-case --x-assign 0 --x-initial 0 -I$R -I$R/fx68k \
  -CFLAGS "-O2 -I$root/K325T/hddsrv" -LDFLAGS "-lpthread" "$here/tb_top.sv" $SRCS "$here/stubs.v" \
  "$here/main.cpp" "$root/K325T/hddsrv/hddsrv_core.c" -o tb > verilator.log 2>&1 \
  || { grep -E "%Error" verilator.log | head -30 >&2; exit 1; }
# fx68k loads its microcode with a relative path (../../Minimig_MiSTerMEGA65/...): run from $OUT/run/a
mkdir -p "$OUT/run/a" "$OUT/Minimig_MiSTerMEGA65/rtl/fx68k"
cp "$R"/fx68k/*.mem "$OUT/Minimig_MiSTerMEGA65/rtl/fx68k/"
# the 68EC020 cycle tables (cpu_cycles.v: ../../../K325T/cpu020/*.mem from the run directory)
mkdir -p "$OUT/../K325T/cpu020" && cp "$root"/K325T/cpu020/*.mem "$OUT/../K325T/cpu020/"
ls -la "$OUT/obj_dir/tb"
