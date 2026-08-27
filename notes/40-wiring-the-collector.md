# 40 — Wiring the collector

`notes/28` built a Cheney collector and proved it standalone. It has
never been instantiated. `hp_flip` is wired to the constant 0 and the
engine's heap has been a 128-cell arena that fills up and faults.

That is now the thing in the way of everything: maps allocate, closures
allocate, and a feature that dies of `heap_full` after thirty iterations
is a demonstration, not a feature. This note is the design for
integration, and it starts with a bug found while reading for it.

## Tag 7 was going to eat the first closure

`Collector` decides whether a heap word is a forwarding pointer with

```elixir
fwd_hit = q0_tag == 7
```

and its moduledoc explains, at length and correctly for the day it was
written, that 7 is free.

`Term` says:

```elixir
fun: 0x7,
bin: 0x8,
hdr: 0x9,
fwd: 0xA,
```

Seven is `:fun`. The tag table moved and the RTL's copy of it did not,
and nothing broke because **no program can currently make a fun** — the
one term that would have collided is the one feature nobody had built.
The first closure to survive a collection would have been read as a
forwarding pointer, and the collector would have followed its payload
into whatever cell that number happened to name. A silent wrong answer,
armed and waiting for a milestone two tasks away.

This is the third time this project has found the same shape: a value
decided in one place, copied into another, and drifting
(`notes/30`'s atoms, `notes/34`'s parameters, and now tags). So the fix
is not to change a 7 to a 10:

```elixir
param :T_CONS, default: PicoBEAM.Term.tag_value(:cons)
param :T_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)
param :T_FWD, default: PicoBEAM.Term.tag_value(:fwd)
```

Module attributes are compile-time Elixir and do not survive into a
`comb` block, so the tags reach the datapath as params — which
elaboration folds straight back to literals. It costs nothing but
correctness. `tb_gc` passes unchanged, which is the point of having had
it first.

Every other RTL module still spells its tags as numbers —
`deser_unit`, `ser_unit`, `send_unit`, `shape_hash`. Those are correct
today and are the same accident waiting; sweeping them is a separate,
mechanical job.

## The pad word, and why the oracle was wrong about it

Written before any of the above was built, as the first thing that
happened when a program was pointed at a hardware-sized heap.

`HeapStress` builds a fresh 2-tuple every iteration and keeps only the
newest — one live cell, one cell of garbage per turn, four hundred
turns through a 128-cell semispace. On the model, with `heap_words: 256`
to match the engine, it died:

```
** (KeyError) key 259 not found in: %{256 => ..., 257 => ..., 258 => ...,
                                      260 => ..., 261 => 0, 262 => 0}
```

The heap allocates whole CELLS. A 2-tuple is three words — a header and
two elements — in two cells, and the fourth word is **pad**. `alloc/3`
bumped `hp` by `cell_round(3) = 4` and wrote three words, so word 259 was
never written at all. Cheney's scan walks to-space one word at a time,
and the first even-arity tuple to survive a collection took `Map.fetch!`
through the floor.

Every GC test in the suite used cons cells. A cons is exactly one cell
with nothing left over, so the hole was never walked.

The RTL does not crash on this, and that is worse. It copies whole
cells, so the pad comes across carrying whatever the *previous* occupant
of that word left there — and if that happens to look like a pointer,
the collector evacuates it and keeps a dead object alive. A leak instead
of a crash, which is the harder of the two to ever notice, on the side
of the machine with no way to look.

The fix is the same for both: **write the pad**. `alloc/3` pads to a
whole cell with `Term.nil_word()`, and `evacuate` copies
`cell_round(size)` words rather than `size`. `nil` because it is a tag
the scan will not follow, and because a defined value is the whole
point.

`test/heap_pad_test.exs` is the program that found it, kept.

This is the class of bug the collector integration was always going to
be made of, and it was found on the model, in one run, with a stack
trace naming the word. The board would have said "it stopped".

## The roots, from the oracle

`Machine.collect/2` defines correctness, and its root set is:

