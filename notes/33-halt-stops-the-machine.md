# 33 — halt stops the machine

`notes/26` bug 2 has been open since the day it was written:

> **2. `halt` means two different things.** In `machine.ex` it stops the
> VM. In the engine it exits the process that executed it.

`notes/32` ended by pointing out that it had become the *only* place
where the model and the netlist still disagreed about a feature that
has shipped. This closes it.

## Freeze, not reset

The obvious reading of "halt stops the machine" is a processor-wide
reset: assert an internal reset across everything inside the engine,
leave the code memory and the literal pool alone because those are the
image, and come back up clean. The boundary is even already drawn in
the source — `code_mem` and `lit_pool` are the only two instances in
`BarrelEngine` that take no `rst`.

It is the wrong mechanism for three reasons, and the first one is
decisive.

**The model freezes.** `{:halt}` sets `halted: true` and `run/2`
returns; the processes are still sitting in `procs` with their windows,
their mailboxes and their pcs. If the oracle freezes and the netlist
erases, they are no longer answering the same question, and the oracle
is the entire point of having a model at all.

**A reset destroys the evidence.** `dbg_deaths`, `dbg_spawns`,
`faulted`/`fault_reason`/`fault_count` and the occupancy are the
machine's flight recorder, and they are what every testbench asserts
on. `tb_fixed:super_tmo_hit` asserts `WANT_OCC=1` — that a peer
*survived*. Reset the engine and there is nobody left to have survived.

**Nothing inside can tell the difference.** The VM is gone either way.
Freezing just leaves the corpse readable from outside, which is
strictly more useful and strictly cheaper.

So: a sticky `vm_halt` that stops every context fetching.

```elixir
f_en = band(cur_state == 1, bnot(frozen))
```

That is the whole mechanism in `BarrelSeq`. Contexts stay in whatever
state they were in; the timer still fires, the ring still delivers, the
seat unit still binds — and none of it goes anywhere, because nothing
fetches. Everything the machine knew when it stopped is still there to
be read.

## Three details that are not details

**`real_halt`, not `any_halt`.** `notes/31` widened `any_halt` to
include a top-level `ret`, because a process returning from its entry
function ends. A process ending is not the VM ending. Wiring the VM
halt to `any_halt` would have stopped the whole machine every time a
spawned function returned — which is to say, it would have replaced one
`halt` bug with a considerably worse one.

```elixir
real_halt = bor(c0_halt, bor(c1_halt, c2_halt))
any_halt  = bor(ret_top, real_halt)
```

**`out_valid` is gated, and the gate is exact.** The model stops
emitting the instant `halt` executes. The netlist sets a latch on the
clock edge after, so in principle some other context could slip an
`out` through in between. It cannot: one context is at X per cycle, and
`out` (0x51) and `halt` (0x52) are both system ops, which contract rule
3 forbids from sharing a bundle. Nothing can emit in the halting cycle,
and from the next one the latch is up. The two agree bundle for bundle,
not approximately.

**`idle` goes high.** A halted machine is idle — and it is the only
kind of idle that can have live processes in it, which is the point.

```elixir
idle = bor(band(occ == 0, rq_empty), vm_halt)
```

## Two engines

`erlang:halt/0` stops the runtime, and with the ring up the runtime is
both engines. That is a sideband — `halt_req` out, `halt_in` in, ORed
at the top — and deliberately not a ring packet. A packet queues behind
a FIFO that may be full, and the one thing a halt must never do is
wait for room.

`boot_en` clears it, so a halted machine can be re-booted with a new
image rather than needing the board reset. That falls out for free and
is what the `.pbi` loader will want.

## The model had to move too

Not much, but the part that moved is worth naming: `halt` now **reaps
its caller** — frees the seat, marks it dead, counts it — because that
is what the engine has always done and `dbg_deaths` is a number the
testbenches assert on. It does *not* go through `die/4`, for two
reasons: `die/4`'s first clause would hand the halt to a catch frame,
and `erlang:halt()` is not catchable in BEAM either; and `die/4`
propagates exit signals to links, which `halt` must not, because BEAM
runs no exit handler on the way down.

The corpse stays readable (`reap(..., keep: true)`), because on the
netlist the register windows are still sitting in the RAM after a halt,
and every `Machine` test that inspects the root process's registers
after `run/2` is asking exactly that question of the model. A dead
process nobody can look at would be a worse oracle, not a purer one.

Three tests asserted `Machine.deaths(m) == []` on programs that end in
`halt`. They meant "nothing crashed", and they now say so:

```elixir
assert Machine.deaths(m) |> Enum.reject(&match?({_, :normal}, &1)) == []
```

## The test that can only pass one way

`tb_fixed:vmhalt`:

```erlang
main() ->
    Me = erlang:self(),
    erlang:spawn(vmhalt, w, [Me]),
    receive X -> erlang:display(X) end,
    erlang:halt().

w(P) -> P ! 1, forever().

forever() -> forever().
```

The child sends *before* it starts looping, so by the time `main` halts
the child has provably run and is provably still runnable. Then it
spins in a tail-recursive loop that never ends on its own.

```
WANT_IDLE       the machine stopped
WANT_OCC=1      with a live process still in it
WANT_DEATHS=1   and only the caller of `halt` gone
```

An engine that exited one process would still be spinning in
`forever/0` when the cycle cap hit. `WANT_IDLE` is new to `tb_fixed`
for this, and it is the assertion that separates *the machine stopped*
from *every process finished* — two things every testbench before this
one was allowed to conflate.

## Four test programs were saying the wrong thing

The gate run after the change failed in three places, and every one of
them was a program using `halt` to mean **"this process is finished"**.

* `mk_m3_spawn8` — the root spawns eight workers and halts; each worker
  prints its argument and halts. Under a VM-wide halt the root freezes
  all eight before any of them runs, and the first worker to finish
  would freeze its seven siblings anyway.
* `mk_m3_fib` — the root spawns two fib workers and halts.
* `mk_m4_evict` — the root wakes exactly one evicted waiter and halts,
  which freezes the waiter it just woke. That waiter reporting 99 was
  the entire assertion.
* `mk_bench` b2 and b4 — four looping workers, and a hundred processes
  that exist only to spawn and stop, all of them halting.

None of these is a bug in the change. That idiom was only ever valid
because the engine was wrong, and `mk_super` says so in a comment
written months ago:

> The child SPINS rather than halting. `halt` is `erlang:halt/0` — the
> first process that halts ends the run before the root's deadline can
> expire. (The engine treats halt as a process exit, which is a
> divergence…)

Someone already knew, worked around it in one program, and wrote down
why. The others just never had two processes racing to say they were
done.

They all say `ret` now. Which is available to say because `notes/31`
gave a top-level `ret` its meaning eight days too late to have helped
here — a process that returns from its entry function exits with
`normal`, which is exactly "this process is finished", and it stops
nobody else.

`tb_ring2` is the one worth calling out separately: engine 0 used to
send its message and halt. It blocks now, and engine 1's halt at the
end of *its* program is what stops the machine — so the testbench's
terminating condition, "five outputs from engine 1 and engine 0 idle",
became evidence in its own right. Engine 0 is idle because a halt
crossed the sideband, and there is nothing else that could have
unblocked it.

## Where that leaves things

`notes/26`'s scoreboard has no open entry left that is a divergence
between the model and the gates. What remains on it is real work — 128
cells with no collector wired in, nine ops never executed by a compiled
program, `sd_boot` untested — but none of it is the two halves of this
project disagreeing about what an instruction means.
