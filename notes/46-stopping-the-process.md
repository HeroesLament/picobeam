# 46 — Stopping the process, not the world

`notes/45` put one row on the scoreboard where ECOMP is ahead of us on
paper: *"Real-time GC performed concurrently in hardware."* Ours is
`notes/41`, titled *Stopping the world*, and it means it — ≈490 cycles
of pause every ≈6,400, about 8%, almost all of it a serial root walk.

This is the design for closing that row. It is not Baker, it is not a
read barrier, and it does not need either — because of a property this
machine already has and has never been asked to pay off.

## The property: every heap object has exactly one owner

`send` copies. It has since `notes/22`'s postscript: a message is
serialised into flits, the flits go in the receiver's mailbox, and
`recv_take` rebuilds the term on the RECEIVER's heap. The mailbox holds
flits, not pointers, which is why `notes/41` could delete the mailbox
root port it had just built.

`spawn` copies too. `do_spawn` runs `export_term` over the staged
arguments and `spawn_serialized` imports them onto the child's heap —
BEAM's semantics exactly, and for BEAM's reason.

So on a picoBEAM engine, **no pointer is ever held by two processes.**
The heap is shared as an arena; the object graphs in it are disjoint.

That is the whole design. Once a process's object graph is private,
collecting it does not need the world stopped — it needs *that process*
stopped, which is what BEAM does and has always done.

## The design

Four changes to the algorithm, none to Cheney itself.

**1. Collection is triggered, not blocking.** Today an allocation that
would cross the semispace boundary parks the allocating context
(`gc_park`), stops the engine, and replays the bundle afterwards. In the
new scheme that allocation does not stall: crossing the boundary sets
`gc_active`, moves the allocation base to to-space, and the bundle
proceeds into to-space in the same cycle. From-space stops growing; the
mutator has a whole fresh semispace to run in while the collection
happens.

**2. A process is collected WHOLE, and only it parks.** The schedule
walks the process table. For each live process in turn: quiesce its own
background workers, park its context — `BarrelSeq` state 17 already
exists and already does this for `gc_park` — evacuate its roots, run the
Cheney scan over what that evacuation produced, and unpark it.

The other three seats issue for all of it. A process that is swapped out
does not even need parking: it cannot run, so its saved registers and
frames are already stable, and that is most of the thirty-two slots and
most of today's 490 cycles.

**Whole matters, and it is the subtle part.** Evacuating a process's
ROOTS is not enough. A copied object's *contents* are still from-space
pointers until something scans them, so a process whose roots had been
rewritten could immediately `tget` a from-space pointer back out of a
to-space object and hold it in a register that had already been scanned.
That is exactly the hole Baker's read barrier exists to plug. Running
the scan to completion before unparking closes it instead: when the
process resumes, everything it can reach is in to-space, and there is no
path by which it can ever see a from-space pointer again. It is BEAM's
per-process collection, and it is why BEAM needs no barrier either.

**3. Nobody else allocates while one process is being collected.** The
scan terminates when its cursor catches the bump pointer, and a mutator
appending to to-space moves the bump pointer. So for the duration of one
process's scan the allocation port is held: a process that tries to
allocate parks until the scan finishes, and a process that does not
allocate never notices.

This is the honest cost of having no write barrier, and it is worth
naming precisely. Today every process stops for the whole collection.
Under this, a process stops for its OWN collection, and stops for
somebody else's only if it tries to allocate during it — where "it" is
one process's live set rather than the engine's entire root space. A
barrier would remove even that, and is the obvious version 2.

**4. The flip is bookkeeping, not an event.** The collection is complete
when every live process has been collected. From-space is then dead and
becomes the next to-space. There is no moment at which the world must be
still.

## Why no barrier is needed at all

Three facts, and they compose:

* a process's object graph is private, so nobody else can be holding a
  pointer into what is being moved;
* a process is parked while its own graph is moved, so its registers and
  frames cannot change under the scan;
* the whole graph moves before it resumes, so it can never observe a
  from-space pointer afterwards.

Baker needs a read barrier because his mutator runs against a heap that
is half-copied. Here it does not: from the mutator's point of view its
own heap is copied atomically, exactly as BEAM's is.

