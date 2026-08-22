# AGENTS.md — picoBEAM

An Erlang machine in FPGA fabric, written in EHDL, targeting the Lattice
ECP5-85F on a ULX3S. **Nothing is built yet.** This file is the handoff.

## Read in this order

1. `README.md` — the one-paragraph version and the four bets.
2. `notes/00-charter.md` — what counts as success, and what does not.
3. `notes/07-roadmap.md` — M0 is the only thing that matters right now.
4. `notes/06-risks.md` — read before writing any RTL. Three of these have
   already cost this codebase's sibling real time.
5. `../ehdl/AGENTS.md` — **required.** picoBEAM is written in EHDL and inherits
   every one of its sharp edges. Do not skip it.

## Where things are

| | |
|---|---|
| This repo | `~/src/picobeam` |
| EHDL | `~/src/ehdl` — the HDL, its stdlib, its simulator, its linter |
| ECOMP source deck | `erlang.org/euc/00/processor.ppt` (distilled in `notes/01-ecomp-2000.md`) |
| Board | ULX3S, `LFE5U-85F-6BG381C` |
| Toolchain | yosys + nextpnr-ecp5 + prjtrellis; `openFPGALoader` or `fujprog` |

## The rule that outranks all the others

**M0 comes first and nothing starts before it is measured.**

EHDL's simulator runs at **~4 ticks/s** on `HelloBoard.Top`. At that rate a
one-million-cycle benchmark takes **69 hours**. You cannot develop a processor
against it. `../ehdl/AGENTS.md` has the measurement, the diagnosis (`_top_`
holds 40,455 of 40,747 ops and re-evaluates the whole design every clock edge —
87% of all reductions — to compute cross-entity comb the clock already computes
in nine ops) and the fix ranked by confidence. Item 1 alone is claimed to be
most of the win.

Do not start M1 until you can state a ticks/s number, before and after.

## Non-negotiable constraints

These are decisions, not preferences. Changing one changes the architecture, so
argue in `notes/08-open-questions.md` rather than in code.

- **No shared heap.** Engines never share memory. Messages are copied. If you
  find yourself wanting a cross-engine pointer, the design is wrong, not the
  constraint.
- **The PID carries its engine index.** `send` must not consult a table.
- **The collector lives on the heap BRAM's second port.** If the mutator can
  ever stall for GC, the central claim is gone.
- **v1 subset, and it is austere on purpose.** Atoms, 32-bit fixnums, tuples,
  lists, PIDs, funs, `spawn`/`send`/`receive`/`link`/`monitor`/`exit`. No
  floats, no bignums, no maps, no binaries or bitstring syntax, no distribution,
  no hot code loading. Each of those will look tempting and each is a month.
  picoJava is the cautionary tale; see the README.
- **The benchmark is aggregate throughput and worst-case latency, not
  single-process speed.** The barrel makes one lonely process T× slower. That
  trade was made deliberately. Do not relitigate it at M3.

## Conventions

- Elixir modules are `PicoBEAM.*` (files under `lib/hw/pico_beam/` if this ever
  merges into EHDL; `lib/pico_beam/` while standalone). `Macro.underscore/1`
  gives `pico_beam`, which is what you want.
- Notes are numbered and append-only in spirit: when a decision is reversed,
  record the reversal and the evidence *next to* the original rather than
  deleting it. `../ehdl/AGENTS.md` does this and the retractions are the most
  useful paragraphs in the file.
- A claimed bug must be demonstrated by reverting the fix and watching a test
  fail. When the test passes either way, there was no bug. (Also inherited from
  EHDL's notes, where it is written down because it was learned the hard way.)
- Every number in these notes is either quoted from a cited source or marked as
  an estimate. Keep that distinction. The fit table's EBR column is arithmetic;
  its LUT column is extrapolation at ±50% until M2 produces a real nextpnr
  report.

## Traps that already exist, inherited from EHDL

Read `../ehdl/AGENTS.md` for the full list. These three are the ones that a
processor design walks straight into:

1. **`defhw` inlining is a fixpoint, and once was not.** A `defhw` whose body
   calls other `defhw`s used to leave `:defhw_call` nodes that nothing
   downstream matched — the design elaborated, validated, synthesised, placed,
   routed, and **silently dropped every write on real hardware.** A register
   file written through `defhw` tag helpers is exactly that shape.
   `assert_no_defhw_calls!/2` guards it now. Do not remove the guard.
2. **`Ops.Mux` is first-match-wins, and once was not in synthesis only.**
   `emit_mux_always` used to make the *last* arm win, so a trailing catch-all
   clobbered every specific arm — in hardware, never in simulation. An
   instruction decoder is a priority mux. The load-bearing tests in
   `hdl_case_test.exs` assert on emitted Verilog text for this reason.
3. **Atom-table exhaustion during elaboration.** EHDL's suite already needs
   `ERL_FLAGS="+t 8000000"` because something mints atoms per elaboration,
   probably generated signal names. A `generate` over nine engines, each a
   CPU's worth of signals, multiplies that. **This risk is specific to
   picoBEAM's elastic-fabric idea.** Probe it at M1, not at M6.

And one that is ours rather than inherited:

4. **There are no Lattice primitives in EHDL's stdlib.** `lib/hw/std/xilinx/`
   has fourteen wrappers; there is no `lattice/` directory at all. Every memory
   in this design rides on `memory` inference plus the `ram_style` attribute the
   emitter sets. Bet 3 and the entire GC argument depend on true dual-port EBR
   with independent ports. **Verify that inference produces `DP16KD` and not
   distributed LUT-RAM before designing around it.** Half a day, and it gates
   the architecture.

## "The instrument is the device under test"

EHDL's notes record this happening three times. The counter is the one ECOMP
itself used in 1999: *a hardware model of the processor, developed in Erlang.*

Write the ISA as a plain Elixir interpreter at M1, run the compiler and the
benchmarks against it, then co-simulate RTL against it instruction by
instruction. In this project the reference model is nearly free, because the
compiler, the simulator, the HDL and the model are all the same language. That
is not a nice-to-have; it is the only thing standing between you and debugging a
processor through an LED.

## Immediate next actions

- [ ] **M0.** Fix EHDL's `_top_` per-edge re-evaluation. Measure ticks/s before
      and after with the per-process reduction-delta method described in
      `../ehdl/AGENTS.md` (no profiler available — this Erlang build ships no
      `tools` application, so `:eprof` and `:fprof` are both out).
- [ ] **Probe A.** Does `memory` inference give true dual-port `DP16KD` on
      ECP5 with independent read and write ports on one clock? Smallest
      possible test design, read the nextpnr report.
- [ ] **Probe B.** Elaborate a trivial component replicated nine times under
      `generate` and measure atom growth. Establish whether the fabric can be
      elaborated at all before designing it.
- [ ] **M1.** ISA as an Elixir interpreter + Core Erlang front end for the v1
      subset. Get the instruction set wrong here, where it is cheap.

Probes A and B are independent of M0 and of each other. Run them in parallel.
