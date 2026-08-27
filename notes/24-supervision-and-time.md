# 24 — Supervision, monitors, and the first clock

The nine opcodes `notes/23` counted as "in the table, in the model, and
nowhere in the gates". Eight are now built; the ninth was decided
against, on purpose, and that is the honest outcome for it.

| op | outcome |
|---|---|
| `ldc` | built — the literal pool, interned at image build |
| `fail` | built — a strobe into the die path |
| `link` `unlink` | built — the signal table |
| `trapexit` | built — a bit in ProcTable, read on the delivery path |
| `exit2` | built — a signal aimed at one process |
| `monitor` | built — entries, refs, and `DOWN` |
| `recv_waitt` | built — the timer wheel |
| `recv` | **not built, deliberately** |

## `ldc`, and why it was worth more than it looked

The 12-bit `ldi` immediate reaches −2048..2047. Everything wider had to
be *computed*: the Hermite demo in `notes/21` spends three bundles on
`ldi 2000; ldi 20; mul` to say 40000, which is slower than it needs to
be and, worse, a lie about what the code is doing.

Interning happens at image build, not at slot encode, because it is a
whole-image property: the same constant in two functions must get one
slot, and the index is only knowable once every function has been seen.
Values are deduped and ordered by first appearance, so the pool is a
pure function of the program — the Gensym lesson from `notes/10`,
applied before the mistake rather than after.

It also forced a rule that was already true and unwritten. **Bundle
rule 5: at most one late write-back per bundle.** The sequencer
allocates exactly one wb2 turn, so a second `ldc` or heap op in the
same bundle is not slow, it is unrepresentable — the second result
would have nowhere to land. The restriction lived in the datapath; now
the assembler says it.

## `recv` is sugar, and sugar with no consumer rots

`recv rd` means "take the mailbox head or block". The family it
decomposes into — `recv_start`/`recv_wait`/`recv_peek`/`recv_take`/
`recv_skip` — is fully implemented, and the Core Erlang front end has
never emitted `recv` and never will, because `receive` with any pattern
needs the filter.

So a fused `recv` would be ISA surface whose only user is a
hand-written test program. `encode_slot/1` now refuses it with the
lowering spelled out, exactly as it refuses the two-register branches
at 0x31..0x34. The model keeps the fused form, because there it costs
nothing and documents intent. If the unfiltered receive ever measures
hot the answer is a **peephole in the assembler** that recognises the
four-bundle idiom, not a second matcher FSM.

## Links: a bitmap, and why that does not break the incarnation contract

`links[p]` is a 32-bit mask of the slots `p` is linked to. A bitmap
carries no PID serial, which looks like it violates `notes/13`'s
incarnation rule. It does not, because a link cannot outlive either
end:

* **Death clears both sides.** The fan-out clears each peer's bit for
  the corpse as it signals them, then zeroes the corpse's own row.
* **Registration checks the serial.** `link` to a dead incarnation is
  refused by the engine — the same full-PID comparison `send` makes —
  and answered by the dead-letter rule with `noproc`.

The only stale link a bitmap could hold is one whose target died, and
that is precisely the case the fan-out removes. 1024 bits, one LUT-RAM,
no associative store.

**The walk is one link per cycle, not one bit per cycle.** `notes/13`
promises propagation is "links × ring diameter"; scanning all 32 slots
regardless would make it *slots* × diameter — also bounded, and a
different, worse number. A design whose entire claim is a stated WCET
should pay for the constant it states. It costs `m & -m` to isolate the
lowest set bit and five reduction-ORs to index it. Measured: 31 links,
31 signals, ~31 cycles.

## Monitors: entries, because a ref has to come back

A monitor is not a link with the killing removed. It hands the watcher
a **ref**, and the `DOWN` that eventually arrives must carry that same
ref so the watcher can tell which of its monitors fired. Bits cannot do
that, so monitors are 32 entries of `{ref, watcher, target}` and the
bitmaps index entries rather than slots.

Three relations, three bitmaps, one walk:

    links[p]   slots p is linked to        -> exit signals
    mwatch[p]  entries watching p          -> DOWN messages
    mown[p]    entries p created           -> cleanup

`mown` is the one that is easy to forget. When a WATCHER dies its
entries have to go, or the entry leaks and — worse — fires later at a
slot that has since been recycled, dropping a `DOWN` into a stranger's
mailbox. Without a reverse index that cleanup is a 32-entry scan at
every death; with one it is monitors-long like everything else.

