# AGENTS.md — picoBEAM

An Erlang machine in FPGA fabric, written in EHDL, targeting the Lattice
ECP5-85F on a ULX3S. **It runs.** Elixir compiles to bundles, the bundles run
on the barrel, and the barrel has been placed, routed and executed on a board.
This file is the handoff.

## Read in this order

1. `README.md` — what works, with the numbers, and how to run it.
2. `notes/00-charter.md` — what counts as success, and what does not.
3. `notes/03-architecture.md` — terms, engine, ring, GC, supervision.
4. `notes/26-known-bugs.md` — **required.** Thirty-eight entries, several of
   them the same mistake made again. The recurring shapes are worth more than
   the individual fixes.
5. `notes/53-the-smp-correction.md` and `notes/54-supervision-crosses-the-ring.md`
   — the machine is ONE NODE: an engine is a scheduler, not a node, and the
   registry and every supervision signal now behave accordingly. `notes/12`'s
   postscript records the doctrine being corrected.
6. `../ehdl/AGENTS.md` — **required.** picoBEAM is written in EHDL and inherits
   every one of its sharp edges. Do not skip it.

The notes are the project's memory and they are append-only in spirit. When a
decision is reversed, the reversal goes *next to* the original: `notes/30` has a
diagnosis that was confidently wrong left standing beside its correction, and
`notes/26` entry 24 does the same. Those are the most useful paragraphs in the
file.

## Where things are

| | |
|---|---|
| This repo | `~/src/picobeam` |
| EHDL | `~/src/ehdl` — the HDL, its stdlib, its simulator, its linter |
| ECOMP source deck | `erlang.org/euc/00/processor.ppt` (distilled in `notes/01`, scored in `notes/45`) |
| Board | ULX3S, `LFE5U-85F-6BG381C` |
| Toolchain | yosys + nextpnr-ecp5 + prjtrellis; `fujprog` |

## The gate

```sh
bash scripts/run_tbs.sh quick
```

Emit every component, run `check_drivers.py` over the emitted Verilog,
regenerate every test image from the reference model, simulate, compare gates
against model word for word. **66 testbenches, and it is the only thing that
counts as evidence.** `mix test` is the model's own 75; a green model and a red
gate means the model is wrong.

Two process rules, both learned expensively:

- **Never edit a script while it is running.** bash re-reads from a byte offset
  and executes the shifted remainder. It looks like the script has gone insane.
- **Kill by explicit PID and verify.** `pkill -f "run_tbs.sh"` matches the
  command line you are typing it from.

## Non-negotiable constraints

These are decisions, not preferences. Changing one changes the architecture, so
argue in `notes/08-open-questions.md` rather than in code.

- **No shared heap.** Engines never share memory. Messages are copied. If you
  find yourself wanting a cross-engine pointer, the design is wrong, not the
  constraint. This bet paid off twice: because `send` and `spawn` both copy, no
  pointer is ever held by two processes, which is the whole reason the collector
  can stop one process instead of the world with no barrier (`notes/46`).
- **The PID carries its engine index.** `send` must not consult a table.
- **The benchmark is aggregate throughput and worst-case latency, not
  single-process speed.** The barrel makes one lonely process T× slower. That
  trade was made deliberately.

One constraint has been **retired by measurement**, and it is worth knowing why.
It used to read: *"The collector lives on the heap BRAM's second port. If the
mutator can ever stall for GC, the central claim is gone."* The collector does
live there — and the mutator stalls anyway, because the ROOTS live in the
register file and the frame RAM, and reading them stops the process that owns
them. `notes/41` measured 8% of wall clock; `notes/46` cut the longest pause
3.8× and did not cut the total. Zero is the target and is not the number. A
constraint that has been falsified is more useful stated than deleted.

## The v1 subset, as it actually stands

Atoms, signed 32-bit fixnums (overflow traps, never wraps), tuples, lists, PIDs,
refs, **closures**, **maps** (and structs behind them), **binaries and
strings**. `spawn`, `send`, the full selective-receive family, `link`,
`monitor`, `exit/2`, `trap_exit`, timers, `try`/`catch`, tail calls, list
comprehensions, `register`/`whereis`/`unregister` (node-global — `notes/50`,
`notes/53`), and a `lists:`/`maps:`/`binary:` prelude written in Erlang. All
of it works ACROSS ENGINES: spawn placement is round-robin over the ring
(`notes/49`), names resolve node-wide, and links, monitors and `exit/2`
follow their targets to the other engine (`notes/54`).

Not: floats, bignums, distribution (which now means MULTI-BOARD — a second
ULX3S on a wire, `notes/53` §4), hot code loading, ETS,
external IO beyond the debug UART. Maps and binaries were on this list as "each
of those will look tempting and each is a month"; they took rather less, and
`notes/42` and `notes/43` say what they cost.

