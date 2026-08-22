# 03 — Architecture

Everything here follows from four bets. If one of them is wrong the
architecture changes shape, so argue with them before anything else.

| # | Bet |
|---|-----|
| 1 | **No shared heap, ever.** Private heap per engine; messages copied. |
| 2 | **The PID is the route.** Owning engine index is a bit-field of the PID. |
| 3 | **Barrel threads, not context switches.** T contexts through one pipeline. |
| 4 | **The fabric's shape is a computed value.** Solved at elaboration. |

## Term representation

ECP5 EBR is an 18 kbit block that configures down to 512×36. **36 bits is
therefore the natural word:** one block deep-configured, and it leaves 32 bits
of payload after a 4-bit tag — so a fixnum is a full 32-bit signed integer with
no boxing and no bignum path in v1.

```
generic:  [ tag : 4 ][           payload : 32           ]
PID:      [ tag : 4 ][ engine : 4 ][ slot : 6 ][ serial : 22 ]
                       ^^^^^^^^^^
                       NoC destination address — a bit-slice, not a lookup
```

Sixteen tags is enough and then some:

| Tag | Meaning |
|---|---|
| `INT` | 32-bit signed fixnum, immediate |
| `ATOM` | index into the shared atom table |
| `NIL` | the empty list |
| `CONS` | pointer to a 2-word heap cell |
| `TUPLE` | pointer to header + elements |
| `PID` | see above |
| `REF` | monitor / make_ref |
| `FUN` | closure pointer |
| `BIN` | reserved, not in v1 |
| `HDR` | boxed-object header, carries arity |
| `FWD` | GC forwarding pointer |
| `RETADDR` | stack only: return address + frame info |
| `CATCH` | stack only: catch frame |
| — | three spare |

**The heap is a uniform two-word cell.** A cons is one cell; a tuple of arity N
is a header cell plus ⌈N/2⌉ cells. This is ECOMP's "one element size" and
Bacon's "miniheap," arrived at twice independently, and it is the single
decision that makes a hardware collector fit in a few hundred LUTs.

Bet 2 in one sentence: **slicing four bits out of the operand yields the
destination engine**, so the routing decision for `send` is available in the
decode stage before the term has even been read. That is what makes a
fixed-latency send possible at all.

## The engine

A three-stage stack machine — fetch, decode, execute — with dual stacks in
dual-port BRAM, in Actora's shape. What Actora does not have, and what changes
the machine completely, is that the pipeline is **barrel-interleaved across T
process contexts.**

Three dividends, all of which happen to be exactly what Erlang wants:

1. Instructions from a given thread are three cycles apart, so nothing in
   flight can depend on anything else in flight. **The bypass network and the
   interlock logic simply do not exist.**
2. Switching between resident processes costs **zero cycles** — the context is
   selected by the rotation counter. ECOMP's 20-cycle headline becomes a change
   in a two-bit counter.
3. Every process gets precisely 1/T of the machine, forever, with no scheduler
   policy involved. Determinism as a structural property, not a policy.

**The cost:** single-process latency is T× worse. A lone process on a T=4 engine
runs at quarter speed. That is the correct trade for a language whose premise is
thousands of processes, and the wrong trade if you hoped to win a `fib`
benchmark. Decided; see `00-charter.md`.

**Instruction fetch rides the same rotation.** Because exactly one thread
fetches per cycle, a shared code ROM across all engines needs no arbiter at all
— just a rotating port assignment. Above a handful of engines that stops
scaling and each engine wants JOP's **whole-method cache** instead, where a miss
can only occur at call and return. Erlang's function boundaries are exactly as
sharp as Java's, so the worst-case-analysable structure transfers directly.
(Whether to build the method cache at M2 or defer it is in `08-open-questions.md`.)

## Instruction set sketch

Stack machine, dual stacks, in the J1/Actora lineage. ECOMP's 3-slot LIW bundle
retained, but slot 3 repurposed — see below.

