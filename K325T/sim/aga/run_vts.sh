#!/bin/sh
# run_vts.sh BUILD_DIR OUT_DIR VTS_DIR REF_DIR TEST... -- vAmigaTS tests on the bench, A500 machine:
# Kickstart 1.3 (the user's own ROM, read in place: KICK, default ~/Downloads/kick34005.A500),
# 512 KB chip + 512 KB slow RAM, fx68k, the test's ADF in df0 (the core's adf_track_engine), MiSTer's
# floppy turbo on (only the loading gets faster).  TEST = path inside VTS_DIR[:ocs|ecs[:REFNAME]],
# e.g. Agnus/Registers/VPOS/vhpos2:ocs:vhpos2_ocs.  The picture of the last frame (FRAMES, default 400)
# is compared with REF_DIR/<path>/<REFNAME>.tiff (vts_compare.py, crop at OFFSET, default 144,22).  JOBS parallel runs (default 1),
# nice 19.  Output: OUT_DIR/<name>.ppm/.log/.json/_cmp.png, one summary line per test.
# STATE_OCS / STATE_ECS: a --save state of this build taken before Kickstart's first disk access
# (e.g. frame 170 of a run with any 160-track ADF, same chipset): each test then starts from it with
# its own ADF in df0 (the image lives in the C++ driver, not in the saved model).
here="$(cd "$(dirname "$0")" && pwd)"
B="$1"; O="$2"; V="$3"; R="$4"; shift 4
mkdir -p "$O"
KICK="${KICK:-$HOME/Downloads/kick34005.A500}"
run_one() {
    spec="$1"; p="${spec%%:*}"; rest="${spec#"$p"}"; rest="${rest#:}"
    cs="${rest%%:*}"; [ -n "$cs" ] || cs=ecs
    ref="${rest#"$cs"}"; ref="${ref#:}"; t="$(basename "$p")"; [ -n "$ref" ] || ref="$t"
    case "$cs" in ocs) c=0x00; st="${STATE_OCS:-}" ;; *) c=0x08; st="${STATE_ECS:-}" ;; esac
    rs=""; [ -n "$st" ] && rs="--restore $st"
    n="$(echo "$p" | tr '/' '_')_$cs"
    (cd "$B/run/a" && nice -n 19 "$B/obj_dir/tb" --kick "$KICK" --chipset $c --mem 0x04 --cpu 0x00 \
        --frames "${FRAMES:-400}" --adf "$V/$p/$t.adf" --floppy-turbo --shot "$O/$n" --shot-last $rs \
        > "$O/$n.log" 2>&1)
    f=$(ls "$O/${n}"_*.ppm 2>/dev/null | tail -1)
    [ -n "$f" ] || { echo "$n: no picture"; return; }
    mv "$f" "$O/$n.ppm"
    /usr/bin/python3 "$here/vts_compare.py" "$O/$n.ppm" "$R/$p/$ref.tiff" --png "$O/${n}_cmp.png" --json --offset "${OFFSET:-144,22}" > "$O/$n.json"
    /usr/bin/python3 -c "import json; r=json.load(open('$O/$n.json')); print('%-48s %6d px differ (%.3f %%) offset %s rows %s' % ('$n', r['mismatch'], r['mismatch_pct'], r['offset'], r['bad_rows']))"
}
jobs=0
for s in "$@"; do
    run_one "$s" &
    jobs=$((jobs + 1))
    if [ "$jobs" -ge "${JOBS:-1}" ]; then wait; jobs=0; fi
done
wait