## What has to change first, and it is a bug

The design needs one question answerable in one cycle: **is this pointer
in from-space?** During a collection both semispaces hold live data —
unscanned processes' objects in from-space, scanned processes' objects
and every fresh allocation in to-space — so a pointer has to say which.

It cannot say, today. From `heap.ex`:

    pcell = pa[6..0]                      # seven bits
    ... space * 128 + aptr[6..0]          # the space comes from a register

The gates carry a pointer as a cell index **within the active
semispace**, and the space bit lives in a register beside it. The model
does not:

    def cons(word_addr), do: make(:cons, cell_of(word_addr))
    # alloc returns e.hp, which starts at space * heap_words

`Machine`'s pointers are **absolute** — cell 0..255 across both spaces.
The gates' are relative — 0..127, always.

The two agree in semispace 0, and semispace 0 is the only place a
program that has never collected has ever been. `mk_ptr.exs`, the oracle
that exists specifically to compare raw pointer values, allocates four
objects and stops.

`scripts/mk_ptrgc.exs` is that test on the other side of a collection —
hold one cons alive, allocate two hundred cells of garbage past it, and
`out` the survivor's pointer before and after:

    FAIL tick 1: gates 300000000, model 300000080

Cell 0 against cell 128. The model moved the survivor to the far
semispace and said so; the gates moved it and did not.

This is not a wrong answer. Both sides are internally consistent, both
sides read back `[1 | 2]` correctly, and every test in a 62-testbench
gate passes. It is a wrong *representation*, and it has been invisible
because nothing ever printed a pointer after a collection.

It is also `notes/26`'s oldest failure class for the sixth time: a fact
decided in one place and copied into another. The cell-versus-word
argument between `Machine` and `RTL.Heap` was `notes/26` bug 5, fixed by
moving the model to cells. The space bit is the same argument one level
down, and it survived the fix.

**The gates go absolute.** A pointer becomes an eight-bit cell address
over the whole 256-cell arena, which is what the model has always said
and what a pointer physically is. `aptr` becomes an absolute bump
pointer, `space * 128 + aptr[6..0]` becomes `aptr`, the collector's
to-space cursor starts at `to_base` instead of zero, and "is this
pointer in from-space?" becomes `ptr[7] == from_space` — one bit, one
comparator, available in the cycle the barrier needs it.

## The order of work, and what the first three steps found

1. **`mk_ptrgc.exs` in the gate as a failing test.** Done — the failure
   above is it.

2. **Absolute pointers** in `heap.ex`, `collector.ex` and the engine's
   flip path. Done. `mk_ptrgc` is green and reports `[0x300000000,
   0x300000080, 1, 2]` — cell 0, then cell 128 — matching the model word
   for word.

   It cost two width bugs of the class `heap.ex`'s own moduledoc warns
   about, and both are worth writing down because both were silent:

   * `lim_c = to_base + CELLS` is an **eight-bit** add, and 128 + 128 is
     zero. EHDL reproduces Verilog's self-determined width rule, so the
     result takes the operands' width and not the target's. An overflow
     limit of zero means every collection overflows on its first object,
     reclaims nothing, and the engine collects forever. Widen before
     adding — which is exactly what `aptr9 = aptr; need9 = aptr9 + ...`
     three modules away already does, with a comment saying why.
   * A bump pointer has to represent **one past the end**, because that
     is what "full" looks like. One past the end of a 128-cell space is
     128 and fits in eight bits; one past the end of a 256-cell arena is
     256 and does not. At eight bits `aptr` wrapped to zero and the
     allocator started handing out cell 0 of the semispace it had just
     left. Nine bits, in `Heap`, `Collector` and the engine's flip path.

3. **A from-space filter on every pointer the collector follows.**
   `ptr[7] == from_space`, and it is not an optimisation.

   `RTL.Heap` does not write the pad word an odd-word object leaves
   behind — `Machine` does, which is `test/heap_pad_test.exs` — so an
   even-arity tuple carries one word of whatever used to live there.
   Under relative pointers that stale word was always read as a
   from-space address, and following it could only waste a copy. Under
   absolute pointers it can name a live **to-space** cell, and following
   it copies live data as if it were garbage and leaves a forwarding
   word in the middle of it. One bit of comparison, and it is the same
   bit the concurrent collector runs on.

