# 26 — Known bugs in what is already built

`notes/23` audited COVERAGE: what exists and what does not. This one is
narrower and less comfortable. Everything below is a defect in
something already implemented and already passing its own tests — a
place where picoBEAM does the wrong thing, or does the right thing for
reasons that will stop being true.

Nothing here is a missing feature. Missing features are `notes/23`.

Ordered by how badly they would bite someone writing Erlang for this
machine today.

---

## 1. ~~`send` of a compound term ships a raw heap pointer~~ FIXED

**Was: high. Silent. Would have become memory corruption at M6.**

`SerUnit` is instantiated. A compound send parks (sequencer state 15),
the term is walked through heap port B, the flit count is checked
against the target's free space, and the stream goes into the mailbox;
`DeserUnit` rebuilds it at the peek. An IMMEDIATE message still retires
at X in one turn — `b3_pingpong` is byte-identical at 10,508 cycles.

Proven by `tb_fixed:csend`: `{7, [8|9], 9}` sent, arriving at a
**different cell** with its contents intact, compared word-for-word
against the model. See the postscript to `notes/22`.

Two things came with it: `SerUnit` gained `stall` (a flit that loses
the mailbox port is re-presented, not dropped) and `abort` (a message
that does not fit releases the unit instead of wedging it). And the
shape hash now comes from the root arity and first element rather than
from a pointer word, so `recv_hash` on a compound message means
something for the first time.

### The original entry

`SerUnit` (420 lines, round-trips 11 shapes against the oracle in
`tb_ser`/`tb_roundtrip`) is **not instantiated in the engine**.
`SendUnit` takes a single `msg_word` and enqueues it as one flit. So
`send(Pid, {a, b, c})` puts the sender's *pointer* into the receiver's
mailbox.

