# 31 — Return is an exit

`notes/30` shipped five OTP shapes in one sitting and then measured
them on the netlist rather than trusting the model. Four passed.
`spawn_link/3` did not: a program that spawned one child, printed, and
halted produced **459 outputs** on the gates where the model produced
one, alternating `2, 1, 2, 1, …` as if the whole program were running
over and over.

I filed it as "fix `spawn_link` on the gates". That was the wrong
title. This note is about what it actually was, which is older,
simpler, and much more serious than a broken builtin.

## The link was innocent

The first useful thing was to delete a line. `spawn_link/3` lowers to
`spawn` followed by `link`; dropping the `link` leaves

```erlang
main() ->
    erlang:spawn(sp1, w, [1]),
    erlang:display(2),
    erlang:halt().

w(N) -> erlang:display(N).
```

which fails identically — 459 outputs, same alternation. So the bug
was in `spawn`, or in something `spawn` merely exposed. Everything
`notes/30` said about `spawn_link` being "spawn plus link, non-atomic
by one bundle" was true and irrelevant.

## The trace

`tb_fixed` grew a `TRACE_PC` window — every bundle the X stage retires,
between `-DT0` and `-DT1`. There was already a `TRACE2` that did this,
with the time window hard-coded to one past investigation, which is
useful exactly once and I had already spent it.

```
T=3325000  X seat=3 slot=0 pc=0  occ=1  out=0
T=3365000  X seat=3 slot=0 pc=1  occ=1  out=0
T=3405000  X seat=3 slot=0 pc=2  occ=1  out=0     spawn
T=3485000  X seat=3 slot=0 pc=3  occ=2  out=0
T=3525000  X seat=3 slot=0 pc=4  occ=2  out=1  outd=…2
T=3565000  X seat=3 slot=0 pc=5  occ=2  out=0     halt
T=4305000  X seat=1 slot=1 pc=8  occ=1  out=1  outd=…1
T=4345000  X seat=1 slot=1 pc=9  occ=1  out=0     ret
T=5065000  X seat=1 slot=1 pc=0  occ=1  out=0     ← main, again
T=5105000  X seat=1 slot=1 pc=1  occ=1  out=0
T=5145000  X seat=1 slot=1 pc=2  occ=1  out=0     spawn, again
```

Slot 1 is the child. It runs `w/1` at pc 8, prints its argument,
executes `ret` at pc 9 — and then continues at **pc 0**, which is
`main`. It spawns a grandchild, prints 2, halts. The grandchild does
the same. The population never drops to zero, so the machine never goes
idle, and the testbench's cycle cap is the only thing that stops it.

## What `ret` did

`ret` pops the frame stack, reads the popped frame's link, and jumps
there. `FrameRamProc` keeps one 4-bit depth per slot in a shift-indexed
register file; `pop_ok` is `pop_en && depth != 0`, so at depth 0 the pop
is refused, the depth stays 0 — and `ret_pc_out` reads the link at
depth 0, which for a process that has never called anything is zero.
Bundle zero is the image's entry point. The child fell into `main`.

There has never been anything in the engine that says **a process whose
entry function returns is finished**. It never showed up because every
program written for this machine so far either ends in `halt`, or loops
forever in `receive`, or dies. `w/1` was the first function that simply
ran off its own end.

The model has always had it, five lines from the top of `do_ret`:

```elixir
case p.rstack do
  [] -> die(m, eid, p, :normal)
  ...
```

which is BEAM's rule, and is why the model reported one output and the
gates reported 459.

## The fix

`ret` at depth 0 is not a return; it is the process ending with reason
`normal`. The engine has to know that at X, before the pop is issued,
so it can route the bundle down the death path instead of the return
path.

`FrameRamProc` grew a third view of the depth file — read-only,
addressed by whatever slot the caller names:

```elixir
input :q_slot, 5
output :q_depth, 4
# ...
q_depth = band(depths >>> (q_slot * 4), 15)
```

`depth_out`, the port that already existed, could not answer: it is
keyed by `fill_slot`, which belongs to the context streaming a fill
some eighteen turns later, not to the one decoding now. The file is a
register, so a second read is a mux and costs nothing structural.

The engine wires `q_slot` to the X context's slot and splits `any_ret`:

```elixir
raw_ret  = bor(c0_ret, bor(c1_ret, c2_ret))
ret_top  = band(raw_ret, x_depth == 0)
any_ret  = band(raw_ret, bnot(ret_top))
any_halt = bor(ret_top, bor(c0_halt, bor(c1_halt, c2_halt)))
```

Everything downstream follows for free: `any_ret` is what latches the
returned value into the seat's `rv` register, and a top-level return
has nowhere to put one, so suppressing it is correct rather than merely
convenient. `BarrelSeq` already routes `is_halt` to state 6 and the
seat unit already frees the slot with reason `normal`.

## The sibling bug, found in the same file

While reading `FrameRamProc` I noticed it has raised an `overflow`
output since M3 pass 5, and the engine declares

```elixir
wire :fr_ovf, 1
wire :fr_unf, 1
```

wires them to the instance — and reads neither. `fr_unf` is now
redundant (`ret_top` catches the same condition one turn earlier and
does something about it), but `fr_ovf` was a real hole: `push_ok` is
`push_en && depth < 15`, so the sixteenth nested call pushed no frame,
recorded no link, and returned into the fifteenth caller's frame. A
wrong answer, silently, with no fault.

Same query port, same shape:

```elixir
stk_ovf = band(any_call, x_depth == 15)
```

folded into `any_fault` with reserved atom 8, `:stack_overflow` — the
name `FrameRamProc`'s own moduledoc has claimed since pass 5.

## And the model followed the hardware, not the reverse

`Machine` had `@max_rstack 64`. The machine has fifteen frames. A model
that faults at 64 is the wrong oracle for exactly the programs that
need one, so it is now 15, with the reason written next to it: widening
this is a memory-count change in the RTL first, and the constant
follows.

45 model tests still pass, which says something slightly uncomfortable
about how much recursion depth the test suite exercises.

## What this cost, and what it bought

Two testbenches:

* **`tb_fixed:slink`** — `spawn_link` a child that sends a result back
  and *returns*; the parent blocks in `receive`. `WANT_DEATHS=2`,
  `WANT_OCC=0` is the whole assertion: the child must have exited on
  its own, or it would still be there having re-entered `main`.
* **`tb_fixed:deep`** — thirty levels of non-tail recursion into a
  fifteen-frame store, `WANT_FAULT=8`. `tailloop` already proves the
  tail case stays flat; the two together are the contract.

The thing worth saying plainly: this was not a bug in `spawn_link`, and
`notes/30`'s conformance table was wrong about which row was red. Every
process this machine has ever run has been one that ended by asking to.
The first one that just *finished* fell off the edge of the world.

## Still open

`halt` is still two different things. `erlang:halt()` in BEAM stops the
VM; in the model it stops the VM; on the gates it exits one process.
That is `notes/26` bug 2 and it is now the last divergence between the
two in a shipped feature — `slink` had to be written so the parent
halts *last* to avoid tripping over it.