4. **The concurrent collector in `Machine` first.** Done. The model is
   the oracle every netlist test compares against, so it cannot be the
   thing that follows.

   `collect/3` is gone. In its place: `gc_begin/2` moves the allocation
   base and marks every live process pending; `collect_slot/4` collects
   one process whole; `gc_gate/4` refuses to let a process allocate into
   to-space before it has been collected; `gc_tick/2` collects one
   pending process per cycle so a collection finishes even when nobody
   is asking; `gc_finish/2` drops from-space, so a pointer that should
   have been rewritten and was not raises out of `Map.fetch!` instead of
   returning plausible garbage.

   A process that has NOT been collected yet is safe to RUN — from-space
   is still there and its pointers still address it. Only allocation is
   gated. That is the whole difference from stopping the world.

   Seventy-five model tests, no failures, and every generator gives the
   answer it gave before, collection counts included: `ptrgc` one,
   `scanptr` three, `gcloop` twelve, `board` none. For a single-process
   program the new scheme is bit-identical to the old one, pointer
   values included, which is what makes those comparisons meaningful.

5. **The per-process schedule in `RootWalker` and the engine FSM**, and
   the pause MEASURED rather than asserted — per process and per
   collection, against the ≈490 cycles `notes/41` recorded.

   `RootWalker` has its one-process mode (`one_en`, `one_slot`): it
   seeks straight to the target rather than stepping through thirty-one
   slots that are not it, which is where the 490 cycles actually went.
   `Collector` has `start_hp`, because a collection is now a sequence of
   per-process collections sharing one to-space and the cursor cannot
   restart at the bottom each time. `Heap` has `flip_space`, because
   moving the allocation base at the START of a collection and adopting
   the collector's bump pointer after each PROCESS are two different
   operations that `flip_en` used to be both of.

   All three are wired to reproduce today's behaviour exactly, so the
   gate stays green while the FSM that drives them is written.

## The register file, and why it did not end up mattering

Walking a RESIDENT process's registers looked like the hard part.
`RegWindowCtx` has six read ports and three write ports and **one**
`rd_ctx`: the context is selected once and everything reads within it,
and the pipeline selects it every cycle.

Two answers were designed and neither was built.

**Eviction.** A process being collected is a process that is not
running, so give up its seat: `SeatUnit` already drains a window to the
save area, and `RootWalker` reads the save area and the frame RAM
through dedicated ports the pipeline never touches. It is the right end
state and it is not a first version — `SeatUnit` owns the deschedule
policy, and an evicted runnable process goes back on the run queue where
it could be seated again and restore from the very save area the walker
is rewriting. That wants a hold and a release, not an `ev_req`.

**A grant line.** Only the ADDRESS cycle needs the port, so one `grant`
input landing on the parked context's own rotation turn would cost about
two cycles a word. Also not built: it needs six separate grant
conditions — read turn, write turn, save-RAM read, save-RAM write, frame
read, frame write — and each one wrong is a silent corruption rather
than a failure.

What was built instead is the freeze, per process. States 3..6 stop the
engine; state 2 does not. The register file needs no arbitration at all
because nothing else is running when the walker has it, and the measured
result below is what that is worth. Both of the above stay available
for the version that wants the pause to go to zero rather than down by
four.

## It runs, and here is what it cost

Same program — `priv/demo/gc_conc.ex`, four processes churning a 2-tuple
each through one 128-cell semispace — on the old collector and the new
one:

```
                    stop-the-world      per-process
collections                    4                 4
pieces                         4                20
total frozen               5,234             5,209
MAX PAUSE                  1,334               350
total cycles              10,170            10,109
frozen                       51%               51%
```

**1,334 cycles to 350.** Total frozen time is the same to within half a
percent and so is total runtime, which is the honest shape of this: it
is the same work, cut into pieces, with the engine running at full speed
between them. What changed is the longest time any process waits, and
that is the number `notes/05` cares about. With four processes it is
3.8x; it should scale with the process count, because the pause is one
process's roots and live set rather than the engine's.

