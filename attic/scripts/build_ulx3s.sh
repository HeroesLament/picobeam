#!/usr/bin/env bash
# Build the ULX3S bitstream: emit → yosys → nextpnr-ecp5 → ecppack.
#
#   bash scripts/build_ulx3s.sh
#
# Produces _emit/ulx3s/picobeam.bit. Program the board with
#   fujprog _emit/ulx3s/picobeam.bit        (SRAM, volatile)
# or openFPGALoader --board ulx3s _emit/ulx3s/picobeam.bit

set -u
cd "$(dirname "$0")/.."
mkdir -p _emit/ulx3s

mix run scripts/emit_ulx3s.exs || exit 1

echo "=== yosys ==="
yosys -q -l _emit/ulx3s/yosys.log \
  -p "read_verilog _emit/ulx3s/ulx3s_top.v; synth_ecp5 -top ulx3s_top -json _emit/ulx3s/top.json" \
  2>&1 | tail -3
awk '/Printing statistics/{f=1} f' _emit/ulx3s/yosys.log |
  grep -E "Number of cells|LUT4|TRELLIS_FF|DP16KD|DPR16X4|MULT18|EHXPLLL" | head -10

echo "=== nextpnr ==="
nextpnr-ecp5 --85k --package CABGA381 --json _emit/ulx3s/top.json \
  --lpf priv/ulx3s_pb.lpf --textcfg _emit/ulx3s/top.config \
  --log _emit/ulx3s/pnr.log 2>&1 | tail -3
grep -E "Max frequency for clock" _emit/ulx3s/pnr.log | tail -4

echo "=== ecppack ==="
ecppack --compress _emit/ulx3s/top.config _emit/ulx3s/picobeam.bit && \
  ls -la _emit/ulx3s/picobeam.bit

echo "__ULX3S_BUILD_DONE__"
