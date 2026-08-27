# 25 — The first Erlang module, and the three bugs between it and silicon

`scripts/mk_erlsup.exs` compiles this, with `erlc`'s own Core Erlang as
the front end and `PicoBEAM.Erl` as the back end, and runs it on the
emitted netlist:

```erlang
-module(sup).
-export([main/0, worker/1]).

main() ->
    process_flag(trap_exit, true),
    P = spawn(sup, worker, [7]),
    link(P),
    erlang:display(1),
    receive
        {'EXIT', From, Reason} ->
            erlang:display(Reason),
            erlang:display(is_pid(From))
    after 5000 ->
        erlang:display(2)
    end,
    erlang:display(99),
    erlang:halt().

worker(N) ->
    erlang:display(N),
    exit(self(), badarith).
```

78 bundles. The gates print `1, 7, badarith, true, 99` — the same five
words the reference model prints, compared word for word by
`run_tbs.sh` as `tb_fixed:erlsup`. It is the first program on picoBEAM
that was written as Erlang rather than as bundles, and it exercises
`process_flag(trap_exit, true)`, `spawn/3`, `link/1`, `exit/2`, a
`receive` with a tuple pattern and an `after` clause, and the
deserialiser rebuilding a message a signal left behind.

Getting there took three bugs. All three were found the same way: a
transcript of every X-stage retirement (`scripts/tb_trace.v`) diffed
against what the disassembly said should happen. None of them were
visible from the outputs alone.

## Bug 1 — `recv_peek`'s none-label read as zero

The symptom was a module that printed `1 7 1 7 1 7 …` forever: `main`
restarting. The transcript said exactly that, in one line:

```
X 511 seat=0 slot=0 pc=12      <- recv_peek 5, 15
X 519 seat=0 slot=0 pc=0       <- ...resumed at 0, not 15
```

`BarrelSeq` latches a failed peek's none-label off `pc_target`, the
same wire a `call`/`jmp`/`spawn` uses. But the engine builds
`pc_target` from a mask —

```elixir
ctl0 = bor(c0_jmp, bor(br0, bor(c0_call, c0_spawn)))
```

— and `recv_peek` was not in it. So the target was zero, and every
receive whose first scan missed restarted the module.

The mask is safe to extend: rule 3 says a bundle holds at most one
system op, and jmp/call/spawn/peek are all system ops, so no two of
them can want the mux in the same cycle.

This is the same failure shape as `unblock_pc` in `notes/24` and as
the four width bugs before it: **a value that is produced at one site
and consumed at another, where the producing site was never wired.**
The undeclared-net guard now in EHDL catches the version of this where
the name does not exist at all. It cannot catch this one, where the
name exists and the mux term is missing. What catches this one is a
transcript.

## Bug 2 — the peek returned a word where the model returned a term

With bug 1 fixed the module ran to completion but printed a heap
POINTER where the model printed `{:EXIT, …}`, and once the receive
clause was written as a real pattern rather than a catch-all it stopped
matching at all and fell through to the timeout.

The cause is an ISA divergence, not a wiring mistake. The hardware's
`recv_peek` yielded the message's HEAD FLIT, and `recv_take` was what
ran the deserialiser. But BEAM's own lowering of `receive` looks
*inside* the candidate before deciding to remove it —

```
recv_peek        -> r4
istag  r4, tuple
tarity r9, r4
tget   r11, r4, 0     <- 'EXIT'?
...
recv_take r4          <- only now
```

— so a peek that answers with one flit cannot support any pattern more
specific than `_`. **The candidate has to be a term by the time the
clause tests it.**

So the rebuild moved to the peek. A scan hit on a message of more than
one flit now parks the context (`scan_long`, sequencer state 14, the
one the take already used), rebuilds, and puts the rebuilt pointer in
the per-seat latch where the head flit used to sit. `recv_take` is now
always the short path: hand over the latch, free the entry. The
deserialiser no longer drives the mailbox at all.

The price is a rebuild for candidates the clause then rejects — heap
garbage, bounded by the length of the scan, and an honest cost in a
machine with no GC. `recv_hash` remains the way to avoid most of it:
filtering by shape before rebuilding is an optimisation ON TOP of
this, not a substitute for it, because a hash cannot decide a
value-level test.

The front end needed one matching change. `remove_message` was
allocating a scratch register for the take's destination; it now
writes back over the register the peek bound, which is what BEAM's
semantics say anyway — the message you peeked is the message you
removed.

## Bug 3 — a killed process's reason did not propagate

With both fixed, the `{'EXIT', …}` still never arrived; the receive sat
until its 5000-tick timeout. The transcript again:

```
PT  578 cmd=6 slot=1 pc=3      <- doom, reason 3 = badarith
DIE 580 slot=1 reason=0        <- ...and the signal table heard 0
```

`SignalTable` only walks a dying slot's link set when the reason
propagates:

```elixir
propagates = die_reason != 0
rest = propagates * links[die_slot]
```

and the engine was handing it `died_fault * any_fault_r` — the
**X-stage** fault reason. A process killed by a signal never faulted at
X, so that reads `normal`, and `normal` does not propagate. The
supervisor was linked, was trapping, and was never told.

`notes/24` had already found the same laundering on the RECORDING side
— a doomed slot's reason being overwritten at free time — and fixed it
in `ProcTable`. The propagating side had the same hole and was missed
because nothing until now read the reason back out. `ProcTable` grew a
fourth read port on its `reasons` column (it had none: the column was
write-only), and the engine takes the reason from there whenever the
dying slot is doomed.

Transitive propagation is required behaviour: if A is linked to B and
C, and B kills A, then C hears about it too, with B's reason. That now
works because the reason survives the hop.

## What the transcript bought

Three bugs, three subsystems — sequencer, ISA semantics, signal
propagation — and none of them produced a wrong VALUE. The first
produced a loop, the second a silent non-match, the third a timeout.
Output-comparison testbenches say a program failed; they do not say
where. Thirty lines of `$display` on `dbg_x_en`/`dbg_pc` said where,
three times, in the first run each time.

`scripts/tb_trace.v` is kept for that reason. It asserts nothing.
