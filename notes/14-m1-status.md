# 14 — M1 status: the reference model exists

Dated 2026-08-22. M1's brief was "the instruction set as an Elixir
interpreter, plus a Core Erlang front end for the v1 subset — get the ISA
wrong here, where it is cheap." It landed in five increments, all green:
**36/36 tests on OTP 24 and OTP 28**, and the demo exceeded the roadmap's
ask — not just a ring benchmark on the model, but a 9-worker token ring
**compiled from plain Erlang source**, placed one worker per engine,
deterministic to the cycle across runs.

## What exists

| Piece | File | Covers |
|---|---|---|
| Term model | `lib/pico_beam/term.ex` | 36-bit words, 4-bit tags, PID = engine/slot/serial, reserved atom indices (order is ABI) |
| ISA | `lib/pico_beam/isa.ex` | full v1 op set, pure/heap/system classes, per-slot read/write sets, the bundle contract as documentation |
| Assembler | `lib/pico_beam/asm.ex` | bundle-contract *enforcement*: cross-slot RAW/WAW rejection, ≤1 heap op, ≤1 system op last-slot, encoding ranges (12-bit imm/offset, r0–r15, 2048 bundles/fn) so nothing unencodable enters a program |
| Machine | `lib/pico_beam/machine.ex` | the reference semantics: N engines, T-context barrel, clean-on-call windows, ring with cycle-accurate wire latency, mailboxes + shape hash + selective-receive ops, per-engine Cheney GC, run queues + reduction-budget descheduling, links/monitors/exit signals over the ring |
| Front end | `lib/pico_beam/erl.ex` | Core Erlang (via `erlc +to_core`) → bundles, for the v1 subset |

Everything the notes had only asserted is now executable and tested:
determinism (two runs of the same program halt on the same cycle — asserted
in the ring, scheduler and Erlang-source tests), the Q9 lone-resident rule,
blocked-resident eviction, bounded wire latency (the 27-hop test pins
2 + hops + flits), GC survival of live data with mid-bundle allocation
coherence, and the dead-letter `noproc` rule.

## The letrec-goto finding (the good surprise)

OTP ≥ 23's compiler lowers `receive` in Core Erlang to a `letrec` marked
`letrec_goto`/`no_inline` wrapping four primops: `recv_peek_message` (a
two-value let: matched-flag + message), `remove_message`, `recv_next`,
`recv_wait_timeout`. These map **1:1** onto the receive ops the ISA already
had — `recv_peek`, `recv_take`, `recv_skip`, `recv_wait`/`recv_waitt` — and
the letrec-goto itself is exactly a label and a `jmp` (the front end
compiles it as such; no closures, no call overhead).

Read that as design validation of the strongest kind available at M1: the
OTP compiler and the hardware receive unit were designed independently and
meet at the same four-operation interface. The peek/skip/take cursor
machine in `03-architecture.md` is not an invention that needs a custom
compiler — it is what erlc already emits, waiting for hardware to exist.

One asymmetry, worth recording: **erlc's output never uses the shape-hash
filter.** The front end sets no `recv_hash`; generated code peeks every
message and match-tests in code. The 8-bit enqueue-time hash therefore
moves from "ISA contract" to **transparent hardware optimisation** — the
matcher may use it to skip obviously-non-matching messages during the
port-B scan, invisibly, and a future front end may opt in for
literal-headed receives (`{reply, Ref, X}`). Nothing in the programming
model depends on it. This is a *better* position than the one designed:
the bound in `05-determinism.md` (depth + |pattern|) holds without it, and
the hash can only tighten the average.

## The swap-cost tension (the honest wrinkle)

`05-determinism.md` claims swap-in at ~32 cycles, **jitter ±0**, justified
by "fixed context size / port width." Q1's clean-on-call register windows
broke that justification: a context's resident state is now its window
stack, and window count varies with call depth at the moment of
descheduling. Variable frames × fixed port width = variable swap time.
The model currently charges a *constant* `swap_cost` (default 32) and
carries a moduledoc flag saying so.

M2 must resolve it one of two ways, both acceptable, only one claimable:

1. **Bound resident frames.** The context holds at most k window frames in
   register-file RAM (the frame cache); deeper frames already live in
   frame RAM, spilled incrementally at call time. A swap then moves
   exactly k frames + fixed state — constant by construction, and the ±0
   claim survives. This is JOP's stack-cache discipline transplanted, and
   it is the leaning, because it also sizes the register file (the 6R3W
   cost of Q4a applies to the cache, not the depth).
2. **Restate the claim.** Swap-in becomes "≤ (frames × width + fixed)
   cycles, frames ≤ rstack depth" — still bounded, no longer ±0. Weaker,
   and it leaks call depth into the scheduling bound.

Until M2 picks, `05`'s table stands with this note as its asterisk.

## Decisions taken during implementation (now load-bearing)

- **Mailbox overflow kills the receiver**, reason `mailbox_full`, not the
  sender. The bounded mailbox is the receiver's contract; blocking the
  sender would couple send's latency bound to the receiver's behaviour,
  which is the one coupling the architecture exists to forbid. A receiver
  that dies of overflow notifies its supervisor through the ordinary path.
  (Deserves an 08 entry if ever revisited — backpressure alternatives were
  considered and rejected for the bound's sake.)
- **Past-end fetch is a fault**, reason `badarg`: falling off the end of a
  function body is always a compiler/assembler bug and dies loudly.
- **Proc-table exhaustion faults the spawner** (`system_limit` at 64
  slots/engine), not the machine.
- **Return-stack depth 64**, overflow reason `stack_overflow`.
- **Single assignment is enforced at runtime** in the model: reading a
  register the current window never wrote is a fault (`:uninit` in tests).
  Hardware won't check this; the model checks it so the front end's
  register discipline is proven before it costs gates.
- **Front-end register recycling**: registers are a per-window resource
  (r0–r15), so the front end recycles aggressively — clause-scoped
  allocation, full recycle across `seq` steps, `let` frees the bound
  value's temporaries (`max(saved, r+1)`). Without this, real functions
  exhausted 16 registers immediately; with it, every test program fits.
- **The v1 subset fails loudly.** List comprehensions, binaries, floats,
  funs/closures, maps, `after` with a non-zero body on selective receive,
  and anything else unsupported raise `Erl.CompileError` at compile time —
  never a silent miscompile.

## What M1 deliberately does not claim

Cycle counts in the model are *model-shaped*: a bundle per context turn,
constant `swap_cost`, wire latency 2 + hops + flits, GC billed zero cycles
to the mutator. These are the architecture's claims encoded as parameters,
not measurements — M2 makes the engine numbers real (LUT/fmax via
yosys+nextpnr), M5 must *earn* the zero-cost-GC and port-B claims, and M6
makes the ring numbers real. The model's job is semantics and relative
behaviour (determinism, ordering, bounds *shapes*), and co-simulation
against RTL from M2 onward is what keeps it honest.

## Next

M2, per `07-roadmap.md`: one engine, one context, in EHDL, synthesised.
First decisions on entry: Q5 (method cache — leaning build-now, twice
argued), the frame-cache bound k (which resolves the swap tension above),
and the register-file implementation (6R3W against ECP5 primitives —
likely LUT-RAM replication or banking; this is the sizing item Q1 bought).
