# 19 — Fairness: picoBEAM vs BEAM

Written because "guaranteed timing fairness" is the project's loudest
claim and it needs to be stated precisely enough to be attacked.
`notes/18`'s measurements make that possible.

## The one-sentence version

**BEAM enforces fairness as a policy at checkpoints; picoBEAM enforces
it as a wire, for T processes at a time, and as a bounded policy for
everyone else.**

## Two layers, and almost everything follows from telling them apart

picoBEAM has two different fairness stories stacked on top of each
other, and conflating them is how the claim gets overstated.

**Layer 1 — the seated processes (T = 4). This is the wire.**

`seat = cycle mod T`. A free-running 2-bit counter decides whose bundle
issues, and nothing in the machine can influence it. A seated, runnable
process retires exactly one bundle every 4 cycles. Not "on average",
not "usually" — `notes/18` B1 measures 4.00 cycles per bundle to four
significant figures, and B2 shows four processes doing 4× the work in
the same wall-clock (1.02 cycles/bundle aggregate).

What this buys, stated as strongly as it deserves: **a process cannot
be starved by another process's behaviour.** Not by a tight loop, not
by a long computation, not by a burst of messages, not by anything a
program can do. Its slot is physical. In BEAM, a long-running NIF
occupies its scheduler thread and every process on that scheduler
waits; picoBEAM has no equivalent failure mode, because there is no
mechanism by which one context can hold another's cycle.

**Layer 2 — the queued processes. This is policy, but bounded policy.**

With more runnable processes than seats, the reduction budget and the
FIFO run queue decide who is seated. That IS a scheduler, and it is
soft in the way schedulers are. The difference from BEAM is that every
constant in it is a fixed number of cycles, so worst-case latency is a
sum rather than a distribution.

## The constants, from the RTL and from `notes/18`

| quantity | value | where it comes from |
|---|---|---|
| seats, T | 4 | rotation counter |
| slot share, seated | exactly 1 cycle in 4 | B1 = 4.00 cycles/bundle |
| context switch, seated↔seated | **0 cycles** | the counter increments |
| reduction budget | 24 bundles = 96 cycles | `BUDGET` |
| swap out + in | ~90 cycles | 16 (save, one word/cycle) + 64 (restore, one word/turn) + ~10 |
| message round trip | 52.5 cycles | B3 |
| spawn + reap | 87.5 cycles | B4 |
| call + return | 108.2 cycles | B5 |

From these, the thing BEAM cannot state: **the worst-case time for a
runnable process to start executing.** With P runnable processes on
T seats, a queued process waits for the processes ahead of it in the
FIFO, each of which costs one swap:

    wait ≈ (P − T) × (budget + swap) / T
         = (P − T) × (96 + 90) / 4  ≈  (P − T) × 46 cycles

At P = 8, that is ~186 cycles — **15 µs at 12 MHz**, computed from
constants, not measured from a histogram. Every term is a named
hardware number.

## Where this model is honestly weak

**The budget is badly tuned right now.** 96 cycles of running against
~90 cycles of swapping means an OVERSUBSCRIBED engine spends about
half its cycles moving windows instead of executing. `BUDGET = 24` was
chosen so demos would visibly swap, not for throughput. At `BUDGET =
256` the ratio becomes 1024 : 90 — 92% efficiency — at the cost of a
coarser fairness quantum. This is a one-constant change and it is the
second-highest-value tuning knob after the ret-fill burst.

**T = 4 is a hard ceiling on the exact guarantee.** Beyond four
runnable processes, fairness degrades from "a wire" to "a bounded
policy". Erlang systems routinely have thousands of processes — but
most are blocked in `receive` at any instant, and since M4 a blocked
process is EVICTED rather than holding a seat. So the population that
matters is the runnable one, which is usually small. That is an
argument, not a measurement, and it should be measured.

**32 process slots per engine.** A v1 sizing choice, not architecture;
the PID has 6 bits of slot and the roadmap has more engines.

## The comparison, kept fair

| | BEAM | picoBEAM |
|---|---|---|
| quantum | 4,000 reductions, checked at call boundaries | 1 bundle, enforced by a counter |
| preemption | at checkpoints; a long NIF blocks the scheduler | physical — nothing can hold another's slot |
| switch cost | hundreds of ns (registers, cache, queues) | **0 cycles** resident; ~90 cycles to swap |
| fairness among runnable | statistical, with a tail | **exact** for T; bounded beyond |
| priorities | 4 levels | none, deliberately |
| migration | work stealing across schedulers | none, ever (the PID is the route) |
| worst-case run latency | not computable in general | a sum of named constants |
| scale | millions of processes | 32/engine at v1 |
| clock | ~3 GHz | 12 MHz (27 MHz closes today) |

BEAM wins on scale and absolute speed by enormous margins and will
continue to. picoBEAM wins on exactly one axis — **the ability to say
what will happen and when** — and that axis is the entire point of
`00-charter.md`.

## The mental model, in one picture

    BEAM:      a fair scheduler doing its best on shared hardware,
               with a tail you cannot bound

    picoBEAM:  four hardware seats that CANNOT be taken from you,
               plus a small bounded queue for everyone else

If your problem is "run a million processes fast", BEAM. If it is
"prove this control loop never misses its deadline, no matter what the
rest of the system does", that is what four unstealable seats are for.
