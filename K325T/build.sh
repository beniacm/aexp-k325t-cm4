#!/usr/bin/env bash
# build.sh -- generate the top and the source list, check the QNICE firmware, run Vivado.
set -euo pipefail
# Usage: build.sh [radxacm3]
#   (none)    Luckfox Core3566 module   -> bin/aexp_k325t_cm4.bit           (log build.log)
#   radxacm3  Radxa CM3 module: the "CM bus" section of qmtech_k325t_cm4.xdc replaced by
#             qmtech_k325t_cm4_radxacm3_bus.xdc -> bin/aexp_k325t_cm4_radxacm3.bit (log build_radxacm3.log)
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
: "${VIVADODIR:=$HOME/Xilinx/2025.2.1/Vivado}"
variant="${1:-}"
case "$variant" in
    "")       xdc="$here/qmtech_k325t_cm4.xdc"; suffix="" ;;
    radxacm3) xdc="$here/qmtech_k325t_cm4_radxacm3.xdc"; suffix="_radxacm3"
              awk -v f="$here/qmtech_k325t_cm4_radxacm3_bus.xdc" \
                  '/^## >>> CM bus/ { while ((getline l < f) > 0) print l; skip=1; next }
                   /^## <<< CM bus/ { skip=0; next } !skip' "$here/qmtech_k325t_cm4.xdc" > "$xdc"
              grep -q 'PACKAGE_PIN D14 ' "$xdc" && ! grep -q 'PACKAGE_PIN B9 ' "$xdc" \
                  || { echo "ERROR: CM bus section not replaced in $xdc" >&2; exit 1; } ;;
    *)        echo "usage: $0 [radxacm3]" >&2; exit 2 ;;
esac
python3 "$here/gen_top.py" "$root/M2M/vhdl/top_mega65-r6.vhd" "$here/top_qmtech_k325t_cm4.vhd" \
        "$here/top_qmtech_k325t_cm4.tpl.vhd"
python3 "$here/gen_sources.py"
# The QNICE firmware (M2M shell: menus, file browser, SD/FAT32) is assembled from
# CORE/m2m-rom/m2m-rom.asm by CORE/m2m-rom/make_rom.sh (the R6 project runs it as a
# pre-synthesis hook; here it runs every build).  It needs the QNICE assembler and the
# monitor's dist_kit, built once:
#   (cd M2M/QNICE/assembler && cc -O2 -o qasm qasm.c && cc -O2 -o qasm2rom qasm2rom.c)
#   (cd M2M/QNICE/monitor && bash compile_and_distribute.sh)
if [ ! -x "$root/M2M/QNICE/assembler/qasm" ] || [ ! -s "$root/M2M/QNICE/dist_kit/sysdef.asm" ]; then
    echo "ERROR: QNICE assembler or dist_kit missing -- see the comment in K325T/build.sh" >&2
    exit 1
fi
rm -f "$root/CORE/m2m-rom/m2m-rom.rom"
(cd "$root/CORE/m2m-rom" && bash make_rom.sh) > "$here/make_rom$suffix.log" 2>&1
if [ ! -s "$root/CORE/m2m-rom/m2m-rom.rom" ]; then
    echo "ERROR: QNICE firmware build failed, see K325T/make_rom$suffix.log" >&2
    exit 1
fi
source "$VIVADODIR/settings64.sh"
cd "$here"
vivado -mode batch -nojournal -log "$here/build$suffix.log" -source "$here/build.tcl" -tclargs "$xdc" "$suffix"
