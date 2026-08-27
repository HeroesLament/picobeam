# 50 — Sixteen registers, and a name

Mac's charge, verbatim: the 16-register window and `register`/`whereis`
are "literally all we have left before we have a project I can actually
show someone else." This note is both, the five compiler bugs it took
to make recycling sound, and the two BEAM-correctness bugs in `exit/2`
that the name demo flushed out of gates that had been green for weeks.

---

## 1. The window was never the problem

`notes/26` entry 22 says it in its own title: "one 16-register window,
**and the front end leaks into it**." The ISA's register fields are four
bits — sixteen registers is not a limit that can move without re-cutting
the slot encoding — but ordinary Elixir rarely has sixteen values LIVE
at once. It had sixteen values *ever named* by the fifth line, because
`new_reg` was a bump allocator that never freed anything:

```elixir
a1 = f()      # r0, forever
a2 = g(a1)    # r1, forever — a1 is dead and r0 is not coming back
a3 = h(a2)    # r2, forever...
```

`notes/45`: it raised four times while writing `board_demo` alone, and
every workaround was the same workaround — split the function — and a
16 KLOC application cannot be written that way.

The fix is liveness. One prepass counts each variable's occurrences;
each compiled occurrence decrements; at zero the binding dies and its
register returns to a pool the allocator draws from before bumping.
`mix test` says what that is worth: a 40-step chain compiles where ~8
used to be the wall, and a function with seventeen values genuinely
live at one point still raises — now with a message that says LIVE and
means it.

## 2. What it took to make that sound

The bump allocator had one great virtue: it could not reuse a register
too early. A recycler can, and the instruction stream is not the
execution order — clauses fall through, loops jump back, receive
bodies run once. Five bugs, each a lesson in that gap:

**Deaths are pended, not freed.** A variable's last occurrence is
consumed at compile position X, but the instruction that READS the
register may be emitted after X (a tuple's `tset`s, a call's `arg`
staging). So death moves a register to `pend`, and only a statement
boundary (`reap`, at `c_let`/`c_seq`/clause edges) moves `pend` to the
pool — by which point every consumer is emitted.

**Loops hold everything.** Inside a `receive` scan loop, textual
last-use is a lie: the guard that read a variable this iteration reads
it again next iteration. Reaping is suspended (`hold`) across any
region a backward jump can re-enter. The counterweight is that a
receive's TAKEN body is exit-bound — it runs once, on the final pass —
so the hold lifts inside it, with one fence: registers it frees go back
to `pend`, not the pool, so nothing it freed can surface in a later
clause's pattern test, which is loop-region code.

**Tests allocate bump-only.** The scrutinee of a `case` is read by
every later clause's tests with no variable occurrence to count. Rather
than pin registers (tried it: the pins stack down the spine of
`=`-matches and strand dead registers — every `=` in Elixir nests a
clause, so the spine is the whole function), the invariant is: pattern
tests and guards allocate from the bump pointer only. A register freed
in an earlier clause's body can never become a later clause's test
temporary — the only allocation that executes on the fall-through path.

**Scratch cleans up after itself.** On that same `=`-match spine the
per-clause rewind never runs (the clause body IS the rest of the
function), so every literal test's temporaries — one `lda`, one `cmpne`
scratch — were a register each, permanently. `lit_test`, `tag_check`,
`tuple_shape_check` and `guard_test` now rewind their own allocations:
nothing a comparison emits survives its branch.

**Restores must respect binds.** The clause machinery swaps the pool
out during tests and restores it after. `bind` rescues a register from
the pool when a pattern aliases it — against the swapped-out EMPTY
pool. The restore then resurrected the register while it was bound: in
`sum(N, Acc)`, the literal `1` of `N - 1` was allocated INTO N's
register, and the function returned its accumulator after one step.
Every restore now excludes anything with a live binding — `rc` is the
census.

The register-count debug dump (`PB_REGDBG=1`) that found bugs three
through five is left in, because the sixth bug will want it.

## 3. `register`/`whereis`: a CAM, node-local

Three ops — `reg_name` 0x55, `whereis` 0x56, `unreg` 0x57 — and one
new hardware unit. `NameTable` is eight entries of {atom, slot, serial}
in flops, fully associative, because every question asked of it is a
parallel compare: which entry holds this atom (`whereis`, and the send
path), is this atom or this pid already present (`register`'s
legality), which entry holds this slot+serial (a death).

**Per engine, because an engine is a node** (`notes/12`). BEAM's
registry is node-local; `whereis/1` on another node answers
`:undefined` there too. The two-engine test registers `:root` on
engine 0, spawns a child across the ring, and the child's `whereis`
finds nothing — which is not a limitation, it is the semantics. The
model's table is a map on the engine struct; both sides refuse the
ninth name with `:system_limit`, by agreement rather than accident.