Today this appears to work, because there is one heap per engine and
every process on that engine shares it. It is working by accident. The
moment there are two engines (M6's ring) or per-process heaps, the
receiver dereferences a pointer into somebody else's address space.

It also means the mailbox's `len` is 1 and its shape hash is computed
from a pointer word, so `recv_hash` filtering on a compound message is
meaningless.

The receive side is complete: `DeserUnit` is wired and, since
`notes/25`, runs at the peek. The transmit side is the missing half.

**Fix:** instantiate `SerUnit`, give `send` a park state the way the
peek has one, and make the enqueue a flit stream. Until then, `send` of
anything but an immediate should arguably be REFUSED at encode time,
the way `recv` already is — a loud failure beats a quiet one.

## 2. ~~`halt` means two different things~~ FIXED

**Fixed in `notes/33`.** The engine was the one that was wrong. `halt`
now freezes the whole machine — a sticky `vm_halt` that stops every
context fetching, gated exactly against `out_valid`, travelling between
engines on a sideband rather than the ring, and cleared by `boot_en` so
a halted machine is re-bootable. Not a reset: the population and the
counters are the only record of what the machine was doing when it
stopped. `tb_fixed:vmhalt` asserts the machine is idle *with a live
process still in it*, which is a statement only a VM-wide halt can make
true.

The guess below about needing to kill three other seats turned out to
be unnecessary — nothing has to be killed, only stopped.

### The original entry

**Severity: medium. Divergent. Known since M3, still unfixed.**

`Machine` treats `{:halt}` as `erlang:halt()` — it stops the whole VM
(`halted: true`, `Machine.run` returns `:halted`). The engine treats it
as a process exit: the seat dies, the slot is freed, other processes
keep running.

Both are defensible readings; only one can be right. Every test program
so far has sidestepped it by having exactly one process reach a halt.
`erlsup` is the first program where it matters and it gets away with it
only because `main` halts last.

**Fix:** pick. Erlang's `erlang:halt/0` really does stop everything, so
the engine is probably the one that is wrong, and it needs a global
stop — which on a barrel means killing three other seats.

## 3. ~~A signal-killed process reports `fault_reason = normal`~~ FIXED

**Was: medium. Reporting only, but it read as a lie.** Fixed; the
description below is kept because the shape of it recurs.

The fix had three parts, because the lie had three:

1. **`fault_reason` now reports the reason the process actually died
   of.** When the dying slot is doomed, the reason comes from its
   `ProcTable` entry through the read port `notes/25` added, not from
   the X stage.
2. **`fault_count` and `fault_slot` are new outputs.** A single sticky
   bit cannot tell a supervisor doing its job from a crash loop, because
   in Erlang both look like "a process died abnormally". A COUNT can.
   `faulted`/`fault_reason` are now documented as what they are — the
   last abnormal death and what of — rather than as a health flag.
3. **The reason now has a path off-chip.** `DbgUart`'s moduledoc
   described a field as `RR = fault reason`; the board top wired that
   field to occupancy. The reason reached no pin at all. The line format
   gained `XX NN` — reason and count — and the old field is now
   labelled what it has always carried.

`tb_fixed`'s `ALLOW_FAULT` escape hatch is gone with it: `erlsup` now
asserts `WANT_FAULT=3` (badarith) and `WANT_FAULT_COUNT=1`, which is a
statement about a child killed by a signal that could not previously be
made.

`scripts/tb_dbguart.v` is new and is the reason (3) was findable at
all: it recovers the 115200 8N1 bit stream off `txd`, reassembles the
line, and compares it against the string the format promises.
`DbgUart` is the only part of this machine a person looks at directly
and nothing had ever tested it.

### The original entry

`died_fault` is set for a process killed by a signal, so `faulted`
goes high — but `flt_r` is only written from `any_fault_r`, the
**X-stage** reason, and a signal-killed process never faulted at X. So
the engine's fault port says "somebody died abnormally, reason
`normal`", which is a contradiction.

`notes/25` fixed the version of this that mattered — the reason that
PROPAGATES to links, which now comes from `ProcTable`'s reason column
through a new fourth read port. The version that was still wrong was
the one on the debug/UART port, which is what a person watching the
board sees.

`faulted` is also sticky and machine-wide: once any process has died
abnormally it stays high forever, so it cannot answer "is the machine
healthy now?". `tb_fixed` grew an `ALLOW_FAULT` escape hatch for
exactly this reason, which is a smell.

## 4. Heap: 128 cells, two semispaces, and nothing that collects

**Severity: medium. A hard ceiling, not a crash.**

`Heap` is 256 words = 128 cells per semispace, with a `flip_en` input
and no collector behind it. `Machine` has a full Cheney collector
(`cheney_scan`) triggered on allocation failure. So:

* the model survives programs the gates cannot run,
* the gates fault with `heap_full` (6) where the model quietly collects,
* and every long-running program on real silicon will eventually die.

`notes/25` made this worse on purpose: the peek now rebuilds candidate
messages, so a receive that scans past non-matching compound messages
allocates for each one and never reclaims it.

**Fix:** M5. `flip_en` and port B were put there for it.

## 5. ~~Heap pointers are cells here and words there~~ FIXED

**Was: low-medium. Divergent, documented, and the hole in the oracle.**

`Term.cons/1` and `Term.tuple/1` now carry the **cell** index, and
`Machine.alloc/3` rounds every allocation up to whole cells the way
`RTL.Heap` does. The model was always the side that was going to move —
`heap.ex`'s moduledoc said so — and it has.

Two things came with it:

* **`Machine` records `out_raw`** alongside `out`: the same values as
  raw 36-bit words. `out` holds decoded Elixir terms, which is what a
  person wants to read, but a testbench compares WORDS and a decoded
  term cannot express the pointer a compound result actually is. Five
  `mk_*.exs` scripts had each grown their own hand-written re-encoding
  lambda to work around that; they only worked because no test could
  report a pointer.

* **`scripts/mk_ptr.exs`** is the testbench that could not previously be
  written. It `out`s raw pointers and compares them word-for-word. The
  load-bearing case is a tuple of arity 2 — header plus two elements is
  three words, so it occupies two cells and wastes the odd one. If the
  model did not round, every allocation after it would sit one word
  below the hardware's and the following pointer would disagree. Gates
  and model produce the identical sequence: cells 0, 1, 2, 4, 5, 7.

`mk_heapprog.exs`'s header used to explain that it reported only
immediates because pointer payloads legitimately differed. That is no
longer a constraint, only a choice.

### The original entry

`Heap`'s moduledoc says it plainly: the RTL addresses cells, `Machine`
addresses words, and "the model is the one that moves at
co-simulation time". It has not moved.

Consequence: any `out` of a pointer prints a different number on the
two sides, so a word-for-word gate-vs-model comparison is impossible
for any program that displays a compound term. `mk_erlsup.exs` works
around it by destructuring in the receive clause and printing only
scalars.

This is why the fix matters more than it looks: it is not a wrong
answer, it is a **hole in the oracle.** Every compound-term result on
the gates is currently unverifiable against the model.

## 6. `recv_take` with no preceding successful peek reads a stale latch

**Severity: low. Only reachable by hand-written bundles.**

`recv_take` hands over the per-seat latch (`rw0..3`), which is written
by a scan hit. A take issued without a hit in the current scan returns
whatever the previous receive left there. The model would return the
mailbox head.

No compiled program can do this — `PicoBEAM.Erl` always emits the peek
— and no hand-written test does it. It is a sharp edge on the ISA, not
a live bug, and the right response is probably to make the ISA say so.

## 7. Nine encodable ops have never been in a program the gates ran

**Severity: unknown, which is the point.**

Scanning every image any testbench loads:

    band bor bxor cmple recv_hash tailcall unlink yield

(plus `recv`, which `Encoding` deliberately refuses, so it does not
count). `band`/`bor`/`bxor`/`cmple` are unit-tested in `tb_alu_signed`
against the model; the other four are wired into the engine and have
never executed. `tailcall` in particular is load-bearing for any real
Erlang program with a loop, and `PicoBEAM.Erl` does not emit it.

`yield` is the one that should worry us most: `check_m3_ops.exs`
exercises it, but that image is not among the ones the gate loads, so
the strobe is proven and the behaviour is not.

## 8. `PicoBEAM.Erl` refuses fifteen things, and the refusals are untested

**Severity: low. Coverage, not correctness.**

The front end raises `unsupported` for: `try`/`catch`, list
comprehensions and local recursion (`letrec`), fun values, remote calls
other than the handful of BIFs, multi-value `let`, `receive after 0`,
non-literal `mulsr` shifts, non-syntactic spawn arg lists, unbound
variables, and several literal/pattern shapes. Coverage on that module
is 60.6% and essentially none of the refusal paths are exercised, so we
do not know that they refuse cleanly rather than crashing or, worse,
emitting something.

`try`/`catch` matters: it is not exotic Erlang, and a supervisor that
cannot catch is only half a supervisor.

## 9. ~~`sd_boot` — 525 lines, zero tests~~ FIXED

**Fixed in `notes/34`.** `scripts/sd_card_model.v` is a microSD card in
SPI mode; `tb_sdboot` runs the loader against it from power-up and
checks every bundle and pool word against `Encoding.image/2`. The image
is three sectors, so a bundle straddles a boundary — the moduledoc's
sector-agnostic claim, made physical. It has since booted a real card
on a real board (`notes/36`).

### The original entry

**Severity: unknown.**

The SD-card loader is written and has never been simulated end to end.
Everything on the board today is loaded through the ROM side-door. The
`.pbi` path from `notes/20` runs through this code and nothing says it
works.

---

## 10. ~~One process's receive scan parked its cursor in another's slot~~ FIXED

**Was: high, and invisible until two processes received at once.**

`Mailbox` has one write site for the scan cursor with four writers, and
it addressed all of them by `cmd_slot`. Start, skip and take are
commands and that is right for them. The scan's PARK is not a command —
it fires when the scan FSM finishes, cycles after the `peek` that
started it, with no relationship to whatever is on the command port
then. So a scan parked its cursor in whichever slot happened to be
issuing a command at that instant.

A `recv_take` reclaims at the head only when the cursor IS at the head.
With a foreign number in the cursor the take tombstoned the wrong entry
and left the head where it was, so the next `receive` re-matched the
message it had just consumed.

One receiving process never triggers it. A server and a client — all of
OTP — trigger it constantly. Found by `tb_fixed:srv`, which replied `1`
twice instead of `1` then `2`; see `notes/30`.

The cursor write addresses `sc_slot` now. A second, smaller thing came
with it: a take reset the cursor to zero, correct only while the head
was zero. It resets to the new head, which is what BEAM does after a
successful receive.

## 11. A program could not name its own atoms — FIXED

Folded into `notes/30`. `Encoding` could number only the eighteen
reserved atoms, so `{From, inc}` was unencodable and no OTP protocol
could be written. `lda` has always carried a 12-bit index and the ALU
has always made an atom from it: 4,096 were available the whole time
and only the toolchain refused to number them.

## Things that look like bugs and are not

* **The exit-signal emitter DROPS a flit that loses the mailbox port.**
  This one IS a bug, found while wiring the serialiser, and it is
  recorded here rather than above because it is narrow: `sd_st` advances
  whether or not its flit won the port, so a send retiring in the same
  cycle eats a flit of an `{'EXIT', ...}`. Four flits is a small enough
  window that nothing has caught it. It wants the `stall` treatment
  `SerUnit` now has.

* **A send to a dead pid is silently dropped.** `SendUnit` raises
  `dead_letter`, the engine captures it and does nothing. That is
  Erlang's semantics exactly.
* **A mailbox overflow kills the RECEIVER** (reason 7,
  `mailbox_full`), not the sender. Deliberate: `notes/13`'s bounded
  mailbox, and the receiver is the one that failed to keep up.
* **A `fail` sets `faulted`.** That is what `fail` is for; `WANT_FAULT`
  asserts on it.
* **Single-process latency is 4× worse than a dedicated core.** That is
  the barrel's advertised price (`notes/18`, B1 = 4.00 cycles/bundle),
  paid to four significant figures.

---

## 12. A process that returned from its entry function did not exit — FIXED

Found chasing `spawn_link` on the gates and written up in `notes/31`.
`ret` at frame depth zero popped an empty stack, read link zero, and
continued at bundle 0 — which is the image's entry point. A spawned
function that simply ran off its own end re-ran the whole program.
Fixed by routing a top-level `ret` to the death path with reason
`normal`, which is what the model has always done.

## 13. `fr_ovf` and `fr_unf` were wired and never read — FIXED

Same file, same afternoon. `FrameRamProc` has raised `overflow` since
M3 pass 5; the engine declared both wires and read neither, so the
sixteenth nested call pushed no frame, recorded no link, and returned
into the fifteenth caller's. Now `:stack_overflow`, asserted by
`tb_fixed:deep`. The model's `@max_rstack` came down from 64 to the
15 the machine actually has, because an oracle that faults in a
different place from the machine is not an oracle.

## 14. `cstate = 16` truncated to 0 — FIXED

`BarrelSeq`'s per-context status field was four bits and the send park
is state 16, so every context streaming a message out of the serialiser
has been sitting in a state the rest of the machine reads as **an empty
seat**. Nothing consulted it for a decision a sender could lose — the
kill and wake paths test for 1 and 12, the seat allocator keeps its own
occupancy — so it never bit. Found because `notes/32` needed state 20
and got 4. Five bits now.

This is the third time the same failure has happened in this project
(M2's `pidx`, `spawn_park` as state 9, now this), and the moduledoc
that warns about it was one line above the bug.

---

## Scoreboard

| # | what | state |
|---|---|---|
| 1 | `send` ships a raw heap pointer | **fixed** |
| 2 | `halt` means two things | **fixed** — `notes/33` |
| 3 | the fault port lied | **fixed** |
| 4 | 128 cells, no collector | open — M5 |
| 5 | cells here, words there | **fixed** |
| 6 | `recv_take` with no peek | open — unreachable from compiled code |
| 7 | nine ops never run by a program | open |
| 8 | fifteen untested refusal paths | open |
| 9 | `sd_boot` untested | **fixed** — `notes/34` |
| 10 | receive cursor parked in the wrong slot | **fixed** |
| 11 | no application atoms | **fixed** |
| 12 | returning from an entry function did not exit | **fixed** |
| 13 | frame overflow/underflow never read | **fixed** |
| 14 | `cstate = 16` truncated to idle | **fixed** |

## The shortest honest summary

Two of these — (1) `send` and (5) cell-vs-word addressing — meant the
same thing from different directions: **compound terms are the part of
this machine that is least finished and least checkable.** (5) is now
fixed, so the oracle is repaired and the checking half of that sentence
no longer applies. The receive half works end to end and is proven by
`tb_fixed:erlsup`. The transmit half is still unbuilt.

That is the next piece of work, and it is now verifiable when it
lands.

### Postscript, after `notes/31` and `notes/32`

The transmit half landed (`notes/22` postscript), the collector was
built (`notes/28`), and `try`/`catch` is in the gates. With (12), (13)
and (14) closed, **(2) is the only place left where the model and the
netlist disagree about a feature that has shipped**: `erlang:halt()`
stops the VM in BEAM and in `machine.ex`, and exits one process on the
engine. Every program written for this machine so far has hidden it by
halting last.

It is no longer a cosmetic disagreement, because it is the only one.

### Second postscript, after `notes/33`

And now it is none. `halt` freezes the whole engine — a sticky
`vm_halt` that stops every context fetching, gates `out_valid`, drives
`idle` high, and travels between engines on a sideband rather than the
ring. Not a reset: the population, the windows and the counters are the
only record of what the machine was doing when it stopped, and the
model keeps them too.

**There is no open entry on this scoreboard that is a disagreement
between the model and the gates.** What is left is real work — (4) the
collector is built but not wired in, (7) nine ops no compiled program
has ever executed, (9) `sd_boot` — but none of it is the two halves of
this project meaning different things by the same instruction.

### Third postscript, after `notes/34`

(9) is closed. `SdBoot` has a Verilog SD card to talk to and a
testbench that checks every bundle and pool word it delivers against
`Encoding.image/2`, across three sectors, in the regression gate. The
525 lines turned out to be correct — which was never the question; the
question was that nobody could say either way.

It also cost EHDL a footgun. `param` is constant-folded at elaboration,
so the `parameter` the emitter used to write was decorative and a
Verilog override was accepted and ignored. It is `localparam` now, and
making it loud immediately found two testbenches that had been naming a
`BUDGET` they were not running.

### Fourth postscript, after `notes/40`'s walker

A new divergence, found by building the thing that needed to know
where the roots are.

**The model charges a queued message to the receiver's heap; this
machine does not.** `Machine.deliver_to/3` calls `import_term`, which
allocates on the receiver's heap, so a message sitting in a model
mailbox is a live heap object and a GC root. The engine copies on
RECEIVE instead: `SerUnit` turns the term into a flit stream, the
mailbox stores flits, and `DeserUnit` rebuilds it on the heap when
`recv` takes it. Flits are immediates and structural markers, so a
mailbox here holds nothing the collector can see.

It is a divergence in **when memory is spent**, not in what a program
computes. The `out` stream is identical either way. What differs is the
allocation that runs out: a program with mail in flight is closer to
`heap_full` on the model than on the board, and further from it after a
`recv`, because the machine pays for the whole message at once when it
rebuilds. No test in the suite can currently tell them apart; a test
that fills a heap while a mailbox is deep would.

Filed rather than fixed, because both behaviours are defensible and the
BEAM-correct one is the model's — real BEAM copies into the receiver's
heap at send time. Closing it means allocating at delivery here too,
which is a change to `send`, not to the collector, and it should not be
made in the middle of wiring one.

| 15 | mailbox costs heap on the model, flits on the board | open |

### Fifth postscript, after `notes/41`

**(4) is closed.** The collector is in the engine. `heap_full` is a
request, the allocating bundle parks in a new `BarrelSeq` state and
re-executes against a compacted heap, and `tb_fixed:gcloop` runs four
hundred iterations through twelve collections on a 128-cell semispace
with the model's `out` stream as the expectation, on the netlist.

Two things came out of doing it.

The first is a bug that was already there and had never been reached: a
message rebuild that overflowed the heap raised `hp_f`, and `any_fault`
is consumed by whichever context is at X that cycle — so a message too
big for the heap killed a **random process**. No test had ever filled a
heap during a rebuild. The room is checked before the rebuild starts
now, so it is unreachable; what is left of it is (16).

The second is EHDL's, and it is the third of its shape. A child's PORT
name that matches a net in the parent is silently merged with it, and
the emitted Verilog gets two continuous drivers on one wire. Where they
agree the wire looks correct; where they disagree a bit goes `x`, and in
this case that bit was the frame store's write address — so every spill
went nowhere and every process read zeros out of its own frames, three
modules away from the collision. `scripts/check_drivers.py` runs in the
gate now and reads the OUTPUT rather than modelling the renaming rules,
which is what got it wrong the first time.

| 16 | a rebuild that still will not fit after a collection | open |
| 17 | the collector's pause is a serial walk, ~490 cycles | open |

### Sixth postscript, after `notes/42`'s funs

Closures are in the gates. `mkfun` is heap command 7, `fget` is command
8, `callfun` reads the entry out of the object and commits a call to it,
and `tb_fixed:fnelixir` runs Elixir `fn` — captured, passed to another
function as a value, called on both sides of a collection.

Two entries close and one gets easier.

**`badfun` and `badarity` are their own reasons now**, appended to the
reserved table at 18 and 19 rather than laundered into `badarg`. A
supervisor that matches on why a call through a fun failed gets the
answer BEAM would give it.

**An out-of-X death carries its own reason.** `badarity` cannot be known
until the closure's funinfo comes back a cycle after X, when the seat
has moved on — so `BarrelSeq` gained `bad_en`/`bad_seat`, which forces a
seat to state 7 from any state, and the reason is held one extra cycle
because `sfl` is a register and `died` fires after it. That is the
machinery (16) needs: a rebuild that still does not fit after a
collection has to kill the RECEIVER, which is not at X either. The entry
stays open, but it is now a wiring job rather than a design one.

| 18 | `&fun/1` capture and funs escaping by name | open |

### Seventh postscript, after `notes/42`'s maps and `notes/43`'s binaries

Maps, structs and strings are in the gates and in Elixir.

A map is a flatmap — header, pair count, one key/value pair per CELL —
with a tag of its own, so `is_map/1` is a tag test and `element/2` on
one raises. `mkmap` allocates, `tset` fills a literal, `mapat` reads at
a computed index, and `mseti`/`mset` write at one. Everything above that
is Erlang in the prelude, the way the list functions are. **Structs came
free**: a struct is a map with a `__struct__` key, so "maps, structs and
funs" was two features and not three.

A binary is the same shape with a byte count, and Elixir strings are
binaries. `<>`, `byte_size/1`, `:binary.at/2`, a string literal in a
pattern and `<<c, rest::binary>>` all work.

Three things came out of it.

**A per-process index latch is safe where a per-process POINTER would
not be.** `mset` needs three things — a map, an index and a value — and
a heap op has two register reads. So the index arrives in its own pure
op and is latched per PROCESS. It had to be an integer: a latched
pointer would be a GC root nothing walks, and a process swapped out
mid-fill would come back holding a stale one.

**`hp_writes` did not exclude `mset`**, so it claimed a write-back turn
and wrote `rd_late` over r0 — which was the map pointer it had just been
handed. The next read said `badmap` about a register that had been
correct one bundle earlier.

**`tb_fixed` loaded 256 bundles of a 512-bundle store.** It was 128
once, then 256, and each time a program outgrew it the tail stayed
zeros. Bundle zero is `add r0, r0, r0`, so a program that ran off its
own end added a register to itself and died of `overflow` several
hundred cycles later, in a function that had nothing to do with it. It
loads the whole store now.

| 19 | `==` on binaries, tuples and lists is word equality | open |
| 20 | no sub-binaries: `rest::binary` copies | open |
| 21 | no constant area: every literal is constructed | open |
| 22 | one 16-register window, and the front end leaks into it | **fixed** — `notes/50`: the front end recycles; the raise now counts LIVE values |

---

**23. A UART push that reported success and did nothing** (`notes/44`).

`mix run scripts/pbpush.exs _emit/sd/board.img` printed `pushed 3748
bytes` and the board went on running the image it had booted off the
card. No error, no partial load, no wrong answer — the bytes were not
there at all.

The board had been programmed over JTAG minutes earlier. The known form
of that gotcha is that READS on `/dev/cu.usbserial-*` hang forever after
a `fujprog` run; this is the same thing on the write side, and it is
worse, because a hang announces itself and a dropped write does not.
`notes/37` recorded `pbpush.exs` working, and it did — on a board that
had been power-cycled rather than freshly programmed.

The way through is fujprog's own raw-send, which reopens the FTDI and
hands the port to its terminal without an intervening close:

    fujprog -P /dev/cu.usbserial-D01477 -b 115200 -a <img> -t

Not a bug in the design and not a bug in `pbpush.exs`. Filed here
because it cost twenty minutes of staring at a debug line that was
telling the exact truth about a program nobody had loaded, and the next
person to push after a JTAG op will lose the same twenty minutes.

---

**24. `mix test --cover` fails a test that passes without it**
(`notes/45`).

    1) test even-arity tuples survive collection ... (PicoBEAM.HeapPadTest)
       ** (PicoBEAM.Ex.CompileError) debug_info: :unknown_format

`PicoBEAM.Ex` reaches Elixir through the `.beam` file's `debug_info`
chunk, and the coverage compiler rewrites that chunk into a form
`:elixir_erl` does not recognise. `mix test` is 75/0; `mix test --cover`
is 75/1, always the same test, and the failure says nothing about the
code under test.

Filed because a coverage run is exactly when someone reads a failure
count and believes it. Any test that compiles Elixir source at runtime
will do this.

**Postscript, same day: that diagnosis was wrong, and the bug is ours.**

It is not the coverage compiler and it has nothing to do with `--cover`.
It is seed-dependent — `mix test --seed 186099` passes, `--seed 1` fails
— which is the signature of an ORDERING problem, and `--cover` merely
changed the order.

`PicoBEAM.Ex.compile_to_beams/1` did this:

    previous = Code.compiler_options()
    Code.compiler_options(docs: false, debug_info: true)
    try do Code.compile_file(path) after Code.compiler_options(previous) end

`Code.compiler_options/1` is **node-global**. Two overlapping compiles
race: the second saves the first one's `true` as "previous", and the
first one's `after` clause puts `debug_info: false` back while the
second is still compiling. The second module comes out stripped and
`to_program/1` raises `debug_info: :unknown_format` — which is also
exactly what a genuinely unsupported backend says, which is how it
passed for a coverage-tool problem.

ExUnit runs `async: true` cases concurrently, so the suite is the second
caller. The fix is one `:global.trans` lock around the global, in `Ex`
where the race is, rather than `async: false` on the test that happened
to lose. Six seeds green, and green under `--cover` too.

Left standing, wrong half included: a diagnosis that was confidently
about the wrong component is worth more on the page than off it.

---

**25. The Cheney scan did not follow maps, binaries or closures**
(`notes/46`). Silent wrong answers, and the worst entry on this page.

`notes/40` made the collector's pointer tags `param`s specifically so
that adding a tag would be one line in one place — after `:fun` had
already drifted from 7 to 0xA and nearly turned a closure into a
forwarding pointer. The ROOT path took the params. The SCAN path did
not:

    // state 7, 8, 12 — a pointer found INSIDE a copied object
    if bor(h_q0[35..32] == 3, h_q0[35..32] == 4) == 1 do

3 and 4. Cons and tuple. So a map, a binary or a closure reached only
through another object — `{%{a: 1}, "hi"}`, a struct in a record, a
closure in a list — was copied as data and never rewritten, and after
the flip its pointer named a cell in the reclaimed semispace.

`scripts/mk_scanptr.exs` is that program: a map and a binary inside a
tuple, every direct reference dropped so the tuple is the only root,
three collections.

    FAIL tick 0: gates 000000000, model 000000046
    FAIL tick 1: gates 000000010, model 000000002
    FAIL tick 2: gates 000000010, model 00000006f

No fault, no crash, no death — just 0 and 16 where 70, 2 and 111 should
have been. `tb_fixed:maps` and `tb_fixed:mapelixir` both pass, because a
map held in a REGISTER is a root and the root path knows about maps.
Nothing had ever put one inside something else and collected.

The fix is one shared list of tags asked in three places instead of two
lists asked in four. The lesson is `notes/40`'s own, unlearned: making a
fact a `param` fixes the places that read the param, and says nothing
about the places that did not.

---

**26. The model and the gates disagreed about what a pointer IS**
(`notes/46`). Not a wrong answer — a wrong representation, invisible
because nothing ever looked.

`Machine` carries an absolute cell address, 0..255 across both
semispaces. `RTL.Heap` carried a seven-bit index WITHIN the active
semispace, with the space bit in a register beside it. The two agree in
semispace 0, and semispace 0 is the only place a program that has never
collected has ever been.

`mk_ptr.exs` exists specifically to compare raw pointer values against
the model. It allocates four objects and stops.

`scripts/mk_ptrgc.exs` asks the same question after a collection:

    FAIL tick 1: gates 300000000, model 300000080

Cell 0 against cell 128. Both sides internally consistent, both sides
reading back `[1 | 2]` correctly, sixty-two testbenches green.

This is `notes/26` bug 5 one level down — that was `Machine` addressing
the heap in WORDS and the RTL in CELLS, fixed by moving the model to
cells, and the space bit survived the fix in the same argument's other
half. Sixth occurrence of "decided in one place, copied into another".

The gates are absolute now. It was not optional: a concurrent collector
has live data in both semispaces at once, so a pointer has to be able to
say which one it is in.

---

**27. "A collection is running" stopped meaning "this port is free"**
(`notes/46`). Three bugs, one assumption.

Under a stop-the-world collector the two are the same statement, and the
engine said so in nine places: `gc_active * walker + not(gc_active) *
machine`, on register-file port 0, on its write port, on the frame-depth
query, on heap port B. Every one of them was correct for as long as a
collection meant the pipeline was stopped.

The per-process collector has a state — state 2 — that IS a collection
and is ALSO the engine executing at full speed. In it, every D-stage
read got the walker's word and every X-stage write went wherever the
walker was pointing.

Fixing that to "frozen" was not enough either, and the second bug is the
more interesting one. **Freezing stops FETCHING.** The bundles already
at D and X take another eight cycles to retire, which is precisely what
the quiesce states exist to wait for — so handing the port over on the
FIRST cycle of the freeze hands it over while four bundles are still
using it. A `tset` read 42 as its tuple pointer and died of `bad_tag`;
an `add` read a pointer and died of `badarith`.

The right signal was available the whole time and the design never named
it: `rk_busy`. The walker is only busy in the state after the drain has
happened.

Third: a `heap_full` retiring during the quiesce, before the allocation
base had moved, was treated as a real fault. It killed whichever process
happened to be mid-allocation when somebody ELSE's collection started —
a failure mode that could not exist before, because before there was no
state in which a collection was running and the base had not moved.

The lesson is not "check your muxes". It is that a signal named for
WHAT IS HAPPENING (`gc_active`) had been used for WHAT IS SAFE, and the
two were accidentally identical. Renaming the question — is this port
free? is the pipeline drained? — is what found all three.

---

**28. A combinational loop through the heap** (`notes/46`). Self-
inflicted, thirty seconds of confusion, worth one paragraph.

The gated park needs to suppress the store: the allocation must not
happen for a bundle that is parking. So `hp_en` was gated on `gc_park`.
But `gc_park` reads `heap_full`, and the store computes `heap_full` from
`cmd_en`, which is `hp_en`. The simulation stopped making progress and
looked exactly like a livelock in the FSM.

Only the GATED half of the park needs to suppress the store — the
`heap_full` half is already a no-op inside it — and that half does not
read the fault. One extra wire, `gc_gate_x`, and the loop is gone.

---

**29. `rt_kind + 1` in a one-bit wire is zero** (`notes/49`). Verilog's
self-determined width rule, the third time in this project.

The ring egress computed a packet's kind from a flag: `rt_kind + 1`,
where `rt_kind` was one bit — 0 for a spawn request, 1 for a reply.
Requests came out as kind 1 and worked. Replies came out as
`1 + 1` in one bit, which is **0**, which is a MESSAGE — so every reply
to a cross-engine spawn was enqueued into the requester's mailbox as
garbage and the requester stayed parked forever.

Entry 26 was `to_base + CELLS` overflowing eight bits; the emitter
widths in `notes/15` were the same species. Same fix every time: **do
not compute a value in a field narrower than the value.** The field now
holds the real kind and the egress does no arithmetic on it.

Worth adding: the flag-plus-one encoding *looked* smaller. A one-bit
register plus an adder is not smaller than a four-bit register when the
adder is wrong.

---

**30. A "busy" flag that cleared one step before the work finished**
(`notes/49`).

A remote spawn starts at the parked seat's F slot, guarded on
`bnot(ro_busy)`. `ro_busy` clears when the reply lands — but the seat is
still parked at that point: it does not resume until the pid has been
written back and `spawn_ready` goes high, a couple of turns later.

`spawn_park` is true at EVERY F slot of a parked seat, so in that gap
the next F slot started a second request and wiped the answer it had
just been given on the way past. The machine spawned a fresh process on
the far engine every four cycles until its table filled.

Same shape as `notes/46`'s `gc_hold`, and worth stating as a rule: a
flag that means "in flight" is not the same as a flag that means "this
transaction is over", and a park that is polled every N cycles will find
any gap between them.

---

**31. A message off the ring never woke a blocked process** (`notes/49`).
In the machine since the ring carried its first message.

`wake_en` had two sources — a local delivery and the exit-signal
emitter. A ring arrival was not one of them, so a process blocked in
`receive` on engine 1 stayed blocked when engine 0 sent to it. Forever.

The reason nothing caught it is the part worth keeping. `tb_ring2`
sends a message across the ring and reads it back correctly at the far
end — a real test of the ring, which says nothing whatever about
waking, because its receiver SPINS on `recv_peek`/`jmp` rather than
blocking. The one program shape that does not need waking is the shape
the only cross-ring test happened to be written in.

The gap was not in the coverage of PACKETS. It was in the coverage of
RECEIVER STATES, and no packet-shaped test was going to find it. The
first program to block across the ring found it on its first run.

Fixed with a third wake source riding the last flit of the packet —
same reasoning as the exit emitter's, waking on the first would let the
matcher see a head whose continuations have not landed.

---

**32. The wake rode the delivery decision, not the delivery**
(`notes/50`). Entry 31, one path over.

A compound local send's flits land cycles after its X, but the wake
fired AT X, off `delivered` — before the message existed. A receiver
that blocked inside that window woke early to an empty mailbox,
re-parked, and the completed stream woke nobody. Every earlier
compound-send test dodged the race by having its receiver already
parked or spinning; the first program to block at the wrong moment
(`tb_fixed:names`) hung on its first run.

Fixed the way the exit emitter and the ring ingress were already
built: the wake rides the COMPLETION (`ser_done`), with a sixth
`ProcTable` read port for the queued-receiver check. The rule now has
three precedents, so it gets stated: a delivery that takes N cycles
wakes at cycle N, not at cycle 0.

---

**33. `exit(Pid, kill)` was trappable, and recorded the wrong reason**
(`notes/50`). Two BEAM-correctness bugs in one `exit2` block, found by
the first test that killed a process and then LOOKED.

The gates routed `exit2` through the target's trap bit first, so a
trap_exit process would convert a kill into a mailbox message and
survive — BEAM is emphatic that `kill` is untrappable. And the doomed
process's recorded reason was `:kill` (2), the signal, where BEAM
records `:killed` (1) — a supervisor matching on exit reasons would
have seen an atom BEAM never delivers. The model had both right all
along; the gates moved. Two lines.

---

**34. The deserialiser's completion could silently drop another seat's
ALU writeback** (`notes/52`). Latent since the rebuild-at-peek design;
found by the first two processes to ping-pong compound messages fast
enough to align the pulses (`priv/demo/counter.ex` — written as a
DEMO, not a test).

The w0 write port's priority chain assumes every late writer belongs
to a PARKED context whose X slot is free "by construction". It was
true of the ret-fill, the spawn-fill, the pid write and the dest write
— each paces itself to its owner's turn — and false of exactly one:
`dz_done` fired the cycle the rebuild finished, on whatever seat's X
cycle that happened to be. When it landed on a running context's ALU
write, `wb0` lost the port and the write vanished. In the counter, the
dropped write was `lda r0, false` — the peek-ok flag — so a receiver
branched on stale truth, pattern-tested garbage, skipped a message
that was never sent to it, and spun forever.

Fixed by making the claim true: the completion latches into `dzw_*`
and writes back on the OWNER's own X slot, which is empty because the
owner is parked on this very rebuild. One rotation of added latency on
a path that already took a message's length in cycles.

---

**35. A head flit was matchable before its message had finished
arriving** (`notes/52`). Found while hunting entry 34, real on its own.

A local compound send streams one flit per cycle and stamps the HEAD
entry first, so a receiver POLLING its own peek — no wake involved —
could match a message whose continuations had not landed and hand the
deserialiser a partial term. The ring ingress avoids exactly this by
waking on the last flit; a poller does not need a wake. The mailbox
scan now treats an incomplete head (its `len` runs past the slot's
tail) as not there yet: no match, scan stops, cursor parks ON it so
the next pass finds it whole.

---

**36. An image push does not reset scheduler state** (`notes/52`).
`sp_rr` — the spawn round-robin counter — survives the soft reboot a
UART image push performs, so a program's spawn placement depends on
how many spawns the PREVIOUS program executed. The counter demo's
server landed on engine 1 because the names demo had run first; the
same image pushed again worked. The name CAM is the same class of
leak with worse consequences: a registered name can outlive the
program that registered it. Audit everything the boot path resets;
anything holding cross-program semantics (round-robin counters, the
CAM, `next_ref`, doom state) belongs on it.

---

**37. A widened record with an unwidened reader: `q_ent` stayed 27
bits** (SMP refactor, Phase 3). The name table's entries grew 27→31
bits to carry the engine field, and every wire touching them was
widened — except `q_ent`, port A's lookup mux. `q_ent[30..27]` (the
new eng field) then selected past the top of a 27-bit wire, which
Verilog answers with X. The X was invisible at the CAM (`q_hit` was
fine) and surfaced 400 lines away: `whe_word` folds `nm_q_eng` into
the port-0 register-write mux, EHDL muxes are sum-of-products, and in
Verilog `0 * X = X` — so ONE undefined leg poisons every write the
port ever makes, including the seat-in restore. Every program "wedged
at boot" with zero outs; the actual machine ran fine and retired X.

