# 22 — The heap comes back, and messages become terms

`notes/17` decision 5 said: immediates first, the serialiser second.
The serialiser needed the heap, and the heap had been deferred out of
the barrel engine at M3 pass 8. This is both, plus the wire format that
had to exist between them.

## The heap had never been run

`heap.ex` was written at M2 and never instantiated. `scripts/tb_heap.v`
is the first thing to ask it a question, and it found three bugs before
it found any working behaviour — all of them the `notes/21` width
lesson, one level down:

* `tsw = i8[3..0] + 1` is a **four-bit** add. `tset` at index 15 — the
  ceiling `encoding.ex` explicitly permits — wrapped to word 0 and
  **overwrote the tuple header**.
* `tgw = i8 + 1` and `alloc_cells = (i8 + 2) >>> 1` are eight-bit. A
  255-arity `mktup` computed **zero** cells and sailed past
  `heap_full`; the bump comparison `aptr + alloc_cells > 128` wrapped
  at 256 for the same reason.
* Every 36-bit tag literal in it — `0x300000000` for a CONS pointer,
  `0x400000000` for a TUPLE, `0x900000000` for the tuple header — was
  being truncated to **zero** by the ehdl const-width bug. Before
  `notes/21`, every pointer this unit produced was tagged INT.

The third one is the interesting one, because it means the heap was
broken in a way no testbench of the heap alone would have caught if it
had been written earlier: it was broken by its *dependency*, silently,
and the only reason it surfaced is that the fix landed first.

## The wb2 turn, and the fourth per-seat latch

A bundle carrying a heap op sets `has_wb2`: the context's next turn
fetches nothing and its X slot strobes `wb2_en`, so the late result
lands through port 0 — which that context owns on that cycle by the
rotation. `BarrelSeq` has had this since M3 pass 3; what was missing
was the plumbing.

The result cannot be read at the wb2 turn. Four cycles have passed and
the heap's sync reads have moved on. So `rd_late` is captured into a
per-seat latch the cycle AFTER the command, alongside its destination
register, and the wb2 turn only moves what is already in hand.

**That is the fourth time.** The ret value, the spawn pid, the peeked
mailbox word, and now the heap result: every one of them a value
produced at one moment and consumed at another, and every one of them a
bug until it became a per-seat latch. In a barrel, *later* means
another context's cycle. It is worth stating as a rule rather than
rediscovering it a fifth time.

`tset` is the exception that had to be named. It writes the heap and
produces nothing, and its `rd` field is zero — so granting it a wb2
turn would have written a stale word into r0 of whatever process ran
it. It gets no wb2 turn at all, which is also correct on cost.

## The wire format: postfix, and why that is the whole design

`PicoBEAM.Serial` defines it once, in Elixir, and the RTL has to agree
— the discipline the opcode table and the shape hash already get.

    42                  ->  [42]
    {1, 2, 3}           ->  [1, 2, 3, HDR|3]
    [1 | 2]             ->  [1, 2, WCONS]
    {1, [2 | 3]}        ->  [1, 2, 3, WCONS, HDR|2]

Reverse Polish, and the reason is on the receiving side. In **prefix**
order a reconstructor meets `HDR|3` before it has any of the three
elements: it must allocate the tuple and then patch it as they arrive,
which means a stack of half-built cells and, per cell, a write-back
position. In **postfix** every marker arrives with its children
finished on a value stack, so rebuilding is:

    an immediate  ->  push it
    HDR|n         ->  mktup, tset n values off the stack, push
    WCONS         ->  pop tail, pop head, cons, push

One heap op per marker, nothing allocated before it can be filled,
nothing revisited. The cost moves to the sender as an explicit
traversal stack — but the sender needs a traversal either way, so
postfix buys the receiver's simplicity for free.

`WCONS` is the one wire-only tag (`0xD`). Tuples need no equivalent
because they already *have* a header word on the heap, and the
serialiser simply emits it.

