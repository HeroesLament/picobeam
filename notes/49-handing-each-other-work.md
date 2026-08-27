# 49 — Handing each other work

`notes/47` decided cross-engine spawn, sized it at four state machines
and a testbench, and stopped. This note is what got built, what turned
out not to need building, and the three bugs found on the way — one of
which had nothing to do with spawn and had been sitting in the message
path since the ring existed.

The headline: `tb_spawn2` passes. One image, two engines, and a process
running on the engine that was never booted, created because the other
engine asked for it.

---

## 1. The piece that was not needed

`notes/47`'s fourth piece was the sender's park:

> A remote spawn must park the requesting context, and resume it with
> the pid in `rd` and the pc ADVANCED — not replayed. Every park the
> machine has today replays. […] it is four replicas of `BarrelSeq`
> away, and `BarrelSeq` is the module where a mistake is four identical
> mistakes.

That was wrong, and pleasantly so. **State 9 is already that park.**

```elixir
if is_spawn == 1 do
  tgt0 = pc_target
  cstate0 = 9
end
...
spawn_go = band(cur_state == 9, spawn_ready)
...
if band(spawn_go, seat == 0) == 1 do
  pc0 = pc0 + 1
  cstate0 = 1
end
```

A spawn park already waits for an answer, already advances its own pc
when the answer comes, and already does not replay. It was built that
way for a LOCAL spawn, whose answer arrives in one cycle from
`SeatUnit` — but nothing in it cares how long the answer takes or where
it comes from. A remote spawn is the same park with a slower oracle.

So `BarrelSeq` gained one line, not four state machines:

```elixir
spawn_park = cur_state == 9
```

"This seat is parked on a spawn, right now, at its own F slot" — the
question, exposed separately from the answer, because for a remote
spawn the two are hundreds of cycles apart. Everything else on the
sender's side is engine-level: `spawn_ready` and `spawn_full` become a
mux, and `spawn_commit` splits into `sc_local` and `sc_rem`.

The lesson is the one `notes/32` also learned: **look at what the park
already does before designing a park.** Three of the four pieces were
real. The one that was estimated highest did not exist.

## 2. The piece that changed shape: the arguments

`notes/47` decided the arguments cross as ONE serialised term, the
arity-N tuple of them, rebuilt on the far side by `DeserUnit`. That is
the honest answer for `spawn/3` in general, and it is still the right
answer for the general case.

It is not what got built, because of the placement rule:

```elixir
target =
  if Enum.all?(args, &immediate?/1) do
    rem(eid + e0.spawn_rr, m.n_engines)
  else
    eid
  end
```

**A spawn goes remote only if every argument is immediate.** A boxed
argument is a pointer into this engine's heap; the far end cannot read
it; so a spawn carrying one stays home. That is a placement decision,
and placement is allowed to be a decision — BEAM promises nothing about
which scheduler a process lands on. Nothing about the program's meaning
changes; only where it runs.

And once the arguments are all immediate, they *are* the wire format.
A `spawn_req` is:

```
  head:  kind 1, deng = target, word = REQUESTER's pid, len = 1 + arity
  flit0: arity << 9 | entry pc
  flit1..N: the arguments, as words
```

No serialiser, no deserialiser, no heap allocation on either side, and
no room check — because nothing is allocated. The reply is one flit:

```
  head:  kind 2, deng = requester's engine, word = REQUESTER's pid, len = 1
  flit0: the child's PID
```

The requester's pid in the reply head is not decoration. It means the
ingress's existing incarnation check applies to a spawn reply for free:
a requester that died while its child was being created gets its reply
dropped by the same comparison that dead-letters a message.

The request head ignores that check, and has to: the head word is the
requester's pid, which names a slot in the SENDER's table, and checking
it here would be checking a stranger's slot number.

**What this costs.** `spawn(fun, [SomeList])` stays on the engine that
built the list. That is a real limitation and it is written here rather
than hidden: the general path is `notes/47`'s serialised term, it is
designed, and it is not built. What is built is exact rather than
conservative — the engine tracks boxedness per staged register, so
`spawn(f, [1, 2, 3])` with three integers crosses and only a genuinely
unsendable argument keeps a spawn at home.

## 3. The exactness: a bitmap, not a guess

The model asks `Enum.all?(args, &immediate?/1)`. The gates have to
answer the same question about sixteen staging registers, at X, in one
cycle, before the spawn parks.

Per-seat, sixteen bits, updated as each argument is STAGED:

```elixir
bx_set = band(bx_w0, bx_d0) * (1 <<< rd0) + ...
bx_clr = bx_w0 * (1 <<< rd0) + ...
bx0 = bor(band(bx0, bnot(bx_clr)), bx_set)
```

Set-and-clear, not set-only: a staged register can go from a list to an
integer between two spawns, and a stale set bit would strand every
later spawn at home for no reason.

