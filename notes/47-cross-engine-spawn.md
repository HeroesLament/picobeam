# 47 — Cross-engine spawn: the decision, and the honest scope

`notes/29` ended cross-engine spawn with a sentence rather than a
subsystem: *"That is a new path through `SeatUnit`, not a new packet
kind. The options are roughly: give the spawn drain a second source that
the ring can drive; or land the args on the heap first and hand the new
process a term. The first is cheaper and the second is closer to what
the model does. It wants deciding before it is built."*

This note decides it, sizes it, and records what got built now and what
did not.

## What got built now: placement

`Machine` placed every spawn with a machine-global counter:

```elixir
target = rem(m.spawn_rr, m.n_engines)
```

No engine can implement that. Hardware has no shared state to
round-robin over, and two engines spawning in the same cycle would have
to agree about whose turn it was. It is a model-only rule, and it would
have had to change the day the gates grew the feature — at which point
every two-engine comparison would have moved.

It is per-engine now, and round-robin from HOME:

```elixir
target = rem(eid + e.spawn_rr, m.n_engines)
```

Each engine needs a counter and nothing else. It starts LOCAL, so a lone
spawn stays where its arguments already are. And on a one-engine machine
it reduces to "always here", which is every model-versus-gates test in
the gate today — so this change is free until the second engine arrives,
and correct when it does.

In the gates it is `param :N_ENG, default: 1` and a four-bit counter:
`(eng_id + sp_rr) rem N_ENG`. With the default it folds to `eng_id`, and
every existing testbench is untouched.

## The decision: the arguments cross as one term

`notes/29`'s two options, weighed.

**Give the spawn drain a second source.** A local spawn drains sixteen
words out of the requesting context's staging bank into the newborn's
save area. The ring would drive the same drain with words off the wire.
Cheap — and wrong, because a word off the wire is not a term. A
compound argument arrives as FLITS, and a flit is not something you can
put in a register: it has to be rebuilt on THIS engine's heap first,
because the pointer inside it names the sender's heap and this engine
cannot read that. The option is only cheap for immediate arguments, and
"spawn works unless you pass a list" is not a feature.

**Land the args on the heap first.** The receiving engine already owns a
unit that turns flits into a heap term — `DeserUnit` — and it already
reads its flits out of a mailbox, which is exactly where the ring
ingress already puts arriving flits. So the args cross as ONE serialised
term, the arity-N tuple of them, and the receiver does what it already
does for a message.

**Decided: one term.** Not because it is cheaper — it is not — but
because it is the only one of the two that is `spawn/3`. It is also what
`Machine.do_spawn/6` does: `export_term` over the arguments,
`spawn_serialized` to import them. The two sides stay the same
algorithm.

The sender pays for it: it has to build the args tuple on its own heap
before it can serialise it, which is a `mktup` plus N `tset`s
micro-sequenced through the heap command port. `dz_grant` is the
precedent — the deserialiser already drives that port on cycles the X
stage is not using — and this is the same shape in the other direction.
It also means a remote spawn can trigger a collection, so it takes the
same `dz_fits` room check the rebuild takes.

## The build, in the order the pieces unblock each other

**1. `SeatUnit` gains a remote creation.**

```
input  :rsp_req, 1        # create a process at rsp_pc, whoever asked
input  :rsp_pc, 9
output :rsp_ok, 1         # taken this cycle
output :rsp_slot, 5
output :rsp_serial, 22
```

Everything under it exists. `spawn_commit` already allocates a table
slot, pushes the newborn on the run queue, and names it; a remote
creation is that minus the staging drain and minus the pid write-back,
with the pc coming off the wire instead of from `BarrelSeq`. It needs
one new state — sixteen cycles zeroing the newborn's save area, because
nothing drains into it and a save area full of a dead process's
registers is a set of GC roots that would resurrect its garbage.

**2. Two ring packet kinds.** `spawn_req` carries the entry pc and the
arity in the head word — nine bits and four, in a thirty-six bit field —
followed by the args tuple's flits. `spawn_rep` carries the child's
full PID back. `notes/29` defined nine kinds and implemented one; this
is two more, and the ingress already routes on `rg_kind`.

The ring egress currently has exactly one producer, the serialiser.
These are a second, and it wants an arbiter rather than a mux: a reply
must not be able to interleave into the middle of somebody's message.

**3. The receiver's spawn FSM.** Allocate a slot; point the ring
ingress's mailbox enqueue at the NEWBORN's mailbox rather than at the
packet's destination pid; run `DeserUnit` over those flits to rebuild
the args tuple on this heap; read its N elements out with the heap port
and write them into the save area; set the pc; push to the run queue;
reply with the pid.

**4. The sender's park.** This is the piece with the least existing
support and it is the reason this note stops here rather than
continuing. A remote spawn must park the requesting context, and resume
it with the pid in `rd` and the pc ADVANCED — not replayed. Every park
the machine has today replays: `gc_park` exists precisely so a bundle
can run again against a compacted heap, and `notes/40` calls that out as
the only park in the machine that repeats. A spawn that replays spawns
twice.

The mechanism for "resume with a value and move on" does exist — it is
what `ftgt_en`/`ftgt_seat`/`ftgt_pc` does for `callfun` and what
`bad_en`/`bad_seat` does for a badarity — but it is four replicas of
`BarrelSeq` away, and `BarrelSeq` is the module where a mistake is
four identical mistakes.

## What this is honestly worth, and what it is not

Without it, a two-engine picoBEAM is two engines each running their own
process tree, with messages crossing between them. That is a real
machine and `tb_ring2` proves it. It is not a two-core BEAM, because a
program cannot place work on the other core — `notes/44` put it as "two
engines that cannot talk are one engine and a spare", which was too
harsh: they talk. They just cannot hand each other work.

The gap is one subsystem, it is designed here, and the placement rule it
needs is already in the model and already agrees with what the gates
will do. What is left is four state machines and a two-engine testbench
that compares against the model — `tb_ring2` cannot be that test,
because it boots two DIFFERENT images and a cross-engine spawn requires
both engines to hold the same one.

---

## Postscript, after `notes/49`: the fourth piece was not there

This note sized four pieces and stopped at the fourth — the sender's
park, "the piece with the least existing support", four replicas of
`BarrelSeq` away.

It does not exist, and it never needed to. **Spawn park (state 9) is
already a park that resumes with a value and advances its own pc**; it
was built that way for a local spawn, whose answer arrives in one cycle,
and nothing in it cares how long the answer takes. `BarrelSeq` gained
one line — `spawn_park = cur_state == 9`, the question exposed
separately from the answer — and the rest is engine-level muxing.

The piece estimated highest was the piece that was already built. Look
at what a park already does before designing a park.

Two other things in this note moved. The arguments do NOT cross as one
serialised term today: the placement rule sends a spawn remote only
when every argument is immediate, and immediate arguments *are* the wire
format, so no serialiser and no `DeserUnit` are involved. The general
path designed above is still the general path and is still unbuilt.
And the sizing missed a bug that had nothing to do with spawn: a
message off the ring never woke a blocked process (`notes/26` entry 31).

`notes/49` is the account of what got built.
