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
