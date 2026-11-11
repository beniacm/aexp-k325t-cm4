#!/bin/sh
# build.sh [RTL_DIR] -- Verilator build of the AGA + 68020 bench (stage-3 groundwork).
#
#   RTL_DIR   Minimig rtl directory to simulate (default: this tree's submodule with the
#             K325T patches applied, i.e. CORE/Minimig_MiSTerMEGA65/rtl after build.sh's patch
#             step).  Pass MiSTer's Minimig-AGA rtl to compare against MiSTer's chipset.
#   OUT       build directory (default: $SCRATCH/aga/build, outside the repository)
#   EXTRA     more Verilog files (MiSTer's rtl needs some of its new modules)
#
# The RTL is copied into OUT and three simulation-only fixes are applied to the copy (event-ordering
# races in Verilator, synthesis semantics unchanged, as in the A1200 DDR3 study): blocking
# assignments in separate clocked blocks of agnus_copper.v, paula_floppy_fifo.v and userio.v become
# non-blocking.  The TG68K (VHDL) is converted to Verilog with GHDL's synthesis
# (ghdl --synth --out=verilog, the generics of cpu_wrapper's instance fixed) and wrapped with the
# lower-case port names cpu_wrapper uses.  Verilator 5.054 (brew), nice 19, at most 4 jobs.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
RTL="${1:-$root/CORE/Minimig_MiSTerMEGA65/rtl}"
TG="${TG:-$root/CORE/Minimig_MiSTerMEGA65/rtl/tg68k}"
FX="${FX:-$root/CORE/Minimig_MiSTerMEGA65/rtl/fx68k}"
: "${SCRATCH:=/tmp/claude-1000/-home-me-projects-mega65/ae20aebe-73df-4a68-8048-a9d4df735cf0/scratchpad}"
OUT="${OUT:-$SCRATCH/aga/build}"
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
    "$TG/TG68K_Pack.vhd" "$TG/TG68K_ALU.vhd" "$TG/TG68KdotC_Kernel.vhd" -e TG68KdotC_Kernel \
    > tg68k_raw.v 2> ghdl.log) || { cat "$OUT/ghdl.log" >&2; exit 1; }
sed 's/^module TG68KdotC_Kernel$/module tg68k_ghdl/' "$OUT/tg68k_raw.v" > "$OUT/tg68k.v"
SRCS="$R/minimig.v $R/agnus*.v $R/denise*.v $R/paula*.v $R/cia*.v $R/gary.v $R/userio.v \
 $R/minimig_bankmapper.v $R/minimig_sram_bridge.v $R/minimig_m68k_bridge.v $R/minimig_syscontrol.v \
 $R/cart.v $R/gayle.v $R/ide.v $R/amiga_clk.v $R/cpu_wrapper.v $R/fx68k/fx68k.sv $R/fx68k/fx68kAlu.sv \
 $R/fx68k/uaddrPla.sv $OUT/tg68k.v $here/tg68k_wrap.v ${EXTRA:-}"
cd "$OUT"
nice -n 19 $V --savable --cc --exe --build -j 4 -O3 --top-module tb_top -Wno-fatal -Wno-lint -Wno-style \
  -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-COMBDLY -Wno-INITIALDLY \
  -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-IMPLICIT -Wno-SELRANGE -Wno-LATCH -Wno-BLKANDNBLK \
  --no-timing --no-assert-case --x-assign 0 --x-initial 0 -I$R -I$R/fx68k \
  -CFLAGS "-O2" "$here/tb_top.sv" $SRCS "$here/stubs.v" "$here/main.cpp" -o tb > verilator.log 2>&1 \
  || { grep -E "%Error" verilator.log | head -30 >&2; exit 1; }
# fx68k loads its microcode with a relative path (../../Minimig_MiSTerMEGA65/...): run from $OUT/run/a
mkdir -p "$OUT/run/a" "$OUT/Minimig_MiSTerMEGA65/rtl/fx68k"
cp "$R"/fx68k/*.mem "$OUT/Minimig_MiSTerMEGA65/rtl/fx68k/"
ls -la "$OUT/obj_dir/tb"
