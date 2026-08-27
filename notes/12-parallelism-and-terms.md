# 12 — Parallelism, and what to call things

Written because the words kept slipping. "Core," "scheduler," "thread" and
"executor" all mean the wrong thing here, and a design whose vocabulary is
borrowed from the machine it is replacing will quietly inherit that machine's
assumptions. This note fixes the axes and the nouns.

## The three axes (plus an autonomous fourth)

picoBEAM is parallel in three distinct ways, and they do not trade against
each other — they multiply.

**Axis 1 — engines: true parallelism.** N engines each execute a bundle
every cycle, against private heaps, connected only by the ring. This is the
only axis where two things literally happen at the same instant on behalf of
two processes. It scales until the PID's engine field runs out (below).

**Axis 2 — the barrel: concurrency, not parallelism.** Within one engine, T
contexts interleave through one pipeline, seat = cycle mod T (Q9: fixed
rotation, always, even when idle). No two contexts ever occupy the same
pipeline stage on the same cycle for the same seat — this axis adds *zero*
throughput. What it buys is Erlang's actual product: T resident processes
whose interleaving is a counter, whose switch costs zero cycles, and whose
1/T share is a promise rather than a policy outcome.

**Axis 3 — the bundle: instruction-level parallelism.** Up to three slots
issue together in one context turn (Q4a). This is the axis that softens
axis 2's cost: a lone process on a T=4 engine runs at 1/4 the cycle rate but
up to 3 ops per turn, so the single-process penalty is T/3 in the best-packed
case, not T. The bundle contract (no cross-slot dependencies, reads see
pre-bundle state) is what keeps this axis free of bypass hardware.

**The fourth plane — port-B units — is not an axis the program sees.** The
collector, the mailbox matcher/enqueuer, and the housekeeping FSMs (Q4b) run
every cycle on the second ports of the BRAMs, concurrently with all three
axes, by construction. They are best thought of as weather: always running,
never scheduled, never billed to any process. (The "never billed" claim is
an assumption until M5 measures it — see `14-m1-status.md`.)

## The nouns

| Term | Means | Never call it |
|---|---|---|
| **engine** | One pipeline + private heap + mailbox + proc table + run queue + port-B units. The unit of true parallelism and the unit of GC scope. | core, CPU, scheduler, executor |
| **context** | A seat in one engine's barrel. Holds a resident process's registers/windows. There are exactly T per engine, forever. | thread, hart |
| **process** | The Erlang thing. Lives in one engine's proc table (64 slots); is *resident* when seated in a context, *queued* when runnable but unseated, *blocked* in receive. | task |
| **rotation** | seat = cycle mod T. The entire "scheduler" of resident processes. | arbitration, scheduling |
| **run queue** | Per-engine FIFO of runnable-but-unseated processes. The only scheduling policy in the machine (budget exhaustion with waiters → tail of queue; wake → tail of queue). | — |
| **placement** | The spawn-time choice of engine (Q6, open; model uses round-robin). Made once, permanent. | migration, load balancing |
| **port-B units** | Collector, matcher, housekeeping FSMs. Autonomous, unbilled. | coprocessors |
| **the ring** | The only thing between engines. Carries messages, exit signals, DOWN, link/unlink/monitor registrations — and, in hardware only, spawn requests: the model can place a process on another engine by writing its table, and gates cannot (`notes/29`). | bus, fabric (reserved for the FPGA itself) |

The load-bearing analogy: **an engine is to picoBEAM what a scheduler thread
is to BEAM** — the unit that owns a run queue and multiplexes processes — with
two deliberate differences. First, BEAM's scheduler is software policy over
shared memory; an engine's rotation is a counter over private memory. Second:

## There is no work stealing, and there cannot be

This is a consequence, not an oversight. Bet 1 (no shared heap) plus Bet 2
(the PID *is* the route) mean a process's heap lives in one engine's BRAM and
its PID names that engine forever. Migrating a process would require copying
its heap across the ring *and* either mutating its PID (breaking every
existing reference to it) or adding a forwarding layer (reintroducing the
lookup that Bet 2 exists to delete). So placement at spawn is final, a hot
engine stays hot, and the answer to imbalance is the placement policy (Q6)
plus the application's own spawn structure — the same answer OTP gives for
distributed Erlang across nodes. **An engine is a node, not a scheduler
thread**, is the sharper form of the analogy: private heap, copied messages,
permanent placement, and the ring as the distribution channel. picoBEAM is a
distributed system on a chip, and admitting it early keeps us from
re-deriving work stealing badly.

## The ceiling, and why it is welcome

The PID allocates 4 bits of engine: **16 engines, hard.** Q3 independently
argued that past ~16 engines the ring must become a torus and the send bound
degrades from "diameter" to "deflection bound" — a weaker claim. The
encoding and the topology agree on the same number, which is the design
telling us it is self-consistent: v1 is at most 16 engines, the send bound
stays clean, and anyone wanting 64 engines is asking for picoBEAM-NUMA,
which is a different machine (or several picoBEAMs and real distribution).

At the `:balanced` fit (9 engines, T=4, all numbers ±50% until M2
calibrates): 36 resident processes, 9 bundles/cycle peak issue, 576
processes before `:system_limit`, and a lone process at worst 1/4 speed ×
best 3 ops/turn. Throughput scales with axis 1; the bounds ride on axes 2
and 4 and do not change shape as engines are added — which is the whole
point of separating the axes.

---

## Postscript (notes/53): the doctrine, corrected

"An engine is a node, not a scheduler thread" was this note's sharpest
line, and it aimed one level too high. The machine is the node; an
engine is a scheduler; the ring is the node's interconnect. What made
the sentence feel true — private heaps, copied messages, permanent
placement — is exactly how SMP BEAM already behaves *inside* one node,
so nothing mechanical here was wrong: every bound above survives, and
the ring still carries every word it carried.

What the wrong word cost was NODE state: the registry was built
per-engine (so `whereis/1` answered differently depending on where you
asked — `notes/53` §1 has the failing program), and ring kinds 3–8
were popped and dropped (so a link to a child the round-robin placed
away silently was no link). Both are fixed: one shared name CAM at the
node level (`notes/53`), and supervision signals that cross the ring
(`notes/54`).

"Distribution" is not deleted — it is promoted. It now means
MULTI-BOARD: a second ULX3S on a real wire, a node id above the engine
id. Everything this note derived under the old doctrine — copied
terms, incarnation checks, packets that carry their destination — is
precisely what that machine will need. It was distribution
infrastructure built one level too early, waiting at the level it
belongs.
