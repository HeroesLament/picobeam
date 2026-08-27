#!/usr/bin/env bash
# Build the M3 demo bitstream: emit → yosys → nextpnr-ecp5 → ecppack.
set -u
cd "$(dirname "$0")/.."
mkdir -p _emit/m4top
mix run scripts/emit_m4_top.exs || exit 1
echo "=== yosys ==="
yosys -q -l _emit/m4top/yosys.log \
  -p "read_verilog _emit/m4top/ulx3s_m4_top.v; synth_ecp5 -top ulx3s_m4_top -json _emit/m4top/top.json" \
  2>&1 | tail -3
awk '/Printing statistics/{f=1} f' _emit/m4top/yosys.log |
  grep -E "Number of cells|LUT4|TRELLIS_FF|DP16KD|DPR16X4|EHXPLLL" | head -8
echo "=== nextpnr ==="
nextpnr-ecp5 --85k --package CABGA381 --json _emit/m4top/top.json \
  --lpf priv/ulx3s_m3.lpf --textcfg _emit/m4top/top.config \
  --log _emit/m4top/pnr.log 2>&1 | tail -3
grep -E "Max frequency for clock" _emit/m4top/pnr.log | tail -3
echo "=== ecppack ==="
ecppack --compress _emit/m4top/top.config _emit/m4top/picobeam_m4.bit && \
  ls -la _emit/m4top/picobeam_m4.bit
echo "__M4_BUILD_DONE__"