```elixir
roots =
  extra_roots ++                                  # the allocation in flight
    Enum.flat_map(e.procs, fn {_, p} ->           # EVERY process, not just resident
      Enum.flat_map(p.windows, &Map.values/1) ++  # current window AND every spilled frame
        Map.values(p.out_args) ++                 # the staging bank
        Enum.map(p.mailbox, fn {w, _h} -> w end)  # message words
    end)
```

Four things, and each lives somewhere different in the machine:

| model | hardware |
|---|---|
| `extra_roots` | the per-seat latch holding the words being allocated |
| `p.windows` head | `RegWindowCtx`'s current bank for a resident seat |
| `p.windows` tail | `FrameRamProc`, slot × depth × 16 words |
| `p.out_args` | `RegWindowCtx`'s staging bank |
| `p.mailbox` | `Mailbox`, slot × 64 |

The allocation in flight matters more than it looks. It is not yet
anywhere the walker would find it, and if it is not evacuated the object
about to be built points at from-space.

## Why the walk is affordable

The worst case is terrible: 32 slots × 15 frames × 16 words is 7,680
frame words, plus 2,048 mailbox words. `notes/28` measured a collection
every ~1,140 cycles for a send loop. Ten thousand root round trips per
collection against 1,140 cycles of work would be an unusable machine.

Two things make the real case cheap, and the design depends on both:

1. **Walk what is live, not what exists.** Occupied slots only, frames
   `0..depth-1` only, mailbox entries `0..count-1` only. A two-process
   program three frames deep is about a hundred words.
2. **Filter immediates in the walker.** A root that is not `cons` or
   `tuple` cannot move, so it never needs to reach the collector. Only
   pointers pay for a round trip.

Both are the walker's job, which is why the walker is a component and
not a state or two bolted onto the engine.

## Stop the world, and the promise that breaks

`machine.ex` says, in a comment above `alloc/3`:

> TIMING NOTE: the model charges the mutator ZERO cycles for collection.
> That is the architecture's central claim (collector on port B), stated
> here as an assumption the RTL must EARN at M5.

It will not be earned this time. A concurrent Cheney collector needs a
read barrier on every heap access by every seat, which is a bigger and
much riskier machine than the one that stops.

So: **stop-the-world**, and `notes/28`'s zero-cycle claim is now a
stated divergence rather than an assumption. It is a divergence in
TIMING and not in RESULTS — the model's `out` stream is identical either
way, so every existing testbench keeps working and the oracle keeps
oracling. What changes is that a cycle count taken from the model is no
longer a prediction of the board, and `tb_bench`'s numbers acquire a
footnote the day a benchmark allocates.

The freeze mechanism already exists. `notes/33` gave `BarrelSeq` a
`frozen` input for the VM-wide halt, so:

```elixir
frozen = bor(vm_halt, gc_active)
```

is the whole of "stop the world" — with one wrinkle. `frozen` stops
FETCHING; bundles already at D and X still retire, and one of those
could touch the heap. The collector must therefore not start on the
cycle the freeze asserts but after the pipeline has drained, which with
T = 4 is two rotations. A counter, and a comment saying why it is not
zero.

## The shape of it

```
    hp_full  ──▶  gc_req  ──▶  freeze  ──▶  drain  ──▶  RootWalker
                                                            │
                                     roots one at a time ────┤
                                     rewritten roots  ◀──────┤
                                                            ▼
                                                        Collector
                                                            │
                                                       flip_aptr
```

`hp_full` stops being a fault. It becomes a request: freeze, collect,
retry the allocation, and fault with `heap_full` only if it still does
not fit — which is exactly what `alloc/3` does in the model, and the
reason both sides run out of memory on the same allocation.

## What has to be true before this is believed

`tb_gc` proves Cheney's algorithm. It cannot prove the walk. The
integration test has to be a program that survives more collections than
its heap has cells — the send loop from `notes/28`, run for long enough
that every root class has been rewritten at least once — with the
model's `out` stream as the expectation, on the netlist.

Until that exists, this note is a plan and the collector is still not
wired in.

---

## Postscript: the walker, and the root that was not there

`RootWalker` is built and in the gate (`tb_rootwalk`, 52 ok). Three of
the four root classes above are in it. The fourth is not, and finding
out why was the useful part of building it.

### The mailbox holds no roots

