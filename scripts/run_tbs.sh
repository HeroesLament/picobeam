#!/usr/bin/env bash
# The regression gate: emit every part, run every iverilog testbench.
#
#   scripts/run_tbs.sh            # everything
#   scripts/run_tbs.sh alu m4     # only tbs whose name matches
#
# Netlists are patched on the way in (wire -> reg for the procedurally
# assigned _case_* signals, memories zero-initialised) exactly as the
# per-pass instructions in each tb header describe.
set -u
cd "$(dirname "$0")/.."
# `quick` skips the board tops, which are ~85% of the wall clock: they
# simulate tens of milliseconds of real time through the whole design.
# Use it in the inner loop; run the full gate before delivering.
QUICK=0
# `reuse` skips emit, image generation and netlist patching and goes
# straight to the testbenches. The whole prologue is about forty
# seconds and is identical between two runs of an unchanged tree, so
# splitting the gate into filtered chunks used to pay for it once per
# chunk. Only ever correct when the previous run in this tree got past
# the prologue — it does not check.
REUSE=0
case "${1:-}" in quick|-q) QUICK=1; shift;; esac
case "${1:-}" in reuse|-r) REUSE=1; shift;; esac
case "${1:-}" in quick|-q) QUICK=1; shift;; esac
FILTER="${*:-}"
D=_emit/all
pass=0; fail=0; failed=""
# One vvp image per RUN of this script. Two gates in flight at once
# used to share /tmp/tb.vvp and report each other's results — a
# failure that looks like a design bug and is not.
VVP="/tmp/tb.$$.vvp"
trap 'rm -f "$VVP"' EXIT

if [ $REUSE -eq 0 ]; then
mix run scripts/emit_all.exs 2>&1 | grep -q __EMIT_ALL_DONE__ || {
  echo "emit failed"; exit 1; }

