#!/usr/bin/env bash
# Probe C (M2) — synthesize the register-window variants and report area.
#
#   bash scripts/probe_c.sh
#
# Expects: mix run scripts/probe_c.exs has emitted _emit/probe_c/*.v
# (this script runs it if the .v files are missing), and yosys on PATH.
# fmax via nextpnr needs an IO-shift wrapper (the raw unit has ~600
# ports, more pins than the 85F has) — that is the next probe step;
# this one prices area.

set -u
cd "$(dirname "$0")/.."

if [ ! -f _emit/probe_c/reg_window.v ]; then
  mix run scripts/probe_c.exs || exit 1
fi

for n in reg_window reg_window_narrow reg_window_ram; do
  echo "=== $n ==="
  yosys -q -l "_emit/probe_c/$n.yosys.log" \
    -p "read_verilog _emit/probe_c/$n.v; synth_ecp5 -top $n" \
    2>&1 | tail -3
  awk '/=== '"$n"' ===/{flag=1} flag && NF' "_emit/probe_c/$n.yosys.log" |
    grep -E "Number of cells|TRELLIS_FF|LUT4|PFUMX|L6MUX21|CCU2C|DP16KD|MULT18" |
    head -12
done

echo "__PROBE_C_SYNTH_DONE__"