**Core:** `PUSH_IMM tag,val` · `PUSH_LOCAL n` · `POP n` · `DUP` · `SWAP` ·
`CALL f,arity` · `TAILCALL f,arity` · `RET` · `JMP` · `JMP_IF_FALSE`

**Terms:** `CONS` · `HEAD` · `TAIL` · `MKTUPLE n` · `ELEM n` · `IS_CONS` ·
`IS_TUPLE n` · `EQ_ATOM a` · arithmetic and comparison on fixnums with a tag
check that traps

**Concurrency — the new part:** `SPAWN f,arity` (placement policy in hardware;
returns a PID) · `SEND` · `RECEIVE_START` / `RECEIVE_MATCH pat` /
`RECEIVE_COMMIT` / `RECEIVE_TIMEOUT t` · `SELF` · `YIELD` (implicit on
reduction exhaustion) · `REGISTER name,pid`

**Supervision:** `LINK` · `UNLINK` · `MONITOR` · `DEMONITOR` · `EXIT` ·
`TRAP_EXIT`

**The third bundle slot.** ECOMP spent it on GC increments. With a collector on
the second BRAM port the mutator owes GC nothing, so spend it on **OTP
housekeeping**: one mailbox-enqueue step, one exit-signal hop, or one
timer-wheel tick per bundle. Supervision and timeouts become rate-guaranteed
rather than best-effort — which is a determinism claim, not an optimisation.

## The fabric

N engines, each with a private heap, mailbox, process table and run queue,
connected by a message ring. Nothing shared except read-only code and the atom
table.

```
        [ shared code ROM + atom table — read-only, ~16 EBR ]
            |             |                      |
         fetch, rotated — no arbiter needed
            |             |                      |
      +-----v-----+ +-----v-----+          +-----v-----+
      |   PE 0    | |   PE 1    |   ...    |   PE 8    |
      | heap (pvt)| | heap (pvt)|          | heap (pvt)|
      | mailbox   | | mailbox   |          | mailbox   |
      | proc tbl  | | proc tbl  |          | proc tbl  |
      | collector | | collector |          | collector |
      | (port B)  | | (port B)  |          | (port B)  |
      +-----+-----+ +-----+-----+          +-----+-----+
            |             |                      |
            +------ message ring, 36-bit flits --+
                          |
                 [ SDRAM 32 MB — hibernation tier ]
```

**Topology.** Crossbar below ~4 engines (cheap), ring above. Past ~16 engines
the answer is a 2D torus with Hoplite-style deflection routing — but that
changes send's worst case from "ring diameter" to "deflection bound," which is a
weaker determinism claim. See `08-open-questions.md`.

## Send and receive

In software BEAM, `send` resolves a PID, copies the term into the receiver's
heap or an off-heap fragment, appends to a queue and signals the scheduler.
Every step is a lookup or a pointer chase. In fabric three of the four become
wires.

```
SEND        serialiser        ring          mailbox writer      shape hash
PE0,ctx P2  term walk→flits   k hops        PE3, port B         8 bits, at enqueue
  1 cy         1..n cy         k cy           1 cy/flit            free
```

Worst case for an immediate on a 9-engine ring: **~13 cycles ≈ 260 ns at
50 MHz**, jitter bounded by ring diameter alone.

**Selective receive, cheaply.** Hash the outer shape of every message as it is
enqueued — tag, arity, and the first element if it is an atom. A
`receive {reply, Ref, X}` then rejects non-matching messages at **one per
cycle** without ever reading their contents, and pays for a real match only on a
hit. This attacks the one part of Erlang's semantics that is reliably slow in
software: BEAM's O(n) mailbox scan, the classic "receive trap."

Two consequences worth naming:

- The matcher runs on the mailbox BRAM's second port, so scanning happens
  **concurrently with the process running**. By the time a blocked process is
  rescheduled, its mailbox has already been searched.