**`Name ! Msg` costs nothing.** An atom destination resolves through
the CAM combinationally, one mux ahead of `SendUnit`; a hit substitutes
the pid (alive by construction — the table clears on death), and a miss
leaves the atom to fall into the existing bad-destination path, which
makes "send to an unregistered name is badarg on the sender" true for
free. The serial rides each entry so a death clears only the
incarnation that registered.

**BEAM's rules, all of them, at X:** the name is an atom and not
`:undefined`; the pid is a live pid ON THIS ENGINE (the aliveness read
borrows `ProcTable`'s rd2, which a register op's X cycle leaves free —
same trick the supervision ops use); the name is unbound; the process
is unnamed. Any miss is badarg on the caller. Auto-unregister rides the
same `died` strobe the link table already watches.

## 4. The bug the name demo flushed out: a lost wakeup

`tb_fixed:names` — the board demo as a gate entry — wedged at the
send-to-name step, and the reason had nothing to do with names.

A compound local send finishes cycles after its X: the serialiser
streams the flits into the target's mailbox one per cycle. But the
WAKE rode `delivered`, which fires AT X — before the message exists.
The receiver woke to an empty mailbox, found nothing, re-parked, and
the completed stream woke nobody. Forever.

This is `notes/26` entry 31 — "a message off the ring never woke a
blocked process" — one path over, and it was found the same way: by
the first program whose receiver BLOCKS at the wrong moment. The race
window is a handful of cycles, and every earlier compound-send test
happened to have its receiver already parked (wake at X, re-check at
wait, flits land in between) or spinning.

The fix is the rule the exit emitter and the ring ingress already
follow: **the wake rides the completion**. `ser_wake` fires on
`ser_done` for a local stream, with a sixth `ProcTable` read port for
the queued-receiver check, because at completion time no existing port
is guaranteed free. `delivered` stays a wake source — an early wake is
spurious and survivable; a missing final one is a hang.

Three wake sources became four. The pattern to keep: a delivery that
takes N cycles wakes at cycle N, not cycle 0, and every new transport
path will want this said again.

## 5. ...and two `exit/2` bugs that were never right

The demo kills its server with `exit(pid, :kill)` and checks the
reason. The gates reported reason 2 — `:kill`, the signal — where BEAM
(and the model, all along) records `:killed`. And worse, hiding behind
it: the gates routed `exit2` through the trap check FIRST, so a
trapping process would have converted a kill into a mailbox message
and survived. BEAM is emphatic that `exit(Pid, kill)` is untrappable.

Both were sitting in a green test suite, because no test had ever
killed a process and then LOOKED at the reason, and none had aimed
`kill` at a trap_exit process. Both are two lines:

```elixir
if band(pt_rd3_trap, ex_reason != 2) == 1 do   # kill traps nobody
...
dm_reason = (ex_reason == 2) * 1 + band(ex_reason != 2, 1) * ex_reason
```

A supervisor matching on exit reasons would have seen an atom BEAM
never delivers. Mac's standing directive — BEAM and OTP correctness
over everything — is exactly the lens that makes these two lines the
most important in this note.

## 6. What this closes

From `notes/48`'s knowingly-absent list, updated by `notes/49` and now
this: cross-engine spawn is DONE, `register`/`whereis` is DONE, the
16-register window no longer stops ordinary Elixir — the compiler
recycles, and the honest raise now names simultaneous LIVE values.

What remains from that list is ETS, `call_ext`/code loading (`notes/42`
designs it), and the collector's last distance to zero pause — none of
which gates "a project I can show someone else."

The proof, as always, is the machine: `priv/demo/names_demo.ex` runs a
24-binding chain the old compiler could not compile, registers a
server, finds it by name, sends through the name, kills it, watches
the name clear, and prints `2a` — through the real Elixir compiler,
onto the ECP5.

---

## Postscript: the board

`p000 0 d 00 001 002 0 5 2a 80 01 01` — `OO=2a`, every step verified;
one spawn, two deaths, and `XX=01`: the last abnormal death's reason
reads `:killed`, which is the `exit2` fix observable on a UART. Before
it, that byte would have said `02` — an atom BEAM never delivers.

Cost on the ECP5: 50,370 LUT4 / 12,945 FF (from 45,115 / 12,241 at
`notes/49`), routed Fmax **12.50 MHz, PASS at 12.00**. The margin
thinned from 13.52 — the CAM's parallel compares and the send-resolve
mux are on or near the critical path now, and whoever lands the next
feature on the send path should look at the timing report before
assuming the headroom is still there.