`gcloop` cannot show this and never could — it is one process, so the
engine has nobody to run while it collects. `mk_gcconc.exs` is the
program that can, and it is a permanent gate entry.

### The engine FSM as built

```
0 idle
1 begin   quiet the background workers, then MOVE the allocation base
          to to-space and mark every live process pending
2 gap     RUN. Not frozen. Leaves when the cursor lands on a pending
          slot and either the gap is served or somebody is parked
3 settle  frozen, waiting for quiet again
4 walk    one process's roots
5 scan    Cheney, to completion, before it resumes
6 adopt   take the collector's bump pointer back, clear the bit
```

`gc_slot` is a rotating cursor advanced one slot per cycle in state 2 —
the state where the engine is running — so "which slot next" needs no
priority encoder and costs nothing. The pause is states 3..6.

The `rw_grant` line the previous draft of this note specified was not
built and is not needed: the engine freezes for one process's turn
rather than arbitrating six ports against a running pipeline. That is
incremental rather than concurrent, and it is the right first version —
the hard SEMANTIC work is the per-process decomposition, and relaxing
the freeze one port at a time is a microarchitecture follow-on that can
have a test each.

## Three bugs, and they are all the same bug

Every one of them is a place where **"a collection is running" and "the
pipeline is not using this port" used to be the same question.** Under a
stop-the-world collector they were. They are not any more, and every
line that assumed it had to be found.

**The port muxes were on `gc_active`.** State 2 *is* a collection and is
also the engine executing at full speed, so the walker was handed
register-file port 0 while four contexts were using it. Every D-stage
read got the walker's word and every X-stage write went wherever the
walker was pointing.

**`gc_busy` was not enough either.** Freezing the engine stops FETCHING;
the bundles already at D and X take another eight cycles to retire, and
states 1 and 3 exist to wait for exactly that. Handing the port over on
the FIRST cycle of the freeze gave those in-flight bundles the walker's
word instead of their own register — a `tset` read 42 as its tuple
pointer and died of `bad_tag`, an `add` read a pointer and died of
`badarith`. It is `rk_busy` now: the walker is only busy in state 4, by
which time the drain has happened. That handover point was always
available and the design never named it.

**A `heap_full` during state 1 was a real fault.** State 1 waits for
quiet, and the allocation base has not moved yet, so an allocation
retiring in that window is asking for room that is about to exist. It
parked under the old design because the old design had no state in which
a collection was running and the base had not moved. Killing whichever
process happened to be mid-allocation when somebody ELSE's collection
started is not a failure mode that existed before.

And one self-inflicted, worth writing down because it is a shape that
recurs: gating the heap's `cmd_en` on the whole of `gc_park` closes a
**combinational loop**, because `gc_park` reads `heap_full` and the
store computes `heap_full` from `cmd_en`. Only the gated half of the
park needs to suppress the store — the `heap_full` half is already a
no-op inside it — and that half does not read the fault.

## One thing the oracle stops being able to say

Pointer VALUES are only comparable between model and gates for a
single-process program.

With one process the new scheme is bit-identical to the old one: the
collection starts, the only process parks for its own graph, nothing
else is allocating, and every object lands exactly where it lands today.
`mk_ptr` and `mk_ptrgc` stay honest.

With two, where an object lands depends on how far the collector had got
when the other process allocated, and model and gates would have to
agree cycle for cycle about a collector's progress to agree about an
address. They do not and should not — `notes/28` made the same argument
about `to_hp` and answered it the same way. The oracle for a
multi-process program is `out`, which is behaviour, and behaviour is
what a collector is allowed to preserve.

## What this does not claim

It does not make the collector stall-free. A process still stops for its
own roots and its own live data, and an allocating process still stops
for somebody else's — which is BEAM's bill plus a barrier we have not
written. Bacon's collector stops nothing at all, and this is not that.

What it claims is that the pause becomes proportional to ONE process's
live set instead of the whole engine's root space, that a process which
is not allocating never stops for anyone, and that the twenty-eight
swapped-out slots which make up most of today's 490 cycles stop nobody
at all.