## Two passes, because a partial message is worse than a slow one

`SerUnit` walks the term twice: pass 0 counts, pass 1 emits. That is
twice the heap reads, and it is the right trade twice over.

* The mailbox stores a message's **length** in its head entry, which is
  what lets the match unit step over a whole non-matching message. A
  one-pass serialiser would have to write the head first and patch its
  length afterwards.
* **Atomicity.** With the count in hand, the engine compares it against
  the mailbox's `free` *before anything is written*. A message that
  does not fit is refused whole. A one-pass-and-patch serialiser can
  discover it is out of room with half a message already in the
  receiver's ring — and the receiver would then match a head whose
  continuations never arrived.

## Entries are flits, and the mailbox had to learn the difference

`hv` went from `{valid, hash:8}` to `{valid, head, len:6, hash:8}`. The
`head` bit is not bookkeeping; it is a correctness requirement. Without
it, the second flit of `{ok, 5}` — a bare `5` — could hash-match a
filter looking for a fixnum and hand the receiver **the inside of
somebody else's message**. `tb_m4_mailbox.v` now enqueues a three-flit
message whose continuations deliberately carry the hash of the message
after it, and checks that the matcher steps over them.

`full` also became `free`: an enqueue of an n-flit message needs n
contiguous entries, and a boolean cannot answer a question whose
threshold varies.

## What it costs

| | |
|---|---|
| `SerUnit` | 8-deep traversal stack, two states per heap read |
| `DeserUnit` | 64-deep value stack — bounded by the 63-flit message cap, so it can never overflow and needs no check of its own |
| a 4-tuple of immediates | ~30 cycles to serialise (both passes), ~25 to rebuild |
| depth limit | 8 nested compounds, `:system_limit` |
| message limit | 63 flits, `:system_limit` |

Depth and width are different bounds and it is worth keeping them
apart: nesting depth bounds the SENDER's traversal stack; how many
finished siblings can be waiting for their marker bounds the
RECEIVER's value stack, and for a flat 62-element tuple that is 62.

## How it was checked

* **`tb_heap.v`** — 31 checks. Every op, both tags, `bad_tag`,
  `heap_full`, index 15, a 255-arity allocation, and the semispace flip.
* **`tb_ser.v`** — 98 checks. `mk_ser_vectors.exs` lays 11 terms out on
  a heap image exactly as `heap.ex` addresses it and writes the flit
  stream `PicoBEAM.Serial` says each flattens to; the netlist has to
  match it flit for flit.
* **`tb_roundtrip.v`** — 159 checks. serialise → deserialise →
  serialise, and the two streams must be identical. This works because
  **a flit stream contains no pointers**: the rebuilt term lives at
  different cells, so anything that leaked an address shows up
  immediately. It also asserts the rebuilt pointer differs from the
  original, so a deserialiser that cheated by handing back its input
  could not pass.
* **`test/serial_test.exs`** — 8 tests including a 500-term randomised
  round trip, plus both bounds and both malformed-stream refusals.
* **`tb_fixed:heapprog`** — the whole engine: build `[9,8,7]`, walk it,
  build a 3-tuple out of order, read it back, nest a list inside a
  tuple. `[24, true, 100, 200, -50, 3, 100]`, matching the model.

26 testbenches green; all six benchmarks unchanged to the cycle.

## Two things the gate caught that review would not have

**A generator can outlive its artifact.** Widening `tset`'s index in
the heap broke `heapprog` — because the ENGINE was passing `f3:f4` as
the index and the heap's four-bit mask had been quietly correcting it.
The mask was load-bearing for the ISA path and dead weight for the
rebuild path. It belongs in the engine: the store stays general, and
the slot encoding stays where slot encodings live.

**`0 * X` is `X`.** The one-hot-sum mux idiom this codebase uses
everywhere propagates unknowns: an unread stack entry poisoned
`stk_data` through a term that was not even selected. Harmless in
hardware, where a DPR16X4 powers up at zero — but it means every
testbench of a unit with an internal RAM must zero that RAM, and the
symptom (an FSM going X two states after the real problem) points
nowhere near the cause.

