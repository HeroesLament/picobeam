#!/usr/bin/env bash
# Build the M3 demo bitstream: emit → yosys → nextpnr-ecp5 → ecppack.
set -u
cd "$(dirname "$0")/.."
mkdir -p _emit/m3top
mix run scripts/emit_m3_top.exs || exit 1
echo "=== yosys ==="
yosys -q -l _emit/m3top/yosys.log \
  -p "read_verilog _emit/m3top/ulx3s_m3_top.v; synth_ecp5 -top ulx3s_m3_top -json _emit/m3top/top.json" \
  2>&1 | tail -3
awk '/Printing statistics/{f=1} f' _emit/m3top/yosys.log |
  grep -E "Number of cells|LUT4|TRELLIS_FF|DP16KD|DPR16X4|EHXPLLL" | head -8
echo "=== nextpnr ==="
nextpnr-ecp5 --85k --package CABGA381 --json _emit/m3top/top.json \
  --lpf priv/ulx3s_m3.lpf --textcfg _emit/m3top/top.config \
  --log _emit/m3top/pnr.log 2>&1 | tail -3
grep -E "Max frequency for clock" _emit/m3top/pnr.log | tail -3
echo "=== ecppack ==="
ecppack --compress _emit/m3top/top.config _emit/m3top/picobeam_m3.bit && \
  ls -la _emit/m3top/picobeam_m3.bit
echo "__M3_BUILD_DONE__"
