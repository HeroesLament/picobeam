#!/usr/bin/env bash
# Build the Zynq-7020 timing harness: emit -> yosys -> nextpnr -> oxibit.
#
#   bash scripts/build_xc7_m5.sh            # -nocarry, seed 1
#   CARRY=1 SEED=3 bash scripts/build_xc7_m5.sh
#   SKIP_EMIT=1 SKIP_SYNTH=1 bash ...        # place and route the last netlist
#   TAG=seed2 SEED=2 JSON_FROM=_emit/xc7/nocarry/xc7_m5.json SKIP_EMIT=1 SKIP_SYNTH=1 bash ...
#   PNR_OPTS="-o hold-fix" ...               # extra nextpnr arguments
#
# Produces _emit/xc7/<tag>/xc7_m5.{json,fasm,bit} and pnr.log, where tag
# is "nocarry" or "carry". The pnr log's "Max frequency" line for pb_clk
# is nextpnr's estimate; the farm measures the real one.

set -euo pipefail
cd "$(dirname "$0")/.."

readonly OXC7="$HOME/src/openxc7"
readonly NEXTPNR="$OXC7/nextpnr/build-ourfork/nextpnr-himbaechel"
readonly DB="$OXC7/prjxray-db-517d66a/zynq7"
readonly OXIBIT="$HOME/src/oxibit/target/release/oxibit"
readonly PART="xc7z020clg400-1"

seed="${SEED:-1}"
if [[ "${CARRY:-0}" == "1" ]]; then
  tag="carry"
  carry_flag=""
else
  tag="nocarry"
  carry_flag="-nocarry"
fi
tag="${TAG:-$tag}"
out="_emit/xc7/$tag"
mkdir -p "$out"
# the netlist to place: this build's own, or another build's via JSON_FROM
json="${JSON_FROM:-$out/xc7_m5.json}"
# extra nextpnr arguments, split on whitespace
read -r -a pnr_opts <<< "${PNR_OPTS:-}"

# 1. elaborate, unless the caller already did
if [[ "${SKIP_EMIT:-0}" != "1" ]]; then
  mix run scripts/emit_xc7_m5.exs
fi

# 2. yosys, three stages: the dffunmap between them is what keeps the
#    packer from producing set/reset routing the router cannot resolve
synthesize() {
  local out="$1"
  local carry_flag="$2"

  cat > "$out/synth.ys" <<YS
read_verilog -sv _emit/xc7/xc7_m5_top.v
synth_xilinx -flatten $carry_flag -abc9 -family xc7 -top xc7_m5_top -run begin:map_ffs
dffunmap
synth_xilinx -flatten $carry_flag -abc9 -family xc7 -top xc7_m5_top -run map_ffs:
stat
write_json $out/xc7_m5.json
YS
  yosys -q -l "$out/yosys.log" -s "$out/synth.ys"
  awk '/Printing statistics/{f=1} f' "$out/yosys.log" |
    grep -E 'LUT[1-6]|FD[RSCP]E|CARRY4|RAMB|DSP48|RAM(32|64)M|MMCM|BUFG|PS7' | head -24
}

if [[ "${SKIP_SYNTH:-0}" == "1" ]]; then
  echo "=== yosys ($tag): skipped, using $json ==="
else
  echo "=== yosys ($tag) ==="
  synthesize "$out" "$carry_flag"
fi

# 3. nextpnr
echo "=== nextpnr ($tag, seed $seed, ${PNR_OPTS:-no extra options}) ==="
: > "$out/empty.xdc"
"$NEXTPNR" --device "$PART" \
  -o "xdc=$out/empty.xdc" \
  --json "$json" \
  -o "fasm=$out/xc7_m5.fasm" \
  --router router2 \
  --timing-allow-fail \
  --seed "$seed" \
  ${pnr_opts[@]+"${pnr_opts[@]}"} \
  --log "$out/pnr.log" > /dev/null 2>&1 || {
    tail -20 "$out/pnr.log"
    exit 1
  }
grep -E 'Max frequency for clock|utilisation|SLICE|RAMB|DSP' "$out/pnr.log" | tail -16

# 4. bitstream
echo "=== oxibit fasm2bit ==="
"$OXIBIT" fasm2bit "$out/xc7_m5.fasm" "$out/xc7_m5.bit" --db-root "$DB" --part "$PART"
ls -la "$out/xc7_m5.bit"
echo "__XC7_BUILD_DONE__"
