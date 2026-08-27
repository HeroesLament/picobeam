# 45 — The ECOMP scoreboard

`notes/01` read the only surviving record of ECOMP — fifteen slides,
473 words, Erlang User Conference 2000 — and ended with a table of
verdicts: keep this, beat that, drop the other. Twenty-six years later
and forty-four notes in, this is the same table with measurements in it.

Searched again while writing this. Still nothing: no paper, no patent,
no retrospective, no ECOMP in Armstrong's HOPL III. The deck is the
whole public record, which means every number below is compared against
a claim nobody can check. That cuts both ways and it is worth saying
once, at the top, rather than hedging every row.

## Where the machine stands, counted

Taken 2026-08-26, after `notes/44`.

    gate            62 testbenches, 0 failed
    model           75 tests, 0 failed
    opcodes         56 of 63 op bytes executed by a real program
    OTP shapes      14 of 15 (notes/30), register/whereis the holdout
    silicon         42,203 LUT4 (50% of the 85F), 116 DP16KD,
                    Fmax 14.59 MHz, closing at 12 MHz

Seven op bytes have never run in a program: `bor` `bxor` `cmple` (unit
tested in `tb_alu_signed`, no program has used one), `recv_hash`
`unlink` `yield` (wired, never exercised), and `recv`, which `Encoding`
deliberately refuses because the fused form does not exist in hardware.
That list has been substantially the same since `notes/27` and is the
cheapest coverage debt in the tree.

## The scoreboard

| ECOMP claimed | verdict in `notes/01` | picoBEAM today |
|---|---|---|
| 3 sub-instructions per instruction, each (Tag, Value) | keep | **yes** — 3 slots × 24 bits, 72-bit bundle |
| Sub-instructions for GC | repurpose | **repurposed, and further than planned** |
| Uniform heap cell ("one element size") | keep | **yes** — 36-bit cells, one shape |
| Real-time GC, concurrent, in hardware | keep | **no — stop-the-world** |
| Per-process clock-cycle limit | keep | **yes**, and exact rather than approximate |
| ~20-cycle process switch | beat | **zero cycles** between resident contexts |
| Basic type checking | keep | **yes** — tagged, and overflow traps |
| One process queue | drop | **per-engine queues, two engines on the die** |
| Runtime in machine code | drop | **in gates** |
| BIFs (`element`), `lists`, ETS | — | `element` and `lists` yes, **ETS no** |
| Registered processes | — | **no** |
| External IO | — | **no**, beyond the debug UART |
| 16 KLOC application, 714 k dump | — | **414 bundles** |

### The four rows we are clearly ahead on

**The runtime is gates.** This is the whole thesis and it is the row
ECOMP is furthest behind on. Their slide lists switch, spawn, send,
message-queue handling, catch/throw, timeout, external IO, atom
handling and registered processes as *"implemented in machine code"* —
software on top of an Erlang-shaped ISA. Here, spawn, send with a
copying serialiser, the selective-receive matcher, links, monitors,
exit signals, `trap_exit`, the timer wheel and `try`/`catch` are RTL,
and every one of them is checked against the model on a netlist:
`tb_fixed:srv`, `:otp`, `:slink`, `:try`, `:super_*`, `:trapread`.

**Process switch.** Barrel multithreading makes a switch between the
four resident contexts cost nothing at all — there is no switch, there
are four program counters and a rotating issue slot. ECOMP's ~20 cycles
was good for 2000; `notes/01` called it the number to embarrass, and
zero embarrasses it. The cost has moved to eviction — swapping a
non-resident process into a seat — which `tb_m4_evict` measures and
`notes/18` records.

**Two engines, per-engine queues.** ECOMP had one process queue and
allowed for more. `M5Core` puts two independent engines on one die with
a ring between them, and `notes/44` places and routes them at 50% of an
85F. The queues, heaps and mailboxes are per engine. What is *not* done
is the thing that makes two engines worth having — cross-engine spawn
and signals (`notes/29`) — so this row is ahead in structure and level
in practice.

**The third slot.** `notes/01` said to take ECOMP's GC sub-instructions
and spend the slot on OTP housekeeping instead: one mailbox-enqueue
step, one exit-signal hop, one timer tick per bundle, so supervision
becomes rate-guaranteed rather than best-effort. What actually happened
is better than the plan. The system slot carries the OTP *ops* —
`send`, `spawn`, `recv_*`, `link`, `monitor`, `exit2` — while the
housekeeping runs in units that do not need a slot at all: `SendUnit`,
`SignalTable`, `Timer` and the shape-hash matcher all step themselves,
off the mutator's critical path, on the mailbox BRAM's second port.
Rate-guaranteed without spending issue bandwidth to guarantee it.