**A `DOWN` never kills.** That is the whole difference between watching
something and being tied to it, and it is why `monitor` is what
`gen_server:call` uses and `link` is what a supervisor uses.

Both messages are flits of immediates in `PicoBEAM.Serial`'s postfix
wire format — `{'EXIT', From, Reason}` in four, `{'DOWN', Ref, From,
Reason}` in five — so `notes/13`'s allocation-free rule holds
physically: **a process dying of `heap_full` can still tell its
supervisor why, because saying it costs no heap.**

## The timer: the first thing in the machine that measures

A blocked process may be evicted — that is what `notes/17`'s eviction
rule is for — so a deadline cannot live in a context. It lives per
SLOT, and survives being swapped out.

The wheel sweeps one slot per cycle, so a timeout is detected within
**32 cycles of expiry**: 2.7 µs at 12 MHz, and a stateable bound, which
is the only kind this machine is interested in. Checking all 32 in
parallel would buy latency nobody asked for at the price of 32
comparators against a 32-bit counter.

Expiry is **not** `now >= deadline`. `now` free-runs and wraps every
2^32 cycles — six minutes at 12 MHz, not a hypothetical — and a
comparison breaks the moment it wraps past a deadline set before it.
Expiry is `(now - deadline)` read as a signed value being non-negative,
which is correct across any single wrap and costs one subtraction and
one bit test. The price is a stated ceiling: a delay must be under 2^31
cycles. A longer wait is a counting loop over shorter ones.

Cancellation is the common case — most receives with a timeout get
their message — so it is one bit of a valid mask, with no scan to find
the entry, because the slot IS the index. When a message and a deadline
land in the same cycle, cancel wins: the mailbox already holds the
message and the receive will succeed.

## Four bugs, and two of them are the same bug again

**ProcTable's `cmd` was three bits and `settrap` is command 9 — which
truncates to 1, `alloc`.** Every `process_flag(trap_exit, true)`
silently consumed a process slot and set no flag; the symptom was a
supervisor dying with its child for no visible reason. Third time in
this project: M3's `cstate` had a state 9 that became 1, M2's `pidx`
collapsed the same way. **A command space that outgrows its declared
width does not error — it aliases onto a neighbour that is usually a
legal, plausible, wrong thing to do.**

**A killed process's reason was erased at the moment it died.** The
doom records the reason — the only moment anyone knows it — and the
free that follows carried the X-stage fault reason. A process killed by
a signal never faulted at X, so that reason is zero: `normal`. The
corpse then claimed to have exited normally.

**`unblock_pc` was never declared, so it became an implicit ONE-BIT
Verilog net.** Every receive timeout resumed at bundle 1 instead of the
label it named, re-running the spawn ahead of it, once per deadline,
forever. See below — this one is now impossible.

**`self`, `recv_take` and `monitor` wrote only through port 0, keyed on
the slot-0 strobe.** The bundle contract puts a system op *last*, and
"last occupied slot" is slot 1 in any two-op bundle — so the same op
one slot over computed its value and wrote nowhere. It stayed shut only
because the front end emits one op per bundle. The port-0 write now
takes a muxed system-op `rd`.

## The ehdl fix that makes one of those impossible

An instance port connected to a name that is neither a declared signal
nor a port used to synthesise a signal silently and never declare it —
and an undeclared net in Verilog is an implicit **one-bit** wire. So a
nine-bit program counter connected through a forgotten `wire`
declaration arrived as its bottom bit, with no error anywhere.

`instances.ex` now raises, naming the port, the signal, and the
declaration to add. Clocks and top-level ports are still allowed
through, because `clock :clk_25mhz` is exactly the legitimate case the
old behaviour existed to serve.

That is the fourth ehdl width fix (`notes/21` has the first three), and
they are all one sentence: **an inferred width smaller than the value
it must carry.**

## Coverage

Opcodes executing in sim and/or silicon: **40 of 52**, up from 32.

Still never executed: `band` `bor` `bxor` `cmple` `cmpne` `mov` (ALU
micro-ops, exhaustively unit-tested in `tb_alu_signed.v` but never run
through the engine by a program), `recv_hash` `recv_skip` `tailcall`
`unlink` `yield` (wired and never exercised), and `recv` (refused by
design). One demo image would close all but the last.

34 testbenches green in `run_tbs.sh quick`, 44 model tests, benchmarks
unchanged to the cycle.

