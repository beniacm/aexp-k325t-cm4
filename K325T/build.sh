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
# Changes to files of git submodules (sy2002's Minimig fork, ...) are not committed there: they
# are patches in K325T/patches/<submodule directory name>/*.patch, applied in name order to the
# submodule's working tree here.  The patches stack (a later one may change lines of an earlier
# one), so the files they touch are rebuilt from the submodule's HEAD + all patches every build;
# if a file already holds exactly that result nothing changes, and a file with other local edits
# stops the build (it is left as it was).  The submodule pointers stay at upstream's commits.
for pdir in "$here"/patches/*/; do
    [ -d "$pdir" ] || continue
    sub=$(find "$root" -maxdepth 3 -type d -name "$(basename "$pdir")" -not -path "*/K325T/*" | head -1)
    [ -n "$sub" ] || { echo "ERROR: submodule for $pdir not found" >&2; exit 1; }
    tmp=$(mktemp -d)
    files=$(cat "$pdir"*.patch | sed -n 's|^+++ b/||p' | sort -u)
    for f in $files; do
        mkdir -p "$tmp/cur/$(dirname "$f")" "$tmp/new/$(dirname "$f")"
        cp "$sub/$f" "$tmp/cur/$f"
        git -C "$sub" show "HEAD:$f" > "$tmp/new/$f"
    done
    for p in "$pdir"*.patch; do
        (cd "$tmp/new" && git apply "$p") || { echo "ERROR: ${p#$here/} does not apply" >&2; rm -rf "$tmp"; exit 1; }
    done
    for f in $files; do
        if cmp -s "$tmp/cur/$f" "$tmp/new/$f"; then
            echo "patches already applied: $(basename "$sub")/$f"
        elif git -C "$sub" diff --quiet -- "$f"; then
            cp "$tmp/new/$f" "$sub/$f" && echo "patches applied: $(basename "$sub")/$f"
        else
            echo "ERROR: $sub/$f has local changes that are not the patches' result" >&2
            rm -rf "$tmp"; exit 1
        fi
    done
    rm -rf "$tmp"
done
python3 "$here/gen_top.py" "$root/M2M/vhdl/top_mega65-r6.vhd" "$here/top_qmtech_k325t_cm4.vhd" \
        "$here/top_qmtech_k325t_cm4.tpl.vhd"
# a1200-lxshell: the menu definition for the Linux shell (travels with the bitstream as .menu) and
# its id + factory defaults for the host master (host_menu_pkg.vhd); both from config.vhd
mkdir -p "$here/bin"
python3 -I "$here/menu_gen.py" "$root" "$here/bin/aexp_k325t_cm4$suffix.menu" --vhdl "$here/host_menu_pkg.vhd"
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
# the gate: every timing constraint matched something, no unexpected critical warning, timing met
python3 -I "$here/check_build_log.py" "$here/build$suffix.log" "$here/timing$suffix.txt" \
    || { echo "ERROR: build gate failed (bitstream bin/aexp_k325t_cm4$suffix.bit is NOT a candidate)" >&2; exit 1; }
