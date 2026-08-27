#!/usr/bin/env bash
# M2 calibration — synthesize the engine and the fib demo top, then
# place-and-route the demo for an fmax estimate.
#
#   bash scripts/calib_m2.sh
#
# Results append to notes/15-m2-calibration.md (by hand, with judgment).

set -u
cd "$(dirname "$0")/.."

mix run scripts/emit_engine.exs || exit 1

for n in engine demo_fib; do
  echo "=== $n synth ==="
  yosys -q -l "_emit/engine/$n.yosys.log" \
    -p "read_verilog _emit/engine/$n.v; synth_ecp5 -top $n -json _emit/engine/$n.json" \
    2>&1 | tail -2
  awk '/Printing statistics/{f=1} f' "_emit/engine/$n.yosys.log" |
    grep -E "Number of cells|LUT4|PFUMX|L6MUX21|TRELLIS_FF|DP16KD|MULT18|CCU2C|DPR16X4" |
    head -14
done

echo "=== nextpnr demo_fib (fmax @ 50 MHz target) ==="
nextpnr-ecp5 --85k --json _emit/engine/demo_fib.json --freq 50 \
  --log _emit/engine/demo_fib.pnr.log 2>&1 | tail -4
grep -E "Max frequency for clock" _emit/engine/demo_fib.pnr.log | tail -4
grep -E "TRELLIS_SLICE:|DP16KD:|logic LUTs" _emit/engine/demo_fib.pnr.log | tail -6

echo "__CALIB_DONE__"
