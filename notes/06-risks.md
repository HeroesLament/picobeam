# 06 — What will hurt

Ordered by how much. The first one is not a risk, it is a blocker.

## BLOCKER — the simulator cannot simulate a processor

**EHDL's simulator runs at ~4 ticks/s** on `HelloBoard.Top`. At that rate:

- one 9600-baud UART bit at 48 MHz (5,000 ticks) = **21 minutes**
- one byte (50,000 ticks) = **3.5 hours**
- a one-million-cycle benchmark = **69 hours**

You cannot develop a processor against that. Even a modest 1000× improvement
gets a megacycle run to four minutes, which is the difference between this
project being possible and not.

The diagnosis is already written down in `../ehdl/AGENTS.md` and it is not a
mystery: `_top_` holds **40,455 of the design's 40,747 ops**, of which 40,361
are combinational, and `build_env/1` materialises the entire 40,770-signal ETS
table into a map on **every clock edge** — 87% of all reductions. It does this
to compute cross-entity comb that `Hw.Sim.Clock` has since gained
`cross_settle_ops`/`cross_settle_inputs` to compute inline in about nine ops.
The retention was never removed.

The fix is ranked by confidence in that file; item 1 (stop `_top_` evaluating
its full comb set per edge — use `copy_needed_ops/4` as every other entity does)
is claimed to be most of the win. **Do item 1 and measure before doing anything
else.**

Method note, also from that file: per-process reduction deltas are the cheap
tool, and they need no profiler — this Erlang build ships no `tools`
application, so `:eprof` and `:fprof` are both unavailable.

## Then, in rough order of cost

### Elaborator atom exhaustion, made worse by exactly this design

EHDL's test suite already needs `ERL_FLAGS="+t 8000000"` because something mints
atoms per elaboration — probably generated signal names. A `generate` over nine
engines, each a CPU's worth of signals, multiplies that by an order of
magnitude.

**This risk is specific to the elastic-fabric idea.** It should be probed at M1
with a trivial replicated component, not discovered at M6 with a real one. If it
does not scale, Bet 4 needs rethinking and it is much cheaper to know that
before the engine exists.

### No Lattice primitives in EHDL's stdlib

`lib/hw/std/xilinx/` has fourteen wrappers — `BUFG`, `IBUFDS`, `IDDR`, `OBUF`,
`PS7`, `DSP48E1`, `MMCME2_BASE`, `PLLE2_BASE`, `ODDR`, `OBUFDS`, and more. There
is **no `lattice/` directory at all.** Every memory in this design rides on
`memory` inference plus the `ram_style` attribute the emitter sets. (The emitter
does know about ECP5 — there's a comment in `lib/hw/emit/verilog.ex` about a
registered-read memory mapping to a real EBR and yosys's `memory_libmap` /
`memory_bram` passes honouring the attribute.)

Bet 3 and the **entire GC argument** depend on true dual-port EBR with
independent ports. **Verify that inference produces `DP16KD` and not distributed
LUT-RAM before designing around it.** Half a day of work, and it gates the
architecture. This is Probe A in `AGENTS.md`.

### Single-process latency is T× worse

The barrel is the right trade and it will still feel bad the first time you
benchmark `nrev` against Actora and lose by 4×. The decision is recorded in
`00-charter.md`: the benchmark is aggregate throughput and worst-case latency,
not single-process speed. **Do not relitigate it at M3.**

### The ULX3S ships a −6 speed grade

The slowest ECP5. Plan **50 MHz** for a design with tag-decode → ALU →
stack-write in one stage; be pleased at 75. The clocking itself is solved —
`ULX3S.PLL` already produces an exact 48 MHz (CLKI_DIV=25, CLKFB_DIV=48) and a
216 MHz CLKOS from the 25 MHz oscillator — but the critical path will not be.

Note also that no authoritative soft-core Fmax citation for ECP5 + nextpnr
exists; LiteX's ULX3S target defaults to 50 MHz. Do not plan above that without
running nextpnr on real RTL.

### "The instrument is the device under test," three times

EHDL's own notes record this happening three times, and it is the failure mode a
processor project is most exposed to.

The counter is the one ECOMP itself used in 1999: **a hardware model of the
processor, developed in Erlang.** Write the ISA as a plain Elixir interpreter at
M1, run the compiler and the benchmarks against it, then co-simulate RTL against
it instruction by instruction. In this project the reference model is nearly
free, because the compiler, the simulator, the HDL and the model are all the
same language.

### Muxes and `defhw` — the two bugs that already bit

Both are guarded now. **Do not remove the guards**, and treat a decoder that
simulates correctly and behaves wrongly on the board as a *known failure mode
with a known cause* rather than a mystery.

1. **`defhw` inlining is a fixpoint.** A `defhw` whose body calls other
   `defhw`s — including from inside an `hdl_case` branch, which is the ordinary
   way to write a register-write dispatcher — used to leave `:defhw_call` nodes
   that nothing downstream matched. `find_all_assigned` did not see them,
   `build_mux_tree` never visited them, the emitter had no clause. The result
   elaborated, validated, synthesised, placed, routed, and **silently dropped
   every write on real hardware.** Guards: `assert_no_defhw_calls!/2`,
   `check_defhw_cycle!/2`, and `elaborate_fsm/8` inlining before
   `find_all_assigned/1` collects reset targets.

   **A register file written through `defhw` tag helpers is exactly that
   shape.** This is the single most likely way picoBEAM gets silently broken.

2. **`Ops.Mux` is first-match-wins, everywhere — and once was not.**
   `emit_mux_always` (>2 arms) used to emit a flat run of independent `if`s over
   a pre-assigned default, making the **last** match win. A trailing always-true
   arm clobbered every specific arm **in hardware only**. An instruction decoder
   is a priority mux over exactly that shape. The load-bearing tests are in
   `hdl_case_test.exs` and they assert on **emitted Verilog text**, not
   simulation — because simulation was always right.

### Compiler scope creep

Core Erlang in, picoBEAM ISA out, written in Elixir via
`:compile.file(f, [:to_core])`. The v1 subset is in `00-charter.md`. Every
excluded feature will look tempting and each is a month. picoJava is the
cautionary tale: 27,500 logic cells, cancelled.

## Risks we do *not* have, because the target is ECP5

Worth stating so nobody imports them from EHDL's notes, which are mostly about
the Xilinx path:

- `-nocarry` is an openXC7 constraint, not a nextpnr-ecp5 one. Carry chains are
  available.
- The ILOGIC/`IDDR` prjxray gap, `DIFF_TERM` being silently ignored, and the
  seed-dependent BUFG routing (four consecutive revisions needing seeds 2, 1, 5
  and 25; one revision where seeds 1–23 all failed) are all Xilinx-side.
- nextpnr-ecp5 does report timing, unlike the openXC7 flow where `--freq 100` is
  nominal and "it routed" does not mean "it meets timing."

The ECP5 path is the mature one. That is why it was chosen.
