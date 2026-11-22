#!/bin/sh
# unit bench of K325T/fmeas.v (a500-bacon): iverilog, then check_fmeas.py.  Work directory: $1 (default ./fmeas_run)
here=$(cd "$(dirname "$0")" && pwd)
w=${1:-$here/fmeas_run}
mkdir -p "$w" && cd "$w" || exit 1
iverilog -g2012 -o tb_fmeas.vvp "$here/tb_fmeas.v" "$here/../fmeas.v" || exit 1
nice -n 19 vvp -n tb_fmeas.vvp > vvp.log 2>&1 || { tail vvp.log; exit 1; }
python3 "$here/check_fmeas.py"