The arity comes off the instruction. `spawn`'s twelve-bit immediate had
three spare bits above its nine-bit target, and they now carry it:

```elixir
si(:spawn, rd, (arity &&& 0x7) <<< 9 ||| (t &&& 0x1FF))
```

Which caps a remote spawn's arity at 7. `Encoding` raises rather than
truncating, and says why. Seven is not a limit anyone will hit — but it
is a limit, and an encoding that silently wrapped would have been the
`notes/15` emitter-width bug again.

Then:

```elixir
sp_mask = bnot(65535 <<< sp_arity_x)
sp_boxed_x = band(bx_cur, sp_mask) != 0
```

Masking to `(1 << arity) - 1` is what makes the stale bits above the
arity harmless — every index below it is written by an `arg` before the
spawn that reads it.

## 4. Placement, and the one expression that is not the model's

```elixir
sp_tgt = band(eng_id + sp_rr, N_ENG - 1)
```

The model says `rem(eid + spawn_rr, n)`. These agree for a power-of-two
engine count and disagree otherwise. Every fabric this design fits is
1, 2 or 4 engines, so they agree everywhere it matters — and this
sentence exists so the two expressions are compared here rather than by
eye, later, by someone wondering why a nine-engine model run places
differently.

`N_ENG` is a `param` with default 1, so `band(N_ENG > 1, …)` folds to
zero and the entire remote path disappears from a single-engine build.
Every existing testbench is untouched, which is how the whole feature
landed without moving a single M3-era expectation.

That folding is also why `tb_spawn2` drives a new component, `Duo`,
rather than two `barrel_engine`s wired up in Verilog: EHDL folds a param
at elaboration into a `localparam`, and Verilog cannot override a
`localparam`. A two-engine configuration has to be chosen on an
`instance`, so it has to be a module.

## 5. The receiving half

`SeatUnit` gained a remote creation: `rsp_req`/`rsp_pc` in,
`rsp_ok`/`rsp_slot`/`rsp_serial`/`rsp_done` out. It is `spawn_commit`
minus the staging drain and minus the pid write-back, with the pc off
the wire.

It needs one new state, and the reason is a GC argument rather than a
correctness-of-spawn argument: nothing drains into the newborn's save
area, and a save area holding a dead process's registers is a set of
roots that would resurrect its garbage. So state 6 writes all sixteen
words — the arguments below the arity, zero above:

```elixir
sv_wd = sv_gcw * gc_data + sv_zw * rsp_arg_d +
          band(bnot(bor(sv_gcw, sv_zw)), 1) * spill_data
```

Three writers, one write site, mutually exclusive by state. `rz_i` is a
counter of its own rather than `sv_cnt`, which state 2 already writes —
one write site per register, the rule that has held all project.

The run-queue push waits for `rsp_done`, and so does the reply. A pid
the requester can send to is a pid whose process has registers.

A full proc table on the receiving engine answers `:system_limit` — a
reply carrying a zero pid, which the requester dies of — rather than
holding the request until a slot frees. Waiting would be a ring that
wedges on a table that may never drain; dying is what a local spawn
into a full table already does (`notes/13`).

## 6. The ring got a second producer

It had exactly one: the serialiser. A reply must not be able to
interleave into the middle of somebody's message, so this is an arbiter
and not a mux — the FSM takes the ring WHOLE:

```elixir
rt_busy = rt_st != 0
rg_ready = band(ring_w_ready, bnot(rt_busy))
```

and every serialiser test of readiness goes through `rg_ready` instead
of `ring_w_ready`. A serialiser mid-packet simply sees a ring that is
not ready and stalls, which is the behaviour it already has for a full
ring. One expression, one place, and no new stall path.

The FSM's collect state exists because the staging drain cannot be
paused: sixteen words over sixteen cycles, free-running. So the first
eight are latched and transmitted afterwards at the ring's pace.

The drain is claimed at the parked seat's own F slot — the same cycle a
local spawn would commit on. That is not a coincidence, it is the
point: `BarrelSeq` gives at most one context an F slot per cycle, and
`op_call` and `op_spawn` are two states of the same context, so the
drain stays single-claimant with no arbiter. The claims-without-an-
arbiter rule from `notes/12` paid for itself again.

---

## 7. Three bugs

### 27. `rt_kind + 1` in a one-bit wire is zero

The egress computed the packet kind as a flag plus one:

```elixir
ring_w_kind = rt_busy * (rt_kind + 1)   # rt_kind: 1 bit
```

For a request (`rt_kind = 0`) that is 1, and requests worked. For a
reply (`rt_kind = 1`) it is `1 + 1` in one bit, which is **0** — so
every reply went out as a MESSAGE, was enqueued into the requester's
mailbox as garbage, and the requester stayed parked forever.