Two lessons. First: EHDL accepted an out-of-range slice silently —
`w[30..27]` on a 27-bit wire should be an elaboration error, and
would have turned a day of X-archaeology into a one-line message
(filed as an ehdl TODO). Second: the debugging pattern that found it
— walk the emitted netlist's assign graph from the X'd signal,
print every cone node that carries an X at a fixed cycle — is
mechanical and fast (`/tmp/xprobe.vh` generation); do that FIRST next
time a design goes all-X, not signal-by-signal guesswork.

---

**38. A peek that hit a SHORT message never wrote rd** (Phase 4 gate
work). The compound path parks the seat and lands its rebuilt pointer
through the deserialiser's deferred writeback; the immediate path
resumed the seat with `pc+1` and wrote NOTHING — so every
selective-receive pattern test against a bare immediate (`receive go`,
`receive 7`) compared a stale register and skipped its own message,
then blocked forever with the message sitting in the mailbox. The
model always wrote rd. Invisible for a year of testbenches because
every covered receive either matched a tuple (compound → deserialiser
path) or peeked with a wildcard (no pattern test reads rd). Found the
day a cross-engine link test sent `go`.

Fix is the entry-34 shape verbatim: a `pkw_*` deferred latch — catch
the word at scan completion, hold the seat (BarrelSeq state 19),
release at the owner's own X slot, resume on the write cycle. Third
use of the pattern; it is now officially the idiom for "a parked
seat's result must enter the register file".

Same excavation also found: `next_ref` was reset to 0 where the
model's counter starts at 1 — every ref minted after an image push was
off by one from the model (caught by mon2's expect file, not by any
equality the program itself performs, since a uniformly shifted
counter still self-agrees — which is WHY the expect files compare raw
words).
