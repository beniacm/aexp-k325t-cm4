#!/usr/bin/env python3
"""check_build_log.py LOG TIMING -- the build gate (build.sh runs it after Vivado, both variants).

Fails (exit 1) when
  * any timing constraint matched no object: CRITICAL WARNING [Vivado 12-4739] "No valid object(s)"
    (a constraint that matches nothing is silently not applied -- that is how the local-QNICE build
    lost QNICE's EAE multicycle when QNICE moved into a generate: WNS -15 ns); the constraints of
    parts a build flag leaves out are in their own .xdc files, added only when the part is built
    (build.tcl), so a correct build has none of these;
  * any other critical warning is not on the allow-list below (or occurs more often);
  * the timing summary does not say that all constraints are met.
"""
import re
import sys

# critical warnings every build of this design has (ID -> at most this many)
ALLOW = {
    'Vivado 12-3645': 1,   # add_files: "adding files one at a time can be performance intensive"
    'Vivado 12-4439': 1,   # set_false_path CORE/* -> i_lat_meter/aux_reg: "very large number of objects"
}
TIMING_CMDS = ('set_multicycle_path', 'create_generated_clock', 'create_clock', 'set_false_path',
               'set_max_delay', 'set_min_delay', 'set_clock_groups', 'set_input_delay',
               'set_output_delay', 'set_case_analysis', 'set_bus_skew')


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    log, timing = sys.argv[1], sys.argv[2]
    bad = []
    count = {}
    for line in open(log, errors='replace'):
        if not line.startswith('CRITICAL WARNING:'):
            continue
        m = re.match(r'CRITICAL WARNING: \[([A-Za-z]+ [0-9-]+)\]\s*(.*)', line)
        cid, text = (m.group(1), m.group(2)) if m else ('?', line)
        count[cid] = count.get(cid, 0) + 1
        if cid == 'Vivado 12-4739' or 'No valid object(s)' in text:
            cmd = text.split(':', 1)[0]
            what = 'timing constraint' if cmd in TIMING_CMDS else 'constraint'
            bad.append(f'{what} matches nothing: {text.strip()[:300]}')
    for cid, n in sorted(count.items()):
        if cid == 'Vivado 12-4739':
            continue
        if n > ALLOW.get(cid, 0):
            bad.append(f'critical warning [{cid}] x{n} (allowed {ALLOW.get(cid, 0)})')
    try:
        met = 'All user specified timing constraints are met.' in open(timing, errors='replace').read()
    except OSError as e:
        met = False
        bad.append(f'no timing summary: {e}')
    if not met:
        bad.append(f'timing not met ({timing})')
    if bad:
        print('BUILD GATE FAILED:')
        for b in bad:
            print('  ' + b)
        return 1
    print('BUILD GATE: no unmatched constraints, critical warnings within the allow-list '
          f'({sum(count.values())}), timing met')
    return 0


if __name__ == '__main__':
    sys.exit(main())