## What is left

`SerUnit` and `DeserUnit` are proven standalone and against each other.
They are **not yet wired into `BarrelEngine`** — `send` still enqueues
one word and `recv_take` still returns one word, which is why every
existing testbench still passes unchanged. Integration is: `send`
drives the serialiser and gates on `free >= count`; `recv_take` drives
the rebuild and parks its context the way the scan already does; and
the heap command port grows a priority chain with the X stage on top.

---

## Postscript: the transmit half, wired in

`SerUnit` was written, tested against the oracle, and **not
instantiated**. `SendUnit` took a single `msg_word` and enqueued it as
one flit, so `send(Pid, {a, b, c})` put the sender's *pointer* into the
receiver's mailbox. It appeared to work because there is one heap per
engine and every process on that engine shares it — working by
accident, and `notes/26` bug 1 said it would become memory corruption
the moment there were two engines.

It is wired in now, and the shape of the wiring is worth recording.

### An immediate message does not park

`send` splits on the message's tag. Cons and tuple are the only two
tags that name heap cells; everything else is its own flit and retires
at X exactly as it always did. That is deliberate and it is measured:
`b3_pingpong` is still **10,508 cycles**, byte-identical, because
ping-pong sends integers.

A compound send parks (sequencer state 15, claiming the serialiser at
the sender's own F slot the way every shared unit in this machine is
claimed), and `SerUnit` streams the term into the mailbox as flits.
`DeserUnit` — which since `notes/25` runs at the PEEK — rebuilds it on
the receiving side.

### Backpressure, not priority

The mailbox command port has three claimants now: a send retiring at X,
the exit-signal emitter, and the flit stream. The first two cannot
stall — X cannot stall, and the emitter is a fixed-length burst — so
the stream is the one that has to yield, and a flit that loses the port
must be **re-presented, not dropped**.

`SerUnit` grew a `stall` input that freezes its whole FSM. `emit` and
`emit_word` are registered, so a frozen unit offers the same flit again
next cycle and the stream is lossless.

This exposed something older: **the exit-signal emitter has the weaker
version of this and drops.** `sd_st` advances whether or not its flit
won the port, so a send retiring in the same cycle silently eats a flit
of an `{'EXIT', ...}`. At four flits the window is narrow enough that
nothing has caught it; at 63 it would have been constant. Logged rather
than fixed here — it wants the same `stall` treatment.

### Two smaller things that came with it

**The count is checked before anything is emitted.** That is what the
two-pass protocol was for: pass 0 counts and HOLDs, the engine compares
the count against the target's free space, and only then does pass 1
run. A message that does not fit dooms the RECEIVER with
`mailbox_full`, the same rule an immediate overflow already followed.
`SerUnit` gained an `abort` input so HOLD has an exit other than
`go_emit` — without it a refused message would have wedged the unit for
every later sender.

**The shape hash finally means something.** It was computed from the
message word, which for a compound message is a pointer — a number that
says nothing about the shape, making `recv_hash` filtering on a
compound message meaningless. It now comes from the root arity and
first element that `SerUnit` reports.

### What proves it

`scripts/mk_csend.exs`. A process builds `{7, [8|9], 9}`, sends it to
itself, and reads it back. Sending to yourself is not a weakened test:
the message still leaves as flits and comes back rebuilt at a
**different heap address**, which is the entire point. It just removes
spawn and scheduling, so a failure means the transmit path.

    sender's pointer   400000001   (cell 1)
    receiver's pointer 400000004   (cell 4)
    elements           7, 9, 8, 9   arity 3

Compared word-for-word against the model — pointers included, which
only became possible when the oracle was repaired the same day
(`notes/26` bug 5). Doing those two in that order was the difference
between a checkable result and a plausible one.
