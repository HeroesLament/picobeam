#!/usr/bin/env bash
# yosys's xilinx cells_sim.v models RAMB18E1/RAMB36E1 as timing-only
# shells (a specify block, no behavior), so their outputs float in a
# post-synthesis simulation. Splice in scripts/xc7_bram_behav.vh.
set -euo pipefail

src=$(yosys-config --datdir)/xilinx/cells_sim.v
out=${1:-_emit/xc7/cells_sim_bram.v}

awk '
  function splice(dbits, abits, ninit, ninitp,    k) {
    print "localparam XB_DBITS = " dbits ";"
    print "localparam XB_ABITS = " abits ";"
    print "`include \"xc7_bram_behav.vh\""
    print "initial begin : xb_load"
    print "  integer k;"
    for (k = 0; k < ninit; k++) printf "  xb_d[%d +: 256] = INIT_%02X;\n", 256 * k, k
    for (k = 0; k < ninitp; k++) printf "  xb_p[%d +: 256] = INITP_%02X;\n", 256 * k, k
    print "  for (k = 0; k < XB_DBITS; k = k + 1) xb_d[k] = (xb_d[k] === 1'"'"'b1);"
    print "  for (k = 0; k < XB_PBITS; k = k + 1) xb_p[k] = (xb_p[k] === 1'"'"'b1);"
    print "end"
  }
  /^module RAMB18E1 \(/ { mod = 18 }
  /^module RAMB36E1 \(/ { mod = 36 }
  mod && /^ *specify/ { skip = 1 }
  mod && skip { if ($0 ~ /^ *endspecify/) skip = 0; next }
  mod && /^endmodule/ {
    if (mod == 18) splice(16384, 14, 64, 8)
    else splice(32768, 15, 128, 16)
    n++
    mod = 0
  }
  { print }
  END { if (n != 2) { print "mk_cells_sim: spliced " n " modules, expected 2" > "/dev/stderr"; exit 1 } }
' "$src" > "$out"

echo "$out: $(wc -l < "$out") lines"