### The row we are behind on, and it is a real one

**Their GC was concurrent. Ours stops the world.**

ECOMP: *"Real-time GC performed concurrently in hardware."* picoBEAM:
`notes/41` is titled *Stopping the world* and means it — `gc_st`
quiesces every engine, the root walk is serial, and the measured pause
is ≈490 cycles every ≈6,400, about 8% of wall clock, almost all of it
the walk.

`notes/01` rated concurrent hardware GC the best-evidenced idea in the
space and cited the two systems that have actually demonstrated it —
Bacon's stall-free FPGA collector (<0.7% of a Virtex-5, zero mutator
stalls) and Cloaca (2024, ~20-cycle pauses). We agreed with the verdict
and then built the other thing, because a stop-the-world Cheney
collector is what could be made correct first, and correct-first has
been the rule since the standing instruction was to get the BEAM and
OTP API right before optimising the fabric.

It is worth being precise about what "behind" means here. ECOMP's claim
is one line on a slide with no artifact behind it, and *"currently
supports one element size"* sits right next to it — which is the shape
of a collector that has been simplified until it works, not one that
has been proven concurrent under load. Our 8% is measured, on a
netlist, against a model, word for word, in `tb_fixed:gcloop`. An
unverified zero and a measured 8% are not the same kind of number. But
the direction of the claim is theirs, and closing it is on the list.

### The row nobody should be comfortable about

**16,000 lines of call control, against 414 bundles.**

ECOMP's larger benchmark was a real Ericsson call-control application:
16 KLOC, a 714 k dump, ~3–4 machine instructions per line of Erlang.
The largest program picoBEAM has ever run is `board_demo` at 414
bundles, and the largest module the front end has compiled is a demo
written specifically to fit.

Every limit behind that is known and none is fundamental:

* **16 registers per window.** `new_reg` raises past `r15`, and it
  raised four times while writing `board_demo` alone. `notes/26`
  entry 22. Every workaround is the same workaround — split the
  function — and a 16 KLOC application cannot be written that way.
* **512 bundles of code memory** on the board, 9-bit program counter.
* **128-cell semispaces**, so a 714 k live set is not in the room.
* **One module.** The front end compiles the user's module plus a
  prelude. There is no `call_ext`, no export table, no code loading —
  `notes/42` designs BEAM's two-version rule and nothing implements it.

So the honest reading of the scoreboard is that picoBEAM has gone
deeper than ECOMP on what an Erlang machine *is* — the runtime in
gates, real closures, maps, binaries, supervision, a collector — and
has not gone anywhere near as far on what an Erlang machine has to
*hold*. They ran an application. We run demos.

### Rows that are simply absent

ETS, external IO beyond the debug UART, `register`/`whereis`, and
distribution. `register`/`whereis` is the one `notes/30` left standing
and it is the cheapest of the four: it needs a VM-global name table,
which across two engines means a ring protocol, which is the same
subsystem cross-engine signals need. Doing them together is the
sensible order.

## What this changes about what to do next

Nothing about the direction, and one thing about the order.

The four ALU op bytes and the three wired-but-unexercised ops are an
afternoon and should stop being carried forward from note to note.

Everything else on this page argues for the same next move: **make the
machine hold a program**. Registers first, because sixteen is the limit
that bites while writing ordinary code and the one that cannot be
worked around; then `call_ext` and an export table, because one module
is not a system; then cross-engine spawn and signals, because two
engines that cannot talk are one engine and a spare.

A concurrent collector is the row where ECOMP is genuinely ahead of us
on paper, and it should stay on the list — but a collector that never
stalls a mutator running a 414-bundle demo would be optimising the part
that is already fast.

## Sources

* R. Tjärnström (Ericsson Radio), P. Lundell (Ericsson Telecom),
  *ECOMP — an Erlang Processor*, Erlang User Conference 2000.
  `erlang.org/euc/00/processor.ppt`
* T. Lindgren, erlang-questions, July 2005, on why it stopped:
  *"what was missing was a large enough market for Erlang-controlled
  ASICs."*
* J. Armstrong, *A History of Erlang*, HOPL III, 2007 — for the absence
  of any mention of it.