The table above says `p.mailbox` is a root, because in
`Machine.deliver_to/3` it is: the model calls `import_term`, which
ALLOCATES on the receiver's heap, so a queued message is a pointer.

This machine does not work that way. `send` serialises
(`SerUnit`), the mailbox stores **flits**, and `DeserUnit` rebuilds the
term on the receiver's heap at `recv`. The exit-signal emitter in
`barrel_engine` says it out loud, about itself:

> flits, every one an immediate. notes/13's allocation-free rule made
> physical: a process dying of `heap_full` can still tell its
> supervisor why, because telling it costs no heap.

Flit tags are immediates and structure — `WCONS` (0xD) and `HDR` (0x9)
— and neither is `cons` or `tuple`. A walk over a mailbox would present
**zero** roots, every time, forever, and look completely correct doing
it.

The GC port for it was built first — an addressed write beside the
deserialiser's read, plus a mux to give the walker the entry store's
`valid`/`head`/`len` so it could step message by message the way the
scan does, because `[head, head+count)` is not the live set: `take` on
a middle message tombstones only that message's head entry and leaves
its continuations in the span. All of that was correct, and all of it
was deleted, because the thing it walked correctly contained nothing.

That is the same shape as this note's opening bug from the other side.
Tag 7 was a copy of a decision that had drifted; the mailbox walk was a
copy of a decision — "the mailbox is a root" — that was never true
HERE. Both look right in the file you are reading and are wrong against
the machine.

The consequence is on the scoreboard as `notes/26` entry 15: the model
and the machine hold different amounts of heap for the same program.
The day a flit can carry a heap address — a refc binary shipped by
reference is the obvious candidate — the mailbox becomes a root again,
and the port comes back with a test.

### Resident or swapped out, never both

The other thing the walk has to get right, and the one that would have
been a silent leak. A process's current window is EITHER a bank of
`RegWindowCtx` (it holds a seat) or sixteen words of `SeatUnit`'s save
area (it does not). The other copy is stale, and a stale save area
still points at everything the process was holding when it was evicted.
Walking both resurrects all of it.

So the walker takes `seat_val` and the four seat slots from `SeatUnit`
and `live_vec` from `ProcTable`, and walks exactly one of the two. The
staging bank is walked only for resident seats, for the same reason:
eviction drains `cur`, not `stg`.

`tb_rootwalk` checks this by asking every location in a modelled
machine whether it was visited — including a dead slot with four frames
and two resident slots whose save areas must not be touched — rather
than only checking that the ones that should be visited were.

### What it costs

Every source is a sync read, so a word costs two cycles to fetch. An
immediate stops there: the filter is in the walker, and most of every
register window is integers, atoms, pids and return addresses. A
pointer costs those two plus the collector's round trip plus one
write-back. Skipping a dead seat, a dead slot or a slot that has run
out of frames costs one cycle each.

### Ports it borrowed rather than built

Nothing here added a memory port that costs BRAM, because the barrel is
frozen while it runs and the ports it needs are therefore idle:

* `RegWindowCtx` — read port 0, with one new mux (`rd_stg0`) so it can
  reach the staging bank. Not an eighth replica of twenty-one memories.
* `SeatUnit` — the restore path's read address, muxed; the save RAM's
  single write site, shared.
* `FrameRamProc` — the spill port's write site, shared, plus the
  addressed read it already had.

`ProcTable` gained `live_vec` and `SeatUnit` gained `seat_val`: both are
a register beside one that already existed (`doom_vec`, `sslot*`), and
both exist so the walk does not have to spend thirty-two round trips
asking who is alive before it can present a first root.

## Still to do

The walker enumerates; nothing yet calls it. Integration needs:

1. `hp_full` to become a request rather than a fault, which means the
   allocating bundle must PARK and re-execute — a new `BarrelSeq` state
   in all four seat replicas.
2. Quiescence, not just a drain counter. `frozen` stops fetching, but
   `SerUnit` owns heap port B — the collector's port — and a background
   window drain, a mailbox scan and the signal emitter all keep running.
   The collector must start on "the machine is quiet", not on "four
   cycles have passed".
3. The flip, and `hpb_space` for `SerUnit`, which has been reading the
   active semispace through a bit that has never changed.