Verilog's self-determined width rule, for the third time in this
project. `notes/26` entry 26 was `to_base + CELLS` overflowing eight
bits; the emitter widths in `notes/15` were the same species. The fix
is the same one every time: **do not compute a value in a field narrower
than the value.** `rt_kind` now holds the actual ring kind — 1 for a
request, 2 for a reply — and the egress does not do arithmetic on it.

The lesson worth keeping: the flag-plus-one encoding *looked* smaller.
A one-bit register and an adder is not smaller than a four-bit register
when the adder is wrong.

### 28. `spawn_park` is true at every F slot, not just the first

```elixir
rt_start = band(spawn_park, band(f_rem, band(bnot(ro_busy), …)))
```

`ro_busy` clears when the reply lands. But the seat is STILL parked —
it does not resume until the pid has been written back and
`spawn_ready` goes high, which is a couple of turns later. In that gap
`spawn_park` is true and `ro_busy` is false, so the next F slot started
a *second* request and wiped `ro_have` on the way past — the answer it
had just been given.

The machine spawned a fresh process on engine 1 every four cycles until
the table filled, then started replying `:system_limit`.

The guard was the wrong question. The transaction is not over when the
reply lands; it is over when the spawn COMMITS:

```elixir
band(bnot(bor(ro_busy, bor(ro_have, ro_pdone))), …)
```

Same shape as `notes/46`'s `gc_hold`: a state machine whose "busy" flag
clears one step before the work is actually finished, and something
else reads the gap.

### 29. A message off the ring never woke anybody

This one is not about spawn. It has been in the machine since the ring
carried its first message.

```elixir
wake_en = bor(delivered, band(sd_en, sd_st == 4 + sd_kind))
```

Two wake sources: a local delivery, and the exit-signal emitter. **A
ring arrival is not one of them.** A process blocked in `receive` on
engine 1 stayed blocked when engine 0 sent to it. Forever.

`tb_ring2` could not see it, and this is the interesting part: its
receiver SPINS.

```
:scan
  recv_peek 1, :none
  recv_take 1
  ...
:none
  jmp :scan
```

A spinning receiver never blocks, so it never needs waking. The one
program shape that does not exercise the wake is the shape the only
cross-ring test was written in — and it was written that way for an
unrelated reason (it was bringing up the ingress, and a spin loop is
easier to reason about when you do not yet trust delivery).

The first program to BLOCK across the ring was `echo` in `tb_spawn2`,
and it found it immediately.

The fix is a third source, riding the last flit for the same reason the
exit emitter's does — waking on the first would let the matcher see a
head whose continuations have not landed:

```elixir
rg_last = band(mb_rg, rg_left == 1)
wake_en = bor(delivered, bor(sd_wake, rg_last))
```

with `wake_queued` gaining the evicted case through `pt_rd5_state`,
which is the port the incarnation check already reads. Three sources,
three ports, because a send's target is on rd2, an exit's on rd3 and a
ring arrival's on rd5, and one comparison against one port cannot serve
all three.

**What to take from it.** A test that avoids a mechanism does not test
it, however close it looks. `tb_ring2` sends a message from one engine
to another and reads it back correctly at the far end; it is a real
test of the ring and it says nothing whatever about waking. The gap was
not in the coverage of *packets*, it was in the coverage of *receiver
states*, and no packet-shaped test was ever going to find it.

### And one divergence, not a bug in either half

The model numbered incarnation serials PER ENGINE; the gates number
them PER SLOT. The same program gives the second process serial 2 in
the model and serial 1 in the gates.

Thirty-odd testbenches never noticed, because no test had ever printed
a second pid — `tb_m3_pass7` checks that the parent's pid and the
child's `self` AGREE, which they do under either scheme. A cross-engine
spawn's whole answer *is* a pid, so `tb_spawn2` prints two and the
divergence surfaced on the first run.

The model moved. `ProcTable` says in its own comment that a slot's
first life is serial 1, `notes/13` sized 22 bits as an ABA guard for a
recycled SLOT, and per-slot is 32× the reuse depth of a shared counter.
The gates had the design rationale written down; the model had a
counter.

---

## 8. What this is worth

`notes/44` said "two engines that cannot talk are one engine and a
spare", and `notes/47` corrected it to "they talk, they just cannot
hand each other work". Both sentences are now historical.

What a two-engine picoBEAM does today:

* engine 0 boots; engine 1 is loaded with the same code and no process
* a `spawn` with immediate arguments places round-robin from home
* the request crosses as one packet, the reply as another
* the child runs, receives across the ring while BLOCKED, and answers
* `self` on the child equals the pid `spawn` handed the parent

`tb_spawn2` asserts all of it against `Machine.run/2` with `engines: 2`,
word for word, and the whole transaction completes in about 600 cycles.

What it does not do yet: carry a boxed argument (§2), spread a spawn
across more than the round robin (there is no load information and
nowhere to put it), or migrate a running process. The first is designed
in `notes/47`. The other two are not designed, and should not be until
something needs them.
