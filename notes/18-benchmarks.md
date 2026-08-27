# 18 — Benchmarks, v1

What picoBEAM costs, measured rather than argued. Every number here is
**cycles per operation**, taken with a cycle-exact simulation of the
emitted netlist, with the work bracketed between two `out` markers so
nothing inside the machine is instrumented. Sim and silicon have agreed
at every step of M2–M4, including on two bugs, so these are read as
facts about the hardware.

    mix run scripts/mk_bench.exs        # assemble the images
    scripts/tb_bench.v                  # the harness (one image per run)

## The numbers (T = 4, one engine, 12 MHz)

| # | benchmark | cycles | ops | **cycles/op** | at 12 MHz |
|---|---|---|---|---|---|
| B1 | 3-bundle loop, ONE process | 12,020 | 3,005 bundles | **4.00** | 3.0 M bundles/s |
| B2 | same loop, FOUR processes | 12,228 | 11,998 bundles | **1.02** | 11.8 M bundles/s |
| B3 | ping-pong round trip | 10,508 | 200 round trips | **52.5** | 229 K/s (458 K msg/s) |
| B4 | spawn + reap | 8,752 | 100 processes | **87.5** | 137 K/s |
| B5 | call + return | 10,820 | 100 pairs | **108.2** | 111 K/s |
| B6 | fib(15) = 610 | 201,252 | 14,799 bundles | 13.6 | 16.8 ms |

## What each one actually says

**B1 = 4.00 cycles per bundle is the trade, exactly.** A lone process on
a T = 4 barrel gets one turn in four, and it gets it to four significant
figures. `03-architecture.md` promised "single-process latency is T×
worse" going in; this is that promise, paid, with no hidden overhead on
top of it.

**B2 = 1.02 cycles per bundle is the whole architecture in one number.**
Four runnable processes retire a bundle almost every cycle — 98% issue
efficiency — and take 12,228 cycles to do 4× the work that one process
did in 12,020. **Four processes cost the same wall-clock as one.** That
is what a barrel buys, and it is why the T× single-process penalty is
the right price rather than a regrettable one.

**B3 = 52.5 cycles per round trip.** Two messages, four `receive`
protocol steps, two `send`s, two scans and the loop arithmetic. At
12 MHz that is 229 K round trips per second on a chip clocked slower
than a 1985 desktop.

**B4 = 87.5 cycles to create AND reap a process.** Erlang's headline
operation, including the 16-cycle argument drain, a proc-table
allocation, a queue push, a seat-in with a 17-turn window restore, the
process running, and its slot being freed. No allocator, no page
mapping, no kernel.

**B5 = 108.2 cycles per call/return**, and this is the one that should
change. A call is one turn plus a background drain; a RETURN is ~18
owner turns (72 cycles) because the callee's window streams back one
word per turn through port 0. Ret is ~4× the cost of everything else in
the machine.

**B6 exposes exactly that.** fib(15) makes ~1,973 calls, and 1,973 ×
~72 cycles ≈ 142 K of its 201 K cycles are ret fills — **70% of a
call-heavy program is the return path.** The fix is already named in
`notes/16`: give the window a fourth bank (the LVT's 2-bit code has a
spare value) so a fill can burst instead of trickling. That is the
single highest-value optimisation in the machine right now, and it was
found by measuring rather than guessing.

## What these numbers do NOT say

They do not say picoBEAM is fast against BEAM on a laptop. BEAM runs on
a 3 GHz core; this runs at 12 MHz, a 250× clock deficit that no
architecture recovers. A fair comparison would run identical programs on
both and normalise per clock, and we have not done that — quoting a
ratio without it would be exactly the kind of estimate-dressed-as-result
that `notes/17` just had to retract.

What can be said without measuring anything else:

* **A context switch costs zero cycles.** Not "a few hundred nanoseconds"
  — zero. The rotation is a 2-bit counter, and switching between
  resident processes is that counter incrementing. Swapping a
  NON-resident process in costs ~33 turns, which is the honest number
  and is what B4 partly measures.
* **Scheduling costs zero cycles.** There is no scheduler loop to run:
  1/T falls out of the rotation, and the only policy in the machine is
  a FIFO that is consulted when a seat comes free.
* **The bounds are structural.** Every cost above is a fixed count of
  turns, not a distribution with a tail. That is the property this
  machine exists to have, and it is why `05-determinism.md` can talk
  about WCET at all.

## Headroom, without new architecture

| lever | effect | status |
|---|---|---|
| clock 12 → 27 MHz | ×2.25 on everything | timing already closes at 24.5–27 MHz; the 12 MHz is first-silicon caution |
| ret fill burst (4th window bank) | ~2× on call-heavy code | designed, not built |
| T = 8 | 2× resident processes, same issue rate | storage layout already context-indexed |
| N engines (axis 1) | ×N throughput | the ring is M6 |

At 27 MHz with 9 engines — the `:balanced` fit from `04-fit-model.md`,
which the M3 LUT numbers say is reachable on an 85F — the same
architecture is on the order of 240 M bundles/s and 4.6 M message round
trips/s. Those are extrapolations and are labelled as such; the six
numbers in the table are not.

## Method notes

* Each image brackets its work with `out 0xA0` / `out 0xA1`; the
  harness counts cycles between them, so loader and boot are excluded.
* `bundles` counts X-stage retirements over the same window, which is
  how B1/B2 get a per-bundle figure independent of the loop shape.
* B2 spawns three workers and runs the same loop in all four, so its
  aggregate includes the spawn cost — the 1.02 is therefore slightly
  pessimistic, not optimistic.
* Every benchmark ran with `fault=0`.