# `notes/41` — a net with two continuous drivers. EHDL's flattener does
# not namespace, so a child's port name that matches a net in the parent
# silently merges the two; the bit that goes `x` surfaces modules away
# from the collision. Checked on the OUTPUT, where the answer is
# unambiguous, rather than by modelling the renaming rules.
python3 scripts/check_drivers.py $D/*.v || exit 1

# the images the engine-level testbenches load, and the shape vectors
for s in mk_m3_spawn8 mk_fixed mk_heapprog mk_gcloop mk_gcconc mk_bitwise mk_funs mk_fnelixir mk_maps mk_mapelixir mk_bins mk_binelixir mk_names mk_board mk_ptrgc mk_scanptr mk_ptr mk_csend mk_ldcfail mk_super mk_trapread mk_erlsup mk_ser_vectors mk_gc_vectors mk_ring2 mk_spawn2 mk_names2 mk_slink2 mk_mon2 mk_super2board mk_tailloop mk_srv mk_otp2 mk_slink mk_deep mk_try mk_vmhalt mk_image mk_elixir mk_m3_fib mk_m4_pingpong mk_m4_evict mk_bench check_shape_hash; do
  mix run scripts/$s.exs >/dev/null 2>&1
done
mix run scripts/emit_tops.exs >/dev/null 2>&1
mix run scripts/emit_m5.exs >/dev/null 2>&1
# the directory first: on a fresh tree the copy had nowhere to land and
# the hex-loading benches failed on a missing image
mkdir -p $D/p
cp _emit/m3/*.hex _emit/bench/*.hex _emit/m4/*.hex _emit/sd/*.hex "$D/p/" 2>/dev/null

for f in $D/*.v; do
  python3 scripts/patch_netlist.py "$f" "$D/p/$(basename "$f")" 2>/dev/null
done
fi   # REUSE

IVFLAGS=""
# per-run wall-clock cap. 900 s covers everything that simulates one
# engine; `tb_m5_top` simulates two and takes about thirty-five minutes,
# so it raises this rather than everything else waiting on it.
TBTIMEOUT=900
run() {
  local tb="$1"; shift
  local label="$tb"
  if [ "$tb" = "tb_bench" ]; then label="tb_bench:$1"; shift; fi
  case "$tb:${1:-}" in tb_fixed:heapprog|tb_fixed:ldcfail|tb_fixed:super_kill|tb_fixed:super_trap|tb_fixed:super_exit2|tb_fixed:super_mon|tb_fixed:super_tmo_hit|tb_fixed:super_tmo_miss|tb_fixed:trapread|tb_fixed:erlsup|tb_fixed:ptr|tb_fixed:csend|tb_fixed:tailloop|tb_fixed:srv|tb_fixed:otp|tb_fixed:slink|tb_fixed:deep|tb_fixed:try|tb_fixed:vmhalt|tb_fixed:elixir|tb_fixed:gcloop|tb_fixed:gcconc|tb_fixed:bitwise|tb_fixed:funs|tb_fixed:funbad|tb_fixed:funar|tb_fixed:fnelixir|tb_fixed:maps|tb_fixed:mapelixir|tb_fixed:bins|tb_fixed:binelixir|tb_fixed:names|tb_fixed:board|tb_fixed:ptrgc|tb_fixed:scanptr) label="tb_fixed:$1"; shift;; esac
  if [ "$tb" = "tb_m4_top" ]; then label="tb_m4_top:$1"; shift; fi
  if [ -n "$FILTER" ]; then
    local hit=0
    for w in $FILTER; do case "$label" in *"$w"*) hit=1;; esac; done
    [ $hit -eq 1 ] || return
  fi
  local outs=()
  for n in "$@"; do outs+=("$D/p/$n.v"); done
  # board tops instantiate ECP5 hard blocks; stub them
  case " $* " in *ulx3s*) outs+=("scripts/ecp5_sim_prims.v");; esac
  # the SD loader is tested against a card, and the card is a model
  case " $* " in *sd_boot*|*m5_core*) outs+=("scripts/sd_card_model.v");; esac
  if ! iverilog $IVFLAGS -o "$VVP" "scripts/$tb.v" "${outs[@]}" 2>/tmp/iv.err; then
    echo "  BUILD FAIL  $label"; head -4 /tmp/iv.err; fail=$((fail+1)); failed="$failed $label"; return
  fi
  # run from the hex dir: the testbenches $readmemh CWD-relative names
  # 900s, not 300: the signed multiply (notes/21 postscript) makes
  # iverilog evaluate a real 64x64 signed product where it used to
  # zero-extend, and `tb_m3_top` pushes 33 ms of simulated time through
  # three ALUs. The DESIGN got smaller and faster; the SIMULATION of it
  # got slower, and a cap that turns that into a red line is a cap
  # reporting on itself.
  local out; out=$(cd $D/p && timeout $TBTIMEOUT vvp "$VVP" 2>&1)
  # tb_bench is a measurement harness, not a pass/fail TB: it prints a
  # BENCH line. A clean run is one that completed with fault=0, and the
  # cycle count is echoed so a drift against notes/18 is visible here.
  if [ "$tb" = "tb_bench" ]; then
    if echo "$out" | grep -q "fault=0"; then
      echo "  ok          $label   $(echo "$out" | grep -o 'cycles=.*')"; pass=$((pass+1))
    else
      echo "  FAIL        $label"; echo "$out" | tail -3 | sed 's/^/                /'
      fail=$((fail+1)); failed="$failed $label"
    fi
    return
  fi
  if echo "$out" | grep -q "_OK__"; then
    echo "  ok          $label"; pass=$((pass+1))
  else
    echo "  FAIL        $label"
    echo "$out" | grep -E "FAIL|TIMEOUT|ERROR" | head -8 | sed 's/^/                /'
    fail=$((fail+1)); failed="$failed $label"
  fi
}

ENG="name_table heap ser_unit deser_unit collector signal_table timer lit_pool barrel_engine barrel_seq seat_unit proc_table run_queue reg_window_ctx frame_ram_proc code_mem decode classify alu mailbox shape_hash send_unit"

run tb_alu_signed   alu
run tb_dbguart      dbg_uart
run tb_heap         heap
run tb_ser          ser_unit heap
run tb_roundtrip    deser_unit ser_unit heap
# `notes/26` bug 9: 525 lines of microSD loader that had never run.
# The card model is a real SPI-mode card; the image is three sectors, so
# a bundle straddles a sector boundary; the assertion is every bundle
# and pool word, word for word against `Encoding.image/2` (notes/34).
IVFLAGS='-DCARD_IMG="sdimg_bytes.hex"' run tb_sdboot sd_boot_sim
# the same image, the same parser, down one wire instead (notes/37) —
# including the line noise a debug cable actually carries
run tb_uartload     uart_loader
run tb_gc           collector heap ser_unit
run tb_rootwalk     root_walker
run tb_ring2        $ENG ring_link
# `notes/49` — one image, two engines, and a process created on the
# engine that was never booted. `duo` rather than two engines wired up
# in the testbench, because `N_ENG` is a param and a param is chosen on
# an instance.
IVFLAGS='-DRERUN' run tb_spawn2       duo
run tb_names2       duo
run tb_slink2       duo
run tb_mon2         duo
run tb_super2       duo
run tb_signals      signal_table
run tb_m4_shape     shape_hash
run tb_m4_mailbox   mailbox
run tb_m4_send      send_unit proc_table mailbox shape_hash
run tb_m3_pass2     proc_table run_queue
run tb_m3_pass3     barrel_seq
run tb_m3_pass4     reg_window_ctx
run tb_m3_pass5     frame_ram_proc
run tb_m3_pass5_int barrel_seq reg_window_ctx frame_ram_proc
run tb_m3_pass6     barrel_seq seat_unit proc_table run_queue reg_window_ctx
run tb_m3_pass7     barrel_seq seat_unit proc_table run_queue reg_window_ctx
run tb_m3_pass8     $ENG
run tb_m3_fib       $ENG
run tb_fixed        $ENG
IVFLAGS='-DIMG="heapprog.hex" -DEXP="heapprog_expect.hex"' run tb_fixed heapprog $ENG
# `notes/40` — the collector, in the engine. Four hundred iterations
# through a 128-cell semispace is twelve collections on the model, and
# the model's `out` stream is the expectation.
IVFLAGS='-DIMG="gcloop.hex" -DEXP="gcloop_expect.hex" -DPOOL="gcloop_pool.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DCYCLES=160000' run tb_fixed gcloop $ENG
# `notes/48` — the four ALU micro-ops that had been unit-tested since M2
# and never been through the ENGINE, plus `yield` and `unlink`, which
# were wired and exercised nowhere. Three notes running listed them as
# the cheapest thing on the board; this is the image that closes them.
IVFLAGS='-DIMG="bitwise.hex" -DEXP="bitwise_expect.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=2' run tb_fixed bitwise $ENG
# `notes/46` — FOUR processes allocating through one semispace, which is
# the program the per-process collector exists for. `gcloop` is one
# process and cannot show the difference: the engine has nobody else to
# run while it collects.
IVFLAGS='-DIMG="gcconc.hex" -DEXP="gcconc_expect.hex" -DPOOL="gcconc_pool.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DCYCLES=200000' run tb_fixed gcconc $ENG
# `notes/42` — a closure built, called, collected around, and called
# again. The second call is the one that matters: it happens after
# everything on the heap has moved.
IVFLAGS='-DIMG="funs.hex" -DEXP="funs_expect.hex" -DPOOL="funs_pool.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=120000' run tb_fixed funs $ENG
# ...and the two ways it goes wrong. 18 is `badfun`, 19 is `badarity`.
IVFLAGS='-DIMG="funbad.hex" -DEXP="funbad_expect.hex" -DWANT_FAULT=18 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=1 -DWANT_OCC=0' run tb_fixed funbad $ENG
IVFLAGS='-DIMG="funar.hex" -DEXP="funar_expect.hex" -DPOOL="funar_pool.hex" -DWANT_FAULT=19 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=1 -DWANT_OCC=0' run tb_fixed funar $ENG
# ...and the same feature written in Elixir rather than in slots: `fn`
# with a free variable, passed to another function as a value and called
# there, on both sides of a collection.
IVFLAGS='-DIMG="fnelixir.hex" -DEXP="fnelixir_expect.hex" -DPOOL="fnelixir_pool.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=120000' run tb_fixed fnelixir $ENG
# `notes/42` — maps: a literal built with literal indices, probed on the
# other side of a collection, and one filled through the latched index.
IVFLAGS='-DIMG="maps.hex" -DEXP="maps_expect.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=120000' run tb_fixed maps $ENG
# ...and the same feature in Elixir: literals, `maps:` calls, a map
# pattern, and a hundred and twenty functional updates in a row.
IVFLAGS='-DIMG="mapelixir.hex" -DEXP="mapelixir_expect.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=400000' run tb_fixed mapelixir $ENG
# `notes/43` — binaries: one built, read by byte, collected around, and
# written at an index the program computed.
IVFLAGS='-DIMG="bins.hex" -DEXP="bins_expect.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=120000' run tb_fixed bins $ENG
# ...and Elixir strings: `<>`, byte access, a literal in a pattern, and a
# `rest::binary` tail, through eighteen collections.
IVFLAGS='-DIMG="binelixir.hex" -DEXP="binelixir_expect.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=140000' run tb_fixed binelixir $ENG
# notes/50 — registered names on the CAM, and the recycling front end:
# the image itself is code the old compiler could not build
IVFLAGS='-DIMG="names.hex" -DEXP="names_expect.hex" -DWANT_OCC=0 -DWANT_DEATHS=2 -DWANT_FAULT=1 -DCYCLES=140000' run tb_fixed names $ENG
# `notes/44` — the board program: closures, maps, binaries and forty
# turns of an allocating loop, folded into one checksum byte because the
# debug UART carries only the LAST `out`. The netlist checks the whole
# stream; the board checks the byte. Same image both places.
IVFLAGS='-DIMG="board.hex" -DEXP="board_expect.hex" -DPOOL="board_pool.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=200000' run tb_fixed board $ENG
# `notes/46` — the oracle on the OTHER SIDE of a collection. `tb_fixed:ptr`
# compares raw pointer values and allocates four objects; these two ask
# the same question after the live data has moved, which is where the
# model and the gates disagreed about what a pointer even was.
IVFLAGS='-DIMG="ptrgc.hex" -DEXP="ptrgc_expect.hex" -DWANT_DEATHS=1 -DCYCLES=200000' run tb_fixed ptrgc $ENG
# ...and whether the Cheney SCAN follows every pointer the ROOT path
# does. A map and a binary hidden inside a tuple, with no other
# reference to either, through three collections.
IVFLAGS='-DIMG="scanptr.hex" -DEXP="scanptr_expect.hex" -DWANT_IDLE=1 -DWANT_OCC=0 -DWANT_DEATHS=1 -DCYCLES=200000' run tb_fixed scanptr $ENG
# The oracle itself: `out` of a raw heap POINTER, compared word-for-word.
# Impossible until the model moved to cell addressing (notes/26 bug 5) —
# every heap testbench before this one could only report immediates that
# had come back OUT of the heap.
IVFLAGS='-DIMG="ptr.hex" -DEXP="ptr_expect.hex"' run tb_fixed ptr $ENG
# The transmit half: `send` of a compound term, serialised into flits
# and rebuilt on the far side. The sender's pointer and the receiver's
# must DIFFER — a copy, not a shared address — and every element must
# survive the round trip.
IVFLAGS='-DIMG="csend.hex" -DEXP="csend_expect.hex"' run tb_fixed csend $ENG
# `tailcall`, which every OTP loop is made of. 200 iterations on
# purpose: the register stack is 64 frames, so anything under 65 would
# pass whether the op reuses the window or pushes one.
IVFLAGS='-DIMG="tailloop.hex" -DEXP="tailloop_expect.hex" -DPOOL="tailloop_pool.hex"' run tb_fixed tailloop $ENG
# A gen_server: receive a request, reply, call yourself with new state.
# Needs tailcall, a copying send, AND application atoms — a program was
# limited to the eighteen reserved ones until the atom table landed, so
# `{From, inc}` could not be written at all.
IVFLAGS='-DIMG="srv.hex" -DEXP="srv_expect.hex" -DPOOL="srv_pool.hex" -DALLOW_FAULT' run tb_fixed srv $ENG
# List comprehensions and the `lists:` prelude, on the gates. Both are
# ordinary Erlang once lifted — a comprehension is a self-recursive
# function and so is `reverse/1` — so what this really tests is that
# `call`/`tailcall`/`cons` compose over a program the front end wrote
# rather than a person. `spawn_link` is NOT here: notes/30 records why.
IVFLAGS='-DIMG="otp2.hex" -DEXP="otp2_expect.hex" -DPOOL="otp2_pool.hex" -DALLOW_FAULT' run tb_fixed otp $ENG
# `spawn_link/3` and the process that ENDS BY RETURNING (notes/31).
# WANT_DEATHS=2 is the whole assertion: the child has to have exited on
# its own after `w/1` returned, or it would still be sitting there
# having re-entered `main`.
IVFLAGS='-DIMG="slink.hex" -DEXP="slink_expect.hex" -DPOOL="slink_pool.hex" -DWANT_DEATHS=2 -DWANT_OCC=0' run tb_fixed slink $ENG
# An ELIXIR module, on the netlist (notes/35). Compiled by the real
# Elixir compiler and lowered through Core Erlang, so this asserts the
# whole route: spawn/send/receive between two processes, the Erlang
# prelude's lists:sum and lists:reverse over heap cons cells, and a
# `try` catching an overflow — four values, against the model.
IVFLAGS='-DIMG="elixir.hex" -DEXP="elixir_expect.hex" -DPOOL="elixir_pool.hex" -DWANT_IDLE=1' run tb_fixed elixir $ENG
# `erlang:halt/0` stops the VM, not one process (notes/33). The child
# has provably run and is provably still runnable when `main` halts, and
# it never ends on its own — so "the machine is idle with a live process
# in it" is a statement only a VM-wide halt can make true.
IVFLAGS='-DIMG="vmhalt.hex" -DEXP="vmhalt_expect.hex" -DPOOL="vmhalt_pool.hex" -DWANT_IDLE=1 -DWANT_OCC=1 -DWANT_DEATHS=1' run tb_fixed vmhalt $ENG
# `try`/`catch` in the gates (notes/32): the deep landing, the shallow
# one, and the happy path where `try_end` must leave the result alone.
IVFLAGS='-DIMG="try.hex" -DEXP="try_expect.hex" -DPOOL="try_pool.hex" -DWANT_DEATHS=1 -DWANT_OCC=0' run tb_fixed try $ENG
# 30 levels of non-tail recursion into a 15-frame store: the fault the
# frame store has been able to raise since pass 5 and nobody read.
IVFLAGS='-DIMG="deep.hex" -DEXP="deep_expect.hex" -DPOOL="deep_pool.hex" -DWANT_FAULT=8 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=1 -DWANT_OCC=0' run tb_fixed deep $ENG
IVFLAGS='-DIMG="ldcfail.hex" -DEXP="ldcfail_expect.hex" -DPOOL="ldcfail_pool.hex" -DWANT_FAULT=10' run tb_fixed ldcfail $ENG
# links: a death takes its peers with it, unless they trap
IVFLAGS='-DIMG="super_kill.hex" -DEXP="super_kill_expect.hex" -DWANT_FAULT=3 -DWANT_FAULT_COUNT=2 -DWANT_DEATHS=2 -DWANT_OCC=0' run tb_fixed super_kill $ENG
IVFLAGS='-DIMG="super_trap.hex" -DEXP="super_trap_expect.hex" -DWANT_FAULT=3 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=1 -DWANT_OCC=1 -DWANT_MB_HASH=156 -DWANT_MB_LEN=4' run tb_fixed super_trap $ENG
# exit2: the target is killed by a SIGNAL naming `overflow` (5), and
# both witnesses now agree on that — the reason ProcTable recorded and
# the reason the fault port reports. This line used to read WANT_FAULT=0
# with a comment explaining that the port reports the X stage and a
# signal-killed process never faulted at X. That was the bug written
# down as an expectation (notes/26 #3); it is fixed, and so is this.
IVFLAGS='-DIMG="super_exit2.hex" -DEXP="super_exit2_expect.hex" -DWANT_FAULT=5 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=2 -DWANT_OCC=0 -DWANT_PT_REASON=5 -DWANT_PT_SLOT=1' run tb_fixed super_exit2 $ENG
# monitor: the watcher survives and is told, carrying its ref
IVFLAGS='-DIMG="super_mon.hex" -DEXP="super_mon_expect.hex" -DWANT_FAULT=3 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=2 -DWANT_OCC=0 -DWANT_MB_HASH=165 -DWANT_MB_LEN=5' run tb_fixed super_mon $ENG
# recv_waitt: the deadline expires, or the message beats it
IVFLAGS='-DIMG="super_tmo_hit.hex" -DEXP="super_tmo_hit_expect.hex" -DPOOL="super_tmo_hit_pool.hex" -DWANT_DEATHS=1 -DWANT_OCC=1' run tb_fixed super_tmo_hit $ENG
IVFLAGS='-DIMG="super_tmo_miss.hex" -DEXP="super_tmo_miss_expect.hex" -DPOOL="super_tmo_miss_pool.hex" -DWANT_DEATHS=1 -DWANT_OCC=1' run tb_fixed super_tmo_miss $ENG
# the other half of trap_exit: the supervisor READS the exit signal
IVFLAGS='-DIMG="trapread.hex" -DEXP="trapread_expect.hex" -DPOOL="trapread_pool.hex" -DWANT_FAULT=3' run tb_fixed trapread $ENG
# A REAL ERLANG MODULE: process_flag(trap_exit,true), spawn, link,
# receive with a tuple pattern and an after clause, exit/2. Compiled by
# `PicoBEAM.Erl` from source, checked against the model's own outputs.
# The clause only matches because the deserialiser rebuilt the
# {'EXIT', From, Reason} the dying child's signal left in the mailbox.
IVFLAGS='-DIMG="erlsup.hex" -DEXP="erlsup_expect.hex" -DPOOL="erlsup_pool.hex" -DWANT_FAULT=3 -DWANT_FAULT_COUNT=1 -DWANT_DEATHS=2 -DWANT_OCC=0 -DWANT_PT_REASON=3 -DWANT_PT_SLOT=1' run tb_fixed erlsup $ENG
run tb_m4_pingpong  $ENG
run tb_m4_evict     $ENG

# The board tops: ROM loader, demo selection, LED instrument and UART,
# with only the PLL stubbed. notes/15 set this rule at M2 — "simulate
# the top, not just the parts" — and then these three quietly stopped
# being run, drifted out of build (tb_m4_top predated btn3), and the
# fixed-point demo had to be checked on SILICON instead.
if [ $QUICK -eq 0 ]; then
# The whole two-engine board, power-up to answer (notes/36): the card
# handshake, one image into two code memories, both entry points out of
# the header, both engines running Elixir. It is slow — two engines in
# iverilog manage about fifty clocks a second — so it lives here with
# the other board tops rather than in the inner loop.
TBTIMEOUT=4000 IVFLAGS='-DCARD_IMG="elixir_bytes.hex"' run tb_m5_top m5_core_sim
TBTIMEOUT=900
run tb_m3_top       ulx3s_m3_top
run tb_m3_comb      ulx3s_m3_top
IVFLAGS='-DDEMO=0' run tb_m4_top pingpong ulx3s_m4_top
IVFLAGS='-DDEMO=1' run tb_m4_top evict    ulx3s_m4_top
IVFLAGS='-DDEMO=2' run tb_m4_top fixed    ulx3s_m4_top
fi
# the six benchmark images, each with its own expected op count
while read -r name nb ops; do
  [ -n "$name" ] || continue
  IVFLAGS="-DIMG=\"$name.hex\" -DNB=$nb -DOPS=$ops" run tb_bench "$name" $ENG
done < _emit/bench/manifest.txt

echo "================ $pass ok, $fail failed ================"
[ -n "$failed" ] && echo "failed:$failed"
[ $fail -eq 0 ] && echo "__TBS_ALL_OK__"
