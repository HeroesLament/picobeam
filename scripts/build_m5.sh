#!/usr/bin/env bash
# Build the two-engine ULX3S bitstream: emit → yosys → nextpnr → ecppack.
#
#   bash scripts/build_m5.sh
#
# Produces _emit/ulx3s/picobeam_m5.bit. Program the board with
#   fujprog _emit/ulx3s/picobeam_m5.bit       (SRAM, volatile)
#
# Two BarrelEngines, two RingLinks, SdBoot and the debug UART. One
# engine was ~17k LUT4 at `notes/24`; this is the run that says what two
# of them cost and whether the ring changed the critical path.

set -u
cd "$(dirname "$0")/.."
mkdir -p _emit/ulx3s

mix run scripts/emit_m5.exs || exit 1

echo "=== yosys ==="
yosys -q -l _emit/ulx3s/yosys_m5.log \
  -p "read_verilog _emit/ulx3s/ulx3s_m5_top.v; synth_ecp5 -top ulx3s_m5_top -json _emit/ulx3s/m5.json" \
  2>&1 | tail -3
awk '/Printing statistics/{f=1} f' _emit/ulx3s/yosys_m5.log |
  grep -E "Number of cells|LUT4|TRELLIS_FF|DP16KD|DPR16X4|MULT18|EHXPLLL" | head -10

echo "=== nextpnr ==="
nextpnr-ecp5 --85k --package CABGA381 --json _emit/ulx3s/m5.json \
  --lpf priv/ulx3s_pb.lpf --textcfg _emit/ulx3s/m5.config \
  --log _emit/ulx3s/pnr_m5.log 2>&1 | tail -3
grep -E "Max frequency for clock|Info: Device utilisation" -A 12 _emit/ulx3s/pnr_m5.log | tail -20

echo "=== ecppack ==="
ecppack --compress _emit/ulx3s/m5.config _emit/ulx3s/picobeam_m5.bit && \
  ls -la _emit/ulx3s/picobeam_m5.bit

echo "__M5_BUILD_DONE__"