## What supervision still does not have

* **A trapping process can be woken by an `{'EXIT', ...}` but cannot
  read it.** The message is in its mailbox, correctly shaped and
  hashed — `tb_fixed` asserts both from outside — but `recv_take`
  returns one word until the deserialiser is in the engine.
* **Restart policy**, which is `notes/13`'s point: mechanism in gates,
  policy in code. The mechanism is now here; the fifty-line
  `one_for_one` supervisor that inherits its WCET from it is a program,
  and it needs the deserialiser first.
* **Nothing from `notes/22` or this note has been on silicon.**

---

## Postscript: the timer's expiry test, and EHDL's `pipeline` macro

The sweep's inner loop was one combinational chain — a distributed-RAM
read of `deadlines[sweep]`, a 32-bit subtract against the free-running
counter, one bit test:

```elixir
diff    = cyc - deadlines[sweep]
expired = bnot(diff[31])
```

It is now two registered stages, written with EHDL's `pipeline` macro:

```elixir
pipeline :expiry, clock: :clk, reset: :rst do
  stage do p_dl   = deadlines[sweep] end
  stage do p_diff = cyc - p_dl end
end
```

The sweep is the only **streaming** datapath in this machine — one slot
per cycle, no feedback, and a consumer that could not care less about
two cycles when the sweep's own granularity is 32. Everywhere else is
an FSM with backpressure, which is the opposite shape: variable latency
negotiated by a handshake, not fixed latency with a valid bit. That is
why this is the only place the macro fits, and why the detection bound
moves from 32 cycles to 34 and nothing else changes.

### What the macro carries, and what it does not

It balanced `cyc` for us — stage two reads it one cycle after stage one
ran, so the macro emitted `cyc__dly_1` and used that. That is the
alignment this project has got wrong five times by hand.

It does **not** carry a tag. A pipeline stage is one `out = expr`
assignment, so the index saying *which slot* a result belongs to has to
be delayed alongside, by hand, to the same depth (`sw_d1`/`sw_d2`
here). Every real datapath carries a tag, so this is the macro's main
ergonomic gap.

### Two traps, both worth writing down

**A memory read after stage one corrupts the memory's name.** The
auto-balancer rewrites bare identifiers to delay taps, and it cannot
tell a memory from a signal at macro-expansion time, so `tbl[sweep]` in
stage two becomes `tbl__dly_1[...]` and elaboration dies with
`Unknown signal or parameter: tbl`. Loud, which is the good kind — but
keep every memory read in stage one.

**`pipeline` had never worked inside an instantiated component**, which
is to say it had never worked. Every stage output it declares has width
`:infer`, and `Hw.Compile.InferWidths.resolve` was only ever run on the
signals of the component being elaborated at the top. A child's signals
are read straight off `__hw_signals__` by the instance flattener, so
each inferred width survived into the parent as the `:infer` ATOM and
died in emit on `width - 1` — an `ArithmeticError` naming no signal, no
file and no line.

Standalone `Timer` elaborated perfectly. `BarrelEngine`, which
instantiates it, did not. `Instances.elaborate_instance/7` now resolves
a child's inferred widths in the child's own context before prefixing
them, guarded on the child actually declaring any, so designs with no
`:infer` signals pay nothing.

That is the **fifth** EHDL bug this project has found, and the first
that was not a width being inferred too narrow. It is a width not being
inferred at all.

### What it bought, which was not what was predicted

The prediction going in was "no timing, do it for the ergonomics" —
the timer was not on the critical path, and the path it is on
(`SignalTable`'s link-bitmap read-modify-write) is untouched.

| | before | after |
|---|---|---|
| fmax | 18.45 MHz | **19.37 MHz** |
| critical path | 54.18 ns | **51.64 ns** |
| — logic | 21.27 ns | 21.75 ns |
| — routing | 32.91 ns | **29.89 ns** |
| LUT4 | 16,986 | 16,959 |
| TRELLIS_FF | 3,432 | 3,507 |

+5%, and look at where it came from: the **logic** on the critical path
got marginally longer, and the **routing** got 3 ns shorter. The
timer's read-and-subtract was not on the critical path, but it was
competing for routing resource near something that was. Splitting it
gave the placer room.

Worth remembering the next time a path looks untouchable: on a design
at 21% fabric with routing at 58% of its critical path, the useful
question is not only "what is the longest chain" but "what is crowding
it".
