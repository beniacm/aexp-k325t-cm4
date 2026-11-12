#!/bin/sh
# reset_long_test.sh TB KICK [OUTDIR] [--full] -- the 68EC020 reset-vector test (stage 3, patch 0132).
#
# After a reset the 68EC020 reads SSP/PC from the Kickstart under the overlay with 32-bit cycles; the
# second word of such a read (word A+1) must come from the ROM, not from whatever 32-bit chip read
# came last before the reset.  Power-up (and every plain bench run) starts with that held word = 0,
# which happens to boot ($F80000 jumps on), so the bug only showed on the board after a full reset.
#   case A (default): start with a stale held word (+dout2init=1234): Kickstart 3.1 must still boot:
#           ExecBase (the long at $4) set and in chip RAM after FRAMES_A frames.
#   case B (--full):  a real reset after 32-bit activity (--reset-at 60), then the Kickstart must
#           reach its insert-disk screen again (more than 2 colours in the frame RESET+190).
# TB = a full bench build (obj_dir/tb with the cache, not FAST_A500), KICK = Kickstart 3.1 40.068
# (A1200; the user's own ROM, never in the repository).  68EC020 = --cpu 3 --chipset 0x10 (AGA)
# --stock, chip RAM through the cache (--cache --mem 3).  Prints PASS/FAIL per case; exit 1 on FAIL.
TB=$1; KICK=$2; OUT=${3:-.}; FULL=$4
[ -x "$TB" ] && [ -f "$KICK" ] || { echo "usage: reset_long_test.sh TB KICK [OUTDIR] [--full]"; exit 2; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd); KICK=$(cd "$(dirname "$KICK")" && pwd)/$(basename "$KICK")
TB=$(cd "$(dirname "$TB")" && pwd)/$(basename "$TB")
# the $readmem files are found relative to the working directory (as in every bench run: OUT/run/a,
# with OUT/Minimig_MiSTerMEGA65/rtl/fx68k/*.mem and ../K325T/cpu020/*.mem next to OUT)
[ -d "$(dirname "$TB")/../run/a" ] && cd "$(dirname "$TB")/../run/a"
FRAMES_A=${FRAMES_A:-40}
M="--kick $KICK --chipset 0x10 --mem 0x03 --cpu 0x03 --stock --cache"
rc=0
nice -n 19 "$TB" $M --frames $FRAMES_A --dump 0 8 "$OUT/a_low.bin" +dout2init=1234 > "$OUT/a.log" 2>&1
eb=$(od -An -tx1 -j4 -N4 "$OUT/a_low.bin" | tr -d ' \n')
case "$eb" in
  00[01]?????) [ "$eb" != "00000000" ] && r=PASS || r=FAIL ;;
  *) r=FAIL ;;
esac
echo "case A (stale word A+1 = \$1234 at power-up): ExecBase \$$eb after $FRAMES_A frames: $r"
[ $r = PASS ] || rc=1
if [ "$FULL" = "--full" ]; then
  nice -n 19 "$TB" $M --frames 251 --reset-at 60 --shot "$OUT/b" --shot-frames 250 > "$OUT/b.log" 2>&1
  n=$(/usr/bin/python3 -c "from PIL import Image; print(len(Image.open('$OUT/b_0250.ppm').getcolors(1<<20)))" 2>/dev/null)
  [ "${n:-0}" -gt 2 ] && r=PASS || r=FAIL
  echo "case B (reset at frame 60, after 32-bit activity): frame 250 has ${n:-?} colours: $r"
  [ $r = PASS ] || rc=1
fi
exit $rc
