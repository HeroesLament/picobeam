# 28 — The collector, and why it stopped being optional

`heap.ex` has carried `flip_en` and an unused port B since M2, waiting
for this. `Machine` has modelled the algorithm since M1. What changed
today is that the machine started producing garbage fast enough to
care.

## The measurement that set the scope

Until `notes/22`'s postscript, `send` shipped a POINTER, so a compound
message cost the receiver nothing — there was nothing to allocate. Now
every received compound message is a fresh copy on the receiver's heap.

Measured on the model, a loop that sends a 3-tuple to itself:

| semispace | collections in 40,000 cycles | one every |
|---|---|---|
| 128 cells | 35 | ~1,140 cycles |
| 512 cells | 8 | ~5,000 cycles |

Without a collector that loop dies of `heap_full` after about thirty
iterations. Growing the heap four times over buys four times the
runway and fixes nothing.

The same measurement said what to optimise, and it was not what I
expected. **Live data at each collection is 8 words.** The copy is
nothing. The entire cost of a collection here is walking the ROOTS,
which is a fixed price whatever survives — so the design question is
not "how fast can we copy" but "how few roots can we get away with
enumerating".

## What is built: the algorithm, not the policy

`PicoBEAM.RTL.Collector` is Cheney copying between the two semispaces,
and it deliberately does **not** know where roots live. They are spread
over the register windows, the frame RAM, the mailboxes and a dozen
per-seat latches, and teaching this unit about all of that would make
it untestable. Instead the engine streams roots in one at a time and
gets each back rewritten:

    root_en / root_word   ->   root_ack / root_new

with `roots_done` when the last one has been presented. Root
enumeration stays where the knowledge is, and the collector stays a
pure statement of the algorithm.

Three phases: evacuate each root, leaving a **forwarding word** (tag 7,
the only free tag) in the old cell so a second reference to the same
object finds the copy rather than making another; then the Cheney scan,
which walks to-space from the bottom and evacuates every pointer it
finds inside a copied object, appending to the very region it is
walking — that is the termination proof and the reason Cheney needs no
mark stack; then the flip.

`flip_en` had to learn a second thing on the way: `flip_aptr`. It used
to reset the bump pointer to zero, which is right for a bare swap and
catastrophic after a collection, because the live data is already over
there and zero would hand it out twice.

## The oracle is the serialiser

`tb_gc` does not compare to-space bit for bit. Where an object lands
after a copy is an implementation detail; that the graph reachable from
every root is unchanged is the property. So the testbench runs a
collection and then points a real `SerUnit` at each REWRITTEN root,
comparing the flit stream against what `PicoBEAM.Serial` says the
ORIGINAL term flattens to. Identical streams mean the graph survived —
structure, contents and sharing.

Three things are asserted on top, because a serialisation comparison
alone would miss them:

* `to_hp` equals the live cell count — **5 of 11 cells**, so garbage
  was not copied, which a collector that merely compacted would fail;
* the two roots naming one object come back **equal**, so it was copied
  once. This is the failure forwarding pointers exist to prevent and
  two identical serialisations would happily hide it;
* an immediate root passes through untouched.

## Two bugs found by building it

**Port B's write path never existed.** `b_wr` and `b_data` were
declared in `heap.ex` from the beginning and never wired to anything;
port B was read-only in practice. They are `b_wr0`/`b_wr1`/`b_d0`/`b_d1`
now — per bank, at an absolute address, because a Cheney copy writes
into to-space *and* leaves a forwarding word in from-space, and those
are not in the same semispace.

**`SerUnit` was addressing port B without the space bit.** Its own
address is seven bits — a cell within the active semispace — and the
engine passed it straight through as eight. Correct only because
nothing has ever flipped; the first collection would have sent every
serialisation reading into the dead half. Found by asking where the
collector's address was going to come from.

And a third, of a kind this project keeps meeting: the collector's
first version sampled heap data one cycle early. Every heap read costs
two states because the address is a register — `SerUnit`'s moduledoc
says exactly this — and the first cell of every object worked ANYWAY,
because the tag check had already addressed it. Only the second cell
was wrong, which is why the symptom was a collection that copied 4 of
5 live cells rather than one that obviously failed.

## What is NOT built

The collector is a module with a testbench. It is not yet a collector:

* nothing **triggers** it — the engine does not yet run one on
  allocation failure;
* nothing **stops the world** — all four seats must freeze, because a
  mutator reading a pointer mid-collection reads a corpse;
* nothing **enumerates roots** — the register windows, the frame RAM up
  to each process's high-water mark, the mailboxes' used entries, and
  the per-seat latches.

That last item is the real work, and the measurement above says it is
also the only part whose cost matters. The `SeatUnit` spill/fill path
already walks a context's registers one word per turn, which is the
machinery a root walk wants.

Until then the heap still faults with `heap_full`, exactly as before —
this note is a foundation, not a fix.
