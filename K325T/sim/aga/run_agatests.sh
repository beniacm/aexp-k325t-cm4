#!/bin/sh
# run_agatests.sh BUILD_DIR OUT_DIR [TEST...] -- the AGA tests of tools/mk_agatest.py on the bench:
# no Kickstart (mk_agatest's boot ROM jumps to the preloaded payload), AGA, 2 MB chip, 68020;
# every frame is captured and its md5 listed (OUT_DIR/<test>.md5: machine-time comparison between
# memory models), the frame 2 after "done" is kept as PNG and checked against the expected colours.
# ARGS: more bench options, e.g. "--cache --shrink 3" (chip RAM through the stage-2 cache RTL).
# One simulation at a time, nice 19.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
B="$1"; O="$2"; shift 2
T="$O/tests"
mkdir -p "$T"
/usr/bin/python3 "$here/../../tools/mk_agatest.py" build "$T" > "$O/tests.txt"
tests="$*"
[ -n "$tests" ] || tests="pal256 fmode1 fmode2 fmode3 ddf3c hires8f3 xor ham8 spr16 spr32 spr64"
cd "$B/run/a"
for t in $tests; do
    nice -n 19 "$B/obj_dir/tb" --kick "$T/bootrom.bin" --chipset 0x10 --mem 0x03 --cpu ${CPU:-0x03} \
        --frames 40 --preload "$T/$t.bin" 0x1c0000 --stop 0x1ffff0 0x600df00d ${ARGS:-} \
        --shot "$O/$t" --shot-every 1 > "$O/$t.log" 2>&1
    md5sum "$O/${t}"_*.ppm | sed "s|$O/||" > "$O/$t.md5"
    f=$(ls "$O/${t}"_*.ppm | tail -1)
    /usr/bin/python3 -c "from PIL import Image; Image.open('$f').save('$O/$t.png')"
    rm -f "$O/${t}"_*.ppm
    /usr/bin/python3 "$here/../../tools/mk_agatest.py" check "$t" "$O/$t.png" --dir "$T" > "$O/$t.check.json"
    /usr/bin/python3 -c "import json; r=json.load(open('$O/$t.check.json')); print('%-9s ok %3s bad %3s %s' % ('$t', r.get('ok'), r.get('bad'), r.get('error','') or (r.get('mismatches') or '')[:2] or ''), 'origin %s' % (r.get('origin'),), 'ham_bad=%s' % r['ham_pixel_bad'] if 'ham_pixel_bad' in r else '')"
    grep "^cache:" "$O/$t.log" || true
done
