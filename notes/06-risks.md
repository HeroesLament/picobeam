# 06 — What will hurt

Ordered by how much. The first one is not a risk, it is a blocker.

## ~~BLOCKER~~ — RESOLVED. The simulator now runs at ~350 ticks/s

Fixed as M0, in EHDL (`Hw.Sim.Schedule` + `Hw.Sim.Entity`): 4 → **344–362
ticks/s (~87×)** on `HelloBoard.Top`. A megacycle benchmark is now ~47
minutes, a 115200-baud UART byte ~13 s. Equivalence against the legacy path
verified by reg-next diff (94/94 identical) and 480-tick lockstep (0
divergent signals); the legacy path survives behind `HW_SIM_TOP_FULL=1`.
Full record, including three latent EHDL bugs surfaced along the way, in
`../ehdl/AGENTS.md`.

Still true: ~350 ticks/s is not fast enough for M3+ inner development loops.
The remaining cost is genuinely distributed across entities, so the next
order of magnitude is the Rust NIF backend (`Hw.Sim.Backend.Nif` — exists,
unused by `Hw.Sim.start`). That is an optimisation to schedule, not a
blocker to clear.

The original diagnosis, kept for the record:

## (historical) BLOCKER — the simulator cannot simulate a processor

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

### Elaborator atom exhaustion — PROBED, RETIRED

Probe B ran early (`../ehdl/_prim/probe_b.exs`): elaborating a small engine
costs +183 atoms, a 9× fabric of it +306 more, and re-elaborating the same
fabric costs **+0** — EHDL's Gensym is a deterministic per-elaboration
counter, so the same design mints the same names and atoms are only paid
once. Even the default 1M table has four orders of magnitude of headroom.
Bet 4 is safe from this side.

Two adjacent findings from the same probe, worth more than the retired risk:

- **`generate` cannot replicate `instance` declarations** — its body goes
  through `Parse.parse_statements`, so it replicates comb statements only.
  The fit-model sketch of `generate ... instance ...` does not parse today.
- **A compile-time `for` comprehension over `wire`/`instance` works** — a
  component body is ordinary Elixir, and module attributes accumulate inside
  the loop. Bet 4's "shape is a computed value" mechanism therefore exists
  with no DSL work: `for i <- 0..(n-1) do wire(...); instance(...) end`,
  proven in the probe.

### No Lattice primitives in EHDL's stdlib — PROBED, the part that gates us is CONFIRMED

There is still no `lattice/` directory, but Probe A settled the question that
mattered (`../ehdl/_prim/probe_a.exs`, `probe_a2.exs`): a 512 × 36 `memory`
with `sync_read:` — exactly one deep-configured EBR, picoBEAM's term width —
synthesises through yosys `synth_ecp5` to **exactly one `DP16KD` cell and
zero other logic**, in both shapes that the architecture needs:

- single clock, write port + independent sync-read port (heap/engine idiom);
- two clocks, write on `wr_clk`, read on `rd_clk` (mailbox/CDC-inside-BRAM
  idiom).

No distributed LUT-RAM anywhere. Bet 1's memory substrate is real.

Three residual gaps, now known rather than suspected:

1. **Emitter reserved-word bug:** memory names are emitted verbatim, and
   `buf` is a Verilog primitive keyword — `Hw.StreamBRAMFIFO` cannot be
   emitted standalone today. picoBEAM memories get non-keyword names until
   the emitter escapes or rejects them.
2. **One write site per memory.** `memory` + `on` expresses 1W + 1R. Bacon's
   collector wants both ports read/write (mutator A, collector B). This is
   the actual DSL work item that gates M5 — smaller than it sounds, but it
   exists.
3. **The simulator cannot model memory writes** (the standing MemWrite
   item), so anything with a written `memory` is synthesis-only for now.
   M2's engine either fixes that or keeps its state in registers during
   bring-up.

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
