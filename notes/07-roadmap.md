# 07 — Roadmap

Ordered so that each milestone produces something you can point at, and so the
two riskiest unknowns — simulator throughput and real LUT cost — resolve early
rather than late.

---

## M0 — Make the simulator able to simulate a CPU — **DONE**

**The number: 4 → 344–362 ticks/s (~87×) on `HelloBoard.Top`.**

Fix #1 (restrict `_top_`'s per-edge eval to the closure feeding its own regs)
and #2 (targeted `build_env`) both landed, plus a third that the first two
forced: `_top_`'s commit-phase eval is replaced by a design-visibility settle
closure evaluated in the clock after all commits, which also turned two
formerly scheduler-order-dependent races into deterministic orderings.
Dirty-tracking was never needed. Equivalence vs the legacy path (kept behind
`HW_SIM_TOP_FULL=1`): 94/94 reg-next values identical, 480 lockstep ticks
with zero divergent signals. Full record in `../ehdl/AGENTS.md`; probes and
verification scripts in `../ehdl/_prim/m0_*.exs`.

Remaining headroom when M3+ needs it: the Rust NIF backend
(`Hw.Sim.Backend.Nif`), which `Hw.Sim.start` does not yet use.

---

## M1 — ISA and reference model, no hardware

The instruction set as an Elixir interpreter, plus a Core Erlang front end for
the v1 subset. Get the ISA wrong here, where it is cheap.

Probes A and B ran alongside M0 — both **done**, both green:

- **Probe A — CONFIRMED:** 512 × 36 `memory` with `sync_read:` → exactly one
  `DP16KD`, single-clock and two-clock shapes. Caveats (memory names vs
  Verilog keywords; one write site per memory — the 2×RW gap gates M5; no
  MemWrite in sim) recorded in `06-risks.md`.
- **Probe B — RETIRED:** +306 atoms for a 9× fabric, +0 on re-elaboration.
  `generate` can't replicate instances, but a compile-time `for` over
  `wire`/`instance` can and is proven — Bet 4's mechanism exists today.

**Demo:** ring benchmark and a gen_server-shaped loop running on the model.

---

## M2 — One engine, one context, no concurrency

Actora's scope, in EHDL: stack machine, tags, heap, no GC yet. Synthesise it.

**This is the calibration milestone.** The LUT and EBR columns in
`04-fit-model.md` stop being guesses and `PicoBEAM.Fit`'s constants become real.
Everything downstream that depends on "how many engines fit" is speculative
until this lands.

Open question, decide before starting: whether JOP's whole-method cache is built
here or deferred. See `08-open-questions.md`. Leaning build it here.

**Demo:** `fib` and `nrev` on hardware; a nextpnr report that rewrites `Fit`'s
constants.

---

## M3 — The barrel

T contexts, reduction counter, run queue, process table, `SPAWN` and `YIELD`
within one engine. Concurrency exists but nothing leaves the island yet.

**Demo:** a thousand spawns, and a scope trace showing exact 1/T interleaving.

---

## M4 — Mailbox, send and selective receive

Serialiser, mailbox BRAM, shape hash, match unit on port B. Still single-engine,
so `SEND` is a local loopback — which is the right way to debug it.

**Demo:** ping-pong between two processes; measured receive latency
distribution.

---

## M5 — The collector

Cheney on port B, semispaces, forwarding pointers, read-before-write barrier.

The claim to verify is not that it collects but that **the mutator never
stalls.** See the measurement note in `05-determinism.md` — if the retirement
counter dips, the claim is dead; do not explain the dip away.

**Demo:** allocation-heavy loop with a cycle counter proving 100% mutator
utilisation.

---

## M6 — Multiple engines and the ring

`generate`-driven replication, PID-routed send, cross-engine delivery. The
moment the fit solver stops being theatre.

**Demo:** the same ring benchmark distributed across 9 engines; hop-latency
histogram.

---

## M7 — Links, monitors and exit signals

Link table, monitor table, signal propagation in the third bundle slot,
`trap_exit`. **The part nobody has built.**

**Demo:** `one_for_one` supervisor restarting a crashed child, LED as the
witness.

---

## M8 — Observability over USB

Reuse the CDC-ACM stack that already enumerates in EHDL (`Hw.USB.FSPhy`,
`Hw.USB.SIE`, `Hw.USB.CDCSerial`). Dump the process table, run queues, mailbox
depths and heap occupancy over serial — `observer` reduced to what fits down a
UART.

**Demo:** watching processes spawn and die from a terminal.

---

## M9 — The hibernation tier

SDRAM controller, context eviction for blocked processes, wake-on-send
prefetch.

Last, because it is the only part that trades away a bound, and because
everything above must work without it.

**Demo:** ten thousand mostly-blocked processes on an 85F.