- Because the scan rate is fixed and the mailbox is bounded, worst-case receive
  latency is a number you can write down: `mailbox_depth` cycles plus the match
  program's length. Software BEAM cannot state that number.

## Garbage collection

Bacon's 2012 design is the template and it is almost too convenient. Dual-ported
BRAM gives the mutator port A and the collector port B, so the root snapshot
pause is *eliminated* rather than shortened, and read-before-write mode captures
the overwritten pointer for the write barrier in one cycle with no stall.

```
 mutator  ──alloc/read/write──▶ [ heap BRAM, 2 semispaces ] ◀──scan/copy/forward── Cheney engine
 (barrel contexts P0..P3)         true dual port,                (an FSM, a few
                                  read-before-write               hundred LUT)
                                  port A         port B
```

Erlang hands you something better than Bacon's starting point, though, and it is
worth being precise about why. BEAM's per-process private heap means a
collection has a scope of exactly one process. Here the heap's scope is one
*engine* — a handful of processes — and **no pointer can leave it**. So the
collector is not merely concurrent with its own mutator; it is concurrent with
the entire rest of the machine, structurally, with nothing to prove.

**Why the claim is structural rather than empirical:** a stop-the-world pause
requires the collector and the mutator to contend for one memory port. Give them
a port each and the pause has nowhere to live. The remaining question is only
whether the collector keeps up with the allocation rate, which is a sizing
problem with a known answer — 1.01–1.4× live data, per Bacon.

Algorithm: Cheney copying between semispaces, forwarding pointers in the `FWD`
tag, snapshot-at-the-beginning with a read-before-write write barrier.

## Supervision in silicon

Every machine in `02-prior-art.md` stops at spawn-and-send, and ECOMP's slides
list catch/throw and timeouts but say nothing about links or monitors. Yet links,
monitors and exit-signal propagation are not a library on top of Erlang — they
are the reason anyone uses it. **This is the part nobody has built.**

The hardware is not exotic:

- A **link table** per engine: a small associative store of PID pairs.
- A **monitor table**, same shape but directed and carrying a reference.
- On exit, the engine walks the link set and emits an exit signal per entry onto
  the same ring the messages use — a local broadcast with bounded fan-out, which
  is exactly the work the third bundle slot exists to absorb.
- `trap_exit` flips a bit in the process table entry and turns the signal into an
  ordinary mailbox message on arrival.

Two things fall out that software cannot offer:

1. **Exit-signal propagation gets a hard latency bound** — links × ring diameter
   — so "how long after a crash until the supervisor knows?" has an answer in
   nanoseconds rather than a distribution.
2. **Crash detection widens past software's reach.** A process that exceeds its
   reduction budget, overflows its stack, dereferences a bad tag or fails to
   allocate is already a hardware-detectable event. Those become exit reasons at
   zero cost, delivered through the same path.

**The demo that proves it:** a supervisor, two children, one of which crashes on
a bad tag. The supervisor restarts it. An LED changes state. `one_for_one`, and
there is no processor in the loop — link table, exit signal and restart are all
fabric.

## The SDRAM tension, and why it dissolves

The ULX3S has 32 MB of SDRAM, which is the only way to get from tens of
processes to thousands. It is also, with refresh cycles and bank conflicts,
exactly the thing that destroys a determinism claim.

These look irreconcilable. They aren't, because **Erlang already tells you which
processes don't need bounded latency: the blocked ones.** A process sitting in
`receive` with nothing matching has, by the language's own semantics, no
deadline — until a message arrives. So put hibernated contexts in SDRAM and let
the *send* trigger the page-in. Send is asynchronous; the wake latency hides
inside a delivery the semantics already permit to take time.

Resident processes never touch SDRAM, and the hard bounds apply to exactly the
set of processes that can currently observe them. Erlang's own `hibernate/3` —
which garbage-collects on the way out — is the same idea one level up.
