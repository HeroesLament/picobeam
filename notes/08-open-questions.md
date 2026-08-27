# 08 — Open questions

Forks not yet decided. Record the decision *and the reasoning* here when one is
taken; do not delete the alternative.

---

## Q1 — Stack machine, or ECOMP's register file with clean-on-call?

ECOMP's most Erlang-specific idea was *"clean register file upon start of new
function — no read/write-back of variables needed,"* which exploits single
assignment to eliminate all save/restore traffic. Actora went stack-machine
instead.

A stack machine is smaller, has better code density, and matches Core Erlang's
shape. A register file with clean-on-call is faster per instruction and is the
one idea from the deck that **nobody has re-tested in 26 years**.

**Leaning:** stack machine for v1 — but the register variant is the more
interesting experiment and it would be a shame never to run it. Possible
compromise: build the stack machine, and make the register variant an M2b
side-quest with the same reference model and the same benchmarks, so the
comparison is apples-to-apples and publishable either way.

---

## Q2 — Is T = 4 right, or should threads scale with engines?

T ≥ pipeline depth is the constraint that kills the bypass network, so T = 4 on
a 3-stage pipeline is the minimum that buys the whole prize. Larger T buys
resident processes at the cost of per-process latency and context BRAM. The
`:wide` fit takes T = 8.

**Leaning:** this should be a solver *output* rather than a knob, driven by a
target resident-process count. Requires knowing what that target is, which
requires knowing what picoBEAM is for beyond "it runs."

---

## Q3 — Ring, or something with a shorter diameter?

A ring makes send latency linear in engine count: fine at 9, bad at 32. A
crossbar is fine at 4 and unaffordable past 8. Past ~16 engines the answer is a
2D torus with Hoplite-style deflection routing — but that changes send's worst
case from "ring diameter" to "deflection bound," which is a **weaker determinism
claim.**

**The real question:** do we accept 16 engines as a ceiling in exchange for the
cleaner bound? Given that determinism is success criterion #1, probably yes.

---

## Q4 — What is the third bundle slot actually for?

ECOMP spent it on GC increments, which the port-B collector makes unnecessary.

**Proposal:** OTP housekeeping — one mailbox-enqueue step, one exit-signal hop,
or one timer-wheel tick per bundle. Makes supervision and timeouts
rate-guaranteed rather than best-effort.

**Alternative:** drop the bundle entirely for a plain 32-bit instruction and let
a small side-FSM do the housekeeping. Simpler, and loses the guarantee.

Decide at M1, because it is an ISA encoding decision and the reference model
bakes it in.

---

## Q5 — Whole-method cache at M2, or defer to M6?

JOP's method cache is the mechanism that makes its WCET story work — a miss can
only occur at call and return, so the analysis stays tractable. It is also a
large part of why JOP was small (1,831 LC) and picoJava was not (27,500 LC).

Building it at M2 means the calibration numbers reflect the real design.
Deferring it means M2 lands sooner but `Fit`'s constants get rewritten twice.

**Leaning:** build it at M2, because the naming argument says size discipline is
a v1 constraint, not a v2 optimisation.

---

## Q6 — Process placement policy for `SPAWN`

`SPAWN` has to choose an engine, and the choice is made in hardware. Options:

- **Round-robin.** Trivially fair, trivially deterministic, ignores load.
- **Least-loaded** (fewest resident contexts). Needs a load broadcast on the
  ring; adds a bounded but nonzero latency to spawn.
- **Spawn-local, migrate never.** Cheapest, and the locality is often right
  (a process usually talks most to its parent) — but a hot spawner fills its own
  engine and starves.
- **Hash of the parent PID.** Deterministic, spreads, ignores load entirely.

Interacts with Q3: on a ring, placement determines message distance, so a
placement policy is also a latency policy. Not urgent until M6, but the ISA
should not hard-code the answer.

---

## Q7 — What happens when a heap is full and the collector cannot keep up?

Bacon's answer is sizing: 1.01–1.4× live data suffices. But "the collector
cannot keep up" is a real state and picoBEAM needs a defined behaviour for it,
because the alternative is a hardware deadlock.

Candidates: stall the allocating context only (loses the 1-cycle allocation
claim but only for that context); kill the process with
`{'EXIT', Pid, heap_full}` (very Erlang, and it is a hardware-detectable event
per `03-architecture.md`); or migrate the process to a less-loaded engine
(expensive, needs M6+).

**Leaning:** exit signal. It is the Erlang-shaped answer, it composes with
supervision, and it keeps the allocation bound intact for everyone else.

---

## Q8 — How does a process touch a hardware register?

**Surfaced by the first real use case (FOC motor control), and it is a hole, not
a fork: picoBEAM currently has no I/O story at all.** ECOMP listed "external io"
in its runtime and did it over PCI to a host. picoBEAM needs a native one,
because the entire point is that the fabric next door *is* the peripheral.

Candidates:

- **`PORT_READ idx` / `PORT_WRITE idx`** with a compile-time port index resolved
  at elaboration. Cheapest, 1 cycle, no allocation, fully deterministic. Least
  Erlang-shaped.
- **A reserved `PORT` tag** whose reads and writes route to a fabric register
  file instead of BRAM. Uniform with the term model; costs a decode case.
