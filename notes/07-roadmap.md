# 07 — Roadmap

Ordered so that each milestone produces something you can point at, and so the
two riskiest unknowns — simulator throughput and real LUT cost — resolve early
rather than late.

---

## M0 — Make the simulator able to simulate a CPU

**Prerequisite for everything.** `../ehdl/AGENTS.md` fix #1: stop `_top_`
evaluating its full comb set per edge; use `copy_needed_ops/4` as every other
entity does. Then #2, targeted `build_env`. Only then consider dirty-tracking
(`State.mark_top_dirty/1` and `clear_top_dirty/1` exist and suggest someone
started down that road).

Measure with the per-process reduction-delta method — no profiler is available.

**Demo:** ticks/s on `HelloBoard.Top`, before and after, stated as a number.

---

## M1 — ISA and reference model, no hardware

The instruction set as an Elixir interpreter, plus a Core Erlang front end for
the v1 subset. Get the ISA wrong here, where it is cheap.

Run **Probe A** and **Probe B** in parallel with this; they are independent of
M0 and of each other.

- **Probe A:** does `memory` inference give true dual-port `DP16KD` on ECP5,
  with independent read and write ports on one clock? Smallest possible test
  design; read the nextpnr report. Gates Bet 1 and the GC argument.
- **Probe B:** elaborate a trivial component replicated nine times under
  `generate`; measure atom growth. Establishes whether the fabric can be
  elaborated at all before designing it. Gates Bet 4.

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
