#!/bin/sh
# run_mister_tests.sh MISTER_DIR OUT_DIR TESTS_DIR [TEST...] -- the AGA tests of tools/mk_agatest.py on
# MiSTer's full system (build_mister.sh): AGA, 2 MB chip, CPU byte ${CPU:-7} (68020 + stock-speed
# 68EC020 timing), payload preloaded, the frame 2 frames after "done" checked.  nice 19.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
D="$1"; O="$2"; T="$3"; shift 3
mkdir -p "$O"
tests="$*"
[ -n "$tests" ] || tests="pal256 fmode1 fmode2 fmode3 ddf3c hires8f3 xor ham8 spr16 spr32 spr64"
cd "$D/rtl/sim/system"
for t in $tests; do
    nice -n 19 ./obj_dir/Vtb_top --rom "$T/bootrom.bin" --preload "$T/$t.bin" 0x1c0000 --cpu ${CPU:-7} \
        --quiet --ms 1000 --shot "$O/$t" > "$O/$t.log" 2>&1 || true
    f=$(ls "$O/${t}"_*.ppm | tail -1)
    /usr/bin/python3 -c "from PIL import Image; Image.open('$f').save('$O/$t.png')"
    rm -f "$O/${t}"_*.ppm
    /usr/bin/python3 "$here/../../../tools/mk_agatest.py" check "$t" "$O/$t.png" --dir "$T" > "$O/$t.check.json"
    /usr/bin/python3 -c "import json; r=json.load(open('$O/$t.check.json')); print('%-9s ok %3s bad %3s %s' % ('$t', r.get('ok'), r.get('bad'), r.get('error','') or (r.get('mismatches') or '')[:3] or ''), 'ham_bad=%s' % r['ham_pixel_bad'] if 'ham_pixel_bad' in r else '')"
done
