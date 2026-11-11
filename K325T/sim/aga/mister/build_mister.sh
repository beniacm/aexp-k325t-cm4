#!/bin/sh
# build_mister.sh -- MiSTer's full-system Verilator simulation (Minimig-AGA_MiSTer, read-only clone in
# ext/) copied to the scratch area, with this directory's tb_top.sv / sim_main.cpp (video tap, payload
# preload, frames, dump).  4 jobs, nice 19.  Usage: build_mister.sh [DEST]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
: "${SCRATCH:=/tmp/claude-1000/-home-me-projects-mega65/ae20aebe-73df-4a68-8048-a9d4df735cf0/scratchpad}"
D="${1:-$SCRATCH/aga/mister}"
SRC="${MISTER:-$HOME/projects/mega65/ext/Minimig-AGA_MiSTer}"
[ -d "$D/rtl" ] || { mkdir -p "$D"; git -C "$SRC" archive HEAD | tar -x -C "$D"; }
cp "$here/tb_top.sv" "$here/sim_main.cpp" "$D/rtl/sim/system/"
# the simulation-only fixes of ../build.sh (blocking assignments in separate clocked blocks: with them
# Verilator lets other blocks see the new value in the same edge and the copper never starts)
R="$D/rtl"
sed -i -E 's/^(\s*)(copjmp1|copjmp2|strobe1|strobe2) = ([01]);/\1\2 <= \3;/; s/^(\s*)strobe = copjmp1 \| copjmp2;/\1strobe <= copjmp1 | copjmp2;/' "$R/agnus_copper.v"
sed -i -E 's/^(\s*)out=mem\[out_ptr\[10:0\]\];/\1out<=mem[out_ptr[10:0]];/' "$R/paula_floppy_fifo.v"
sed -i -E 's/joy1enable = ([01]);/joy1enable <= \1;/' "$R/userio.v"
[ "$(grep -cE '(copjmp1|copjmp2|strobe1|strobe2|strobe) <= ' "$R/agnus_copper.v")" -ge 9 ] || { echo "copper fix" >&2; exit 1; }
# the 68EC020 cycle tables (Quartus ram_init_file attribute, ignored by Verilator): $readmemh
/usr/bin/python3 "$here/mif2hex.py" "$R/tg68k/m68k_cyc_idx.mif" "$D/rtl/sim/system/m68k_cyc_idx.hex"
/usr/bin/python3 "$here/mif2hex.py" "$R/tg68k/m68k_ea_idx.mif" "$D/rtl/sim/system/m68k_ea_idx.hex"
grep -q 'readmemh("m68k_cyc_idx.hex"' "$R/cpu_cycles.v" || sed -i '/reg \[4:0\] ea_rom\[2048\];/a initial begin $readmemh("m68k_cyc_idx.hex", cyc_rom); $readmemh("m68k_ea_idx.hex", ea_rom); end  // K325T sim only' "$R/cpu_cycles.v"
grep -q 'readmemh("m68k_cyc_idx.hex"' "$R/cpu_cycles.v" || { echo "cycle table fix" >&2; exit 1; }
cd "$D/rtl/sim/system"
sed -i 's/-j 24/-j 4/; s/^verilator /nice -n 19 verilator /; s/-march=native/-march=native/' build.sh
PATH=/home/linuxbrew/.linuxbrew/bin:$PATH sh build.sh > build.log 2>&1 || { tail -30 build.log; exit 1; }
ls -la obj_dir/Vtb_top