The sharpest practical limit is not on that list: **sixteen registers per
window** — but `notes/50`'s recycling front end (use-count liveness, reuse at
last read) means ordinary Elixir now fits. `new_reg` raises only past sixteen
LIVE values, and the workaround is still splitting the function.

## Conventions

- Elixir modules are `PicoBEAM.*` under `lib/pico_beam/`.
- A claimed bug must be demonstrated by reverting the fix and watching a test
  fail. When the test passes either way, there was no bug.
- Every number in the notes is either quoted from a cited source or marked as an
  estimate. Keep that distinction.
- A finding gets a note. The notes are numbered, and the number is the order
  things were learned in, not the order they matter in.

## Traps that already exist, inherited from EHDL

Read `../ehdl/AGENTS.md` for the full list. These are the ones a processor
design walks straight into, plus the ones this project found the hard way.

1. **`defhw` inlining is a fixpoint, and once was not.** A `defhw` whose body
   calls other `defhw`s used to leave `:defhw_call` nodes that nothing
   downstream matched — the design elaborated, validated, synthesised, placed,
   routed, and **silently dropped every write on real hardware.**
   `assert_no_defhw_calls!/2` guards it. Do not remove the guard.
2. **`Ops.Mux` is first-match-wins, and once was not in synthesis only.** An
   instruction decoder is a priority mux. The load-bearing tests in
   `hdl_case_test.exs` assert on emitted Verilog text for this reason.
3. **A child's PORT name that matches a net in the parent is silently MERGED
   with it** — two continuous drivers on one wire, and the `x` surfaces modules
   away from the collision. `scripts/check_drivers.py` reads the emitted output
   and is in the gate. `notes/41` has the day it cost.
4. **EHDL reproduces Verilog's self-determined width rule.** `x + 1` takes `x`'s
   width, not the target's, so `128 + 128` in an eight-bit add is zero. Widen
   before adding. This has now bitten four times, in four different modules, and
   `heap.ex`'s moduledoc explains it at the site.
5. **Unconnected inputs float to `x`**, and take every branch that reads them
   with them. Every testbench ties off every input. Adding a port to a component
   means visiting its testbenches.
6. **`param` is constant-folded at elaboration** and emitted as `localparam`.

## The recurring failure, which is not an EHDL problem

**A fact decided in one place and copied into another.** `notes/26` has it six
times: cells versus words, the space bit, the forwarding tag, the closure arity,
`total - 1` against `total - nfree`. It always looks like a hardware bug and it
never is.

The second recurring shape is newer and sharper: **a signal named for what is
happening, used for what is safe.** `gc_active` meant "a collection is running"
and was used to mean "the pipeline is not using this port". Under a
stop-the-world collector those were the same statement. `notes/26` entry 27.

## "The instrument is the device under test"

EHDL's notes record this happening three times. The counter is the one ECOMP
itself used in 1999: *a hardware model of the processor, developed in Erlang.*

The ISA is a plain Elixir interpreter (`PicoBEAM.Machine`), every test image is
generated by running the real program on it, and the netlist is compared against
its output word for word. In this project the reference model is nearly free,
because the compiler, the simulator, the HDL and the model are all the same
language. It is the only thing standing between you and debugging a processor
through an LED.

Two consequences worth stating:

- When model and gates disagree, **neither is presumed right.** `notes/46`
  found a case where both were self-consistent and had disagreed about what a
  pointer meant for four milestones.
- Build a **baseline tree** when a bug might be a regression: a second checkout
  at the last known-good state, emitted and simulated side by side. `notes/41`
  and `notes/46` both used it and both times it turned an argument into a
  bisect in ten minutes.

## Where the work is

`notes/45` scores picoBEAM against ECOMP row by row and says it plainly: deeper
than ECOMP on what an Erlang machine *is*, nowhere near on what one has to
*hold*. In order:

1. **`call_ext` and an export table.** One module is not a system. `notes/42`
   designs BEAM's two-version rule; nothing implements it.
2. **ETS**, whose natural home the SMP correction made obvious: a shared
   node-level unit, like the registry (`notes/53`).
3. **Multi-board distribution** — the promoted meaning of the word: a node id
   above the engine id, the ring's wire format on a real wire.

(Registers, cross-engine spawn, and `register`/`whereis` led this list;
`notes/50`, `notes/49`, and `notes/53`/`notes/54` retired them.)

And on the collector: `notes/46` is incremental, not concurrent. The pause is
one process's live set rather than the engine's. Taking it to zero means
relaxing the freeze one port at a time, and that note says which ports and in
what order.
