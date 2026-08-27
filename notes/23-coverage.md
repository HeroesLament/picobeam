# 23 — Coverage, measured

Asked "how are we looking", and the only honest way to answer was to
count. This is that count, taken 2026-08-24, plus the four gaps it
found and the two that were closed on the spot.

## The gate

`scripts/run_tbs.sh` — 31 runs, all green. `scripts/run_tbs.sh quick`
skips the board tops and does 26 in ~90 seconds; the full gate takes
**9.5 minutes**, of which ~85% is the two board-top testbenches
simulating tens of milliseconds of real time through the whole design.

`mix test` — 44 tests, all green.

## Opcode coverage: 32 of 52 have executed

Measured by decoding every `.hex` image the testbenches load and
collecting the op bytes that actually appear.

**Executed (32).** add sub mul mulsr cmpeq cmplt istag ldi ldn arg nop
mov*, jmp bift biff call ret halt out self spawn send recv_start
recv_peek recv_take recv_wait cons hd tl mktup tset tget tarity.

**Implemented and unit-tested, but never in an executed program (7).**
`band` `bor` `bxor` `cmpne` `cmple` `lda` — the ALU micro-ops. Until
today `tb_alu_signed.v` exercised six of the seventeen `sel` values;
it now exercises all seventeen, so these are covered *at the unit* but
no program has ever run one through the engine. Cheap to close: a
bitwise/compare demo image.

**Implemented in the engine, never exercised at all (4).** `tailcall`
`recv_hash` `recv_skip` `yield`. These have Classify strobes, are bound
in `BarrelEngine`, and have no test. **This is the sharpest gap on the
list** — `tailcall` in particular, because it is the one control-flow
op that reuses a window instead of pushing a frame, and a bug in it
would look like a register-window bug three functions later.

**Not implemented in RTL at all (9).** `ldc` (needs `LitPool`, still
not instantiated), `link` `unlink` `monitor` `exit2` `trapexit` — the
whole supervision mechanism `notes/13` designs and `M1` models —
`fail`, `recv` (the fused form; the family is implemented), and
`recv_waitt` (needs the timer wheel). These are known milestones, not
coverage debt.

## RTL modules

18 of 31 are exercised by the gate. Of the 13 that are not:

* **`ser_unit` (420 loc) and `deser_unit` (264 loc)** are tested
  standalone and against each other, but are not reachable from a board
  top — that is the pending engine integration, not a coverage gap.
* **`sd_boot` (525 loc)** is the SD-card loader from `notes/11`.
  Unfinished and untested. The largest genuinely untested thing in the
  tree.
* **`lit_pool` (37 loc)** is unimplemented along with `ldc`.
* **The other 2,478 lines are dead M2 code**: `engine` (730),
  `reg_window` (492), `sequencer` (268), `reg_window_ram` (260),
  `reg_window_narrow` (246), `ulx3s_top` (236), `demo_fib` (139),
  `frame_ram` (107) — every one superseded by its M3 replacement
  (`barrel_engine`, `reg_window_ctx`, `barrel_seq`, `frame_ram_proc`,
  `ulx3s_m3_top`). They are not gaps; they are weight, and they make
  every coverage ratio in this note look worse than the machine is.
  Deleting them is a decision, not a task — the M2 sequential engine is
  the thing M3's numbers were measured against.

## Model coverage: 70.9%

    Erl      60.6%     Machine  87.1%     Term   93.1%
    ISA      84.8%     Asm      88.9%     Serial 86.5%

**`PicoBEAM.Erl` at 60.6% is the number that matters here.** It is the
Core Erlang front end — the thing that turns a user's program into
bundles — and it is the least tested component in the repo. Its
untested 40% is mostly the `unsupported/2` paths, which is to say: the
v1 subset's *refusals* are largely unproven. `notes/14` claims "the v1
subset fails loudly"; that claim currently rests on a handful of tests.

The RTL modules show 0% because coverage measures the elaboration-time
Elixir, not the gates — the netlists are covered by iverilog instead,
and no tool joins the two views. Worth knowing before reading that
table as a whole-project number.

## Silicon coverage

Six things have run on the board: `fib(10)`, DemoSpawn, two concurrent
recursions, 1000 spawns / 1001 deaths / occ=0, ping-pong, eviction, and
the fixed-point Hermite self-check. Sim and silicon have agreed at
every step of M2–M4, including on two bugs.

Nothing from `notes/22` has been on silicon: the heap is in the
bitstream (it synthesised, it placed, it closed timing) but no board
demo exercises a heap op, and the serialiser is not in the bitstream at
all.

## Two gaps closed while counting

**The board tops had fallen out of the gate.** `notes/15` set the rule
at M2 that made first silicon hold no surprises — *"simulate the top,
not just the parts"* — and then `tb_m3_top`, `tb_m3_comb` and
`tb_m4_top` quietly stopped being run. By the time anyone looked,
`tb_m4_top` could not even build: it predated `btn3`. The EHXPLLL stub
they need had only ever existed inside an ad-hoc `iverilog` command
line and was never committed, which is *why* they fell out — a
testbench that cannot be run by the gate will not be run at all.

The stub is now `scripts/ecp5_sim_prims.v` and all three run, the M4
one across all three demos. That means **the fixed-point demo's `0xA3`
self-check is now verified in simulation** — the thing that previously
required building a throwaway bitstream that defaulted to demo C,
flashing it, and reading the UART.

**`tb_m3_comb` was failing on a calibration, not a property.** Its
"seat LED carries sustained traffic" check asserted `> 2000` strobes;
the run now produces 1833–1988, because the demo ROM grew from 64
bundles to 128 and the boot sequence with it. The real instrument — all
four seats within 25% of each other, the 1/T comb — passed the whole
time. The threshold is now a floor with its reasoning attached rather
than a number tuned to one run.

## What I would do next, in order

1. **`tailcall`, `recv_hash`, `recv_skip`, `yield`** — four ops that
   are wired and have never run. One demo image covers all four.
2. **The serialiser into the engine, then onto silicon.** It is the
   only large piece that is proven in isolation and unproven in place.
3. **`PicoBEAM.Erl`'s refusals.** A table-driven test that feeds it one
   program per unsupported construct and asserts the error. Cheap, and
   it converts a claim in `notes/14` into a fact.
4. **Decide about the 2,478 lines of M2 RTL.** Keeping them is
   defensible; leaving the decision unmade is not.
