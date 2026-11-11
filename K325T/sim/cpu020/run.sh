#!/usr/bin/env bash
# run.sh [OUTDIR] -- tb_cpu020 with Vivado xsim: cpu_wrapper.v with the fx68k and the TG68K, fast
# RAM (amiga_fastram.vhd) on Zorro II and III.  Needs binutils-m68k-linux-gnu and Vivado
# (VIVADODIR, default ~/Xilinx/2025.2.1/Vivado).  Prints TB_CPU020_PASS / _FAIL per case.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
rtl="$root/CORE/Minimig_MiSTerMEGA65/rtl"
out="${1:-${TMPDIR:-/tmp}/tb_cpu020}"
: "${VIVADODIR:=$HOME/Xilinx/2025.2.1/Vivado}"
# fx68k reads its microcode as ../../Minimig_MiSTerMEGA65/rtl/fx68k/*.mem (relative to the run
# directory, as in the Vivado project): run in $out/a/b with a link $out/Minimig_MiSTerMEGA65
mkdir -p "$out/a/b"
ln -sfn "$root/CORE/Minimig_MiSTerMEGA65" "$out/Minimig_MiSTerMEGA65"
cd "$out/a/b"
source "$VIVADODIR/settings64.sh" >/dev/null
xvhdl -nolog "$rtl/tg68k/TG68K_Pack.vhd" "$rtl/tg68k/TG68K_ALU.vhd" "$rtl/tg68k/TG68KdotC_Kernel.vhd" >/dev/null
xvhdl -nolog -2008 "$root/K325T/amiga_fastram.vhd" >/dev/null
xvlog -nolog -relax "$rtl/cpu_wrapper.v" "$rtl/amiga_clk.v" >/dev/null
xvlog -nolog -sv "$rtl/fx68k/fx68k.sv" "$rtl/fx68k/fx68kAlu.sv" "$rtl/fx68k/uaddrPla.sv" \
      "$here/tb_cpu020.sv" >/dev/null
rc=0
for case in "0 3 0 0" "3 3 1 0" "3 6 1 1"; do
    set -- $case                   # CPUCFG FASTCFG CPU020 Z3
    defs=""
    [ "$3" = 1 ] && defs="$defs --defsym CPU020=1"
    [ "$4" = 1 ] && defs="$defs --defsym Z3=1"
    m68k-linux-gnu-as -m68020 $defs -o prog.o "$here/prog.s"
    m68k-linux-gnu-objcopy -O binary prog.o prog.bin
    python3 -c "import sys; d=open('prog.bin','rb').read(); d+=b'\0'*(len(d)&1); \
print('\n'.join('%04x'%(d[i]<<8|d[i+1]) for i in range(0,len(d),2)))" > prog.hex
    xelab -nolog -timescale 1ns/1ps -generic_top "CPUCFG=$1" -generic_top "FASTCFG=$2" \
          -debug off -s "tb$1$2" tb_cpu020 >/dev/null
    r=$(xsim -nolog -R "tb$1$2" | grep -E 'stamp|RESULT|TB_CPU020')
    echo "== CPUCFG=$1 FASTCFG=$2"; echo "$r"
    echo "$r" | grep -q TB_CPU020_PASS || rc=1
done
exit $rc