- **Ports as processes.** A fabric block owns a PID; you `send` to it and
  `receive` from it. Most Erlang-shaped, reuses the whole NoC and mailbox path,
  and gets supervision for free — a peripheral that faults sends an exit signal
  and the supervisor restarts the driver. Costs message latency (~13 cy) per I/O.

**Leaning:** the third, with the first as an escape hatch for latency-critical
paths. *"A peripheral is a process you can link to"* is the design that makes
picoBEAM different from a soft core with memory-mapped I/O, and it turns
`monitor(EncoderPid)` into a real thing with a hardware-bounded detection time.

Blocks any use case that touches the outside world. **Not deferrable past M4.**

---

## Q9 — Does an idle barrel context waste its slot?

Fixed rotation gives every context exactly 1/T of the machine whether or not it
has work. That *is* the determinism guarantee — and it also means an engine
running one process runs at 50/T MIPS rather than 50. Skipping idle contexts
recovers the throughput and destroys the guarantee: the share becomes 1/active,
which varies with whatever else happens to be running.

**Leaning:** fixed rotation, and say so loudly, because a control process that is
*promised* its slot is the entire product.

**Consequence for Q2:** T is the divisor on single-process speed. Latency-
sensitive work argues for `:deep` / `:balanced` (T = 4, 80 ns/instruction at
50 MHz) and hard against `:wide` (T = 8, 160 ns/instruction). If the target
application is control rather than throughput, T should not scale up with
engines.
---

## Q1 — DECIDED (2026-08-22): register file, clean-on-call

The ECOMP experiment gets run in full — it is the one idea from the deck
nobody has re-tested in 26 years, and testing it is a stated reason this
project exists. Consequences accepted with it: Actora stops being a direct
LUT/Fmax calibration point (the fit table's ±50% stays wide until M2), code
density likely worsens, and the register-window mechanism — a per-context
register stack with the top frames resident, spill/fill against frame RAM;
JOP's stack cache reborn as a frame cache — becomes M2's hardest sizing
item. In exchange, Core Erlang compiles more directly than to a stack
(let-bound single assignment ↦ fresh registers), and the calling convention
is genuinely save/restore-free. The stack machine becomes the M2b
comparison variant instead of the baseline. The reference model
(`lib/pico_beam/machine.ex`) enforces single assignment at runtime: reading
a register the window never wrote is a fault.

---

## Q4 — DECIDED (2026-08-22), in two parts

**Issue width: 3-slot LIW from day one** — full ECOMP fidelity, chosen with
the costs on the table: ~6R3W register file (engine LUT estimate rises;
M2 measures by how much), 72-bit bundles (two code words per fetch), and a
slot-scheduling compiler. The payoff: a bundle recovers up to 3× per
context turn, directly softening the barrel's T× single-process penalty.
The bundle contract that keeps hardware bypass-free is enforced by the
assembler (`lib/pico_beam/asm.ex`): slots read pre-bundle state; no
cross-slot RAW/WAW (same-slot read-old/write-new is fine); ≤1 heap op;
≤1 system op, last slot.

**Housekeeping: autonomous port-B FSMs, not an instruction slot.** The
housekeeping work (mailbox enqueue, exit-signal hops, timer wheel) is
machine-state-driven, not compiler-chosen — it needs a guaranteed cycle
share, not encoding bits. FSMs on second BRAM ports run every cycle by
construction, so the rate guarantee is stronger than ECOMP's slot and holds
even when no instructions flow. The original "loses the guarantee"
objection applied only under port contention, which dual-ported BRAM
removes.

---

## Q5, revisited — the method cache is also the memory hierarchy

The boot/image design (`11-boot-and-images.md`) adds a second argument for
building the cache at M2: with it, the code image can live in SDRAM (loaded
from SD at boot) with EBR as the method cache — lifting the ~34 KB code
ceiling to the 32 MB SDRAM while keeping JOP's worst-case-analysable miss
behaviour (misses only at call/return). Without it, application size is
bounded by block RAM forever. The original question was WCET vs schedule;
it is now WCET *and* capacity vs schedule, which strengthens the "build it
at M2" leaning.

---

## Q8, revisited — resolved by the boundary declaration

Settled in `10-userland.md`, more precisely than the leaning above: **ports
as processes for the asynchronous world, declared-latency SIFs
(Silicon-Implemented Functions) for the synchronous one, both generated
from a single `api` declaration on the component — and the `PORT_READ`
escape hatch deleted.** An undeclared poke into fabric is exactly the ABI
drift the single-declaration scheme exists to prevent. SIFs must declare a
worst-case latency at elaboration (linter-enforced); anything unbounded
must be a port message. The barrel makes a stalled SIF caller cost only its
own context's slots — the dirty-NIF problem is unrepresentable.

---

## Q2, revisited — T is application-dependent

See `09-use-case-motion.md`. FOC argues for T = 4, because T divides
single-process speed and the current loop *is* one sequential process. A
fieldbus motion interpolator argues for T = 8, because per-axis latency is
irrelevant against a 1 ms cycle and 80 contexts buys 80 supervised axes.

Both are right for their application, which settles the original question in an
unexpected direction: **T should be a solver input driven by a declared latency
budget**, not a constant and not a free knob. Something like
`Fit.solve(luts, ebrs, max_process_latency_ns: 20_000)`.
