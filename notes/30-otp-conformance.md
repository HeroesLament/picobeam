# 30 — OTP conformance, measured

The instruction was: get the BEAM and OTP API right, and worry about
the FPGA later. So the first thing was to stop guessing which Erlang
shapes work and count.

Fifteen small modules, each one construct, compiled through
`PicoBEAM.Erl` and run on the model.

## Before

    PASS  guards (when)              PASS  bang (!) send operator
    PASS  multi-clause heads         PASS  arithmetic: div and rem
    PASS  if expression              PASS  boolean andalso / orelse
    PASS  case on a tuple            FAIL  try / catch
    PASS  list pattern [H|T]         FAIL  spawn_link/3
    FAIL  gen_server receive loop     FAIL  lists:reverse/1
    FAIL  exit reason as a TUPLE      FAIL  list comprehension
                                      FAIL  register/whereis

    8/15

The two that mattered failed for the same reason, and it was not the
one I expected:

    lda :inc — only reserved atoms have fixed indices;
               application atoms need the image atom table

**A program could not name its own atoms.** Eighteen reserved atoms
existed for signal reasons, and nothing else. `{From, inc}`,
`{ok, Value}`, `{error, Reason}`, a record tag — none of it was
encodable. Every OTP protocol is application atoms, so no OTP code
could run at all, and the failure looked like a compiler limitation
rather than what it was.

## The fix cost the hardware nothing

`lda` has always carried a 12-bit index and the ALU has always turned
it into an atom term:

```elixir
<<14::5>> -> y = 0x100000000 + imm
```

**4,096 atoms were available the whole time.** Only the toolchain
refused to number them. The change is entirely in Elixir:
`Encoding.program_atoms/1` collects every non-reserved atom a program
names, `image/2` numbers them after the ABI ones, and `Machine.new/2`
interns from the *same function* — which is the only way the two sides
can be guaranteed to agree about what `lda 19` means. A table computed
independently on each side is a table that drifts, and the symptom
would be a program printing the wrong atom name.

## After

    10/15 — gen_server loop and tuple exit reasons now pass

Still refused, in the order they are worth fixing:

| gap | why it matters |
|---|---|
| `try` / `catch` | not exotic Erlang; a supervisor that cannot catch is half a supervisor |
| `spawn_link/3` | the OTP idiom for starting a child; it is `spawn` + `link` and should be cheap |
| list comprehensions / `letrec` | idiomatic in almost any real module |
| `lists:` and other remote calls | the front end handles only its own module plus a handful of BIFs |
| `register` / `whereis` | needs a name table; less urgent than the rest |

## Two things proven on silicon along the way

**`tailcall` works.** `notes/27` listed it as wired-but-never-executed
and called it the sharpest entry on that list, because a `gen_server`
is a function that calls itself and Erlang runs that in constant stack.
`mk_tailloop.exs` runs a self-recursive loop **200 times** — the
register stack is 64 frames, so anything under 65 would have passed
whether the op reuses the window or pushes one — and the gates agree
with the model.

**A gen_server-shaped process runs.** `mk_srv.exs`: a server that
receives `{From, inc}`, replies `{reply, N+1}`, and tail-calls itself
with new state, driven by a client that does it twice and then sends
`stop`. Gates and model both give `[1, 2, done]`, word for word.

That program needs three things that were each broken within the last
day: `tailcall` reusing the window, `send` COPYING a compound term
rather than shipping a pointer, and a program being able to name its
own atoms.

## The second pass: 8 -> 14 of 15

Working the refusal list in the order it was worth fixing.

**`spawn_link/3`** is spawn then link — one bundle apart. BEAM makes the
pair ATOMIC, and here there is a gap of one bundle that is not
closeable without a fused opcode. The window is small and the failure
mode is benign (`link` to a dead pid dead-letters), so the parent ends
up unlinked rather than wedged. Written down rather than papered over.

**`try` / `catch`** needed a real mechanism, because the shape `erlc`
emits wraps a CALL:

    try apply 'f'/1 (_0) of <_1> -> _1 catch <_5,_4,_3> -> {_5,_4}

so a raise has to UNWIND frames, not just redirect a pc. The ISA gained
`try_begin rd, handler` and `try_end`. A catch frame records where the
handler is and how deep the stacks were when the protected expression
began — both, because a handler that ran with the callee's window would
read the wrong registers. Class and reason land in rd and rd+1, which
is why the front end allocates them adjacently.

It works in the model, across a call:

    try f(1) of X -> X catch _:E -> E end   %% f(A) -> 2147483647 + A
    => :overflow          (raised in f, caught in main)
    => 2147483647         (f(0), no raise)

`throw`, `error` and `exit` all lower to `fail`, so a handler sees class
`error` for all three. BEAM distinguishes them and `try` can match on
the class; that approximation is recorded, not hidden.

**List comprehensions** are a `letrec` holding a self-recursive fun.
The front end lifts every letrec fun to a top-level function, which is
EXACT for this shape — `erlc`'s `lc$^0/1` takes the list as its only
parameter and closes over nothing — and `tailcall` already makes its
recursion constant-stack. A fun that does close over an enclosing
variable is not lifted correctly and does not pretend to be: the free
variable is not in scope in the lifted function and the existing
"unbound variable" error fires, naming it.

Compiling a function can now DISCOVER functions, so `translate/2` is a
worklist rather than a map comprehension.

**`lists:`** is a prelude written in Erlang, because in a real BEAM
`lists.erl` IS Erlang — there is nothing primitive about `reverse/1`.
It is compiled alongside the user's module and only the functions
actually called are lifted, so images stay small: `otp.erl` pulls in
`reverse/1,2`, `sum/1,2`, `length/1`, `len/2` and `member/2` and
nothing else. Higher-order `map/2`, `filter/2`, `foldl/3` are absent
because the machine has no fun values.

**`register`/`whereis`** is the one left. It needs a VM-global name
table, which across engines is a new subsystem and a ring protocol —
and adding a fifteenth model-only feature would widen a gap that is
already the most important fact about the project (below).

## What of this runs on GATES, which is the question that matters

| | model | gates |
|---|---|---|
| application atoms | yes | **yes** — `tb_fixed:srv` |
| `tailcall` | yes | **yes** — 200 iterations, `tb_fixed:tailloop` |
| gen_server-shaped loop | yes | **yes** — `tb_fixed:srv` |
| list comprehensions | yes | **yes** — `tb_fixed:otp` |
| `lists:` prelude | yes | **yes** — pointers match the model exactly |
| `spawn_link/3` | yes | **no** — see below |
| `try` / `catch` | yes | **no** — `try_begin`/`try_end` have no RTL |

Five of seven. The two that do not are honest entries, not omissions.

### `spawn_link` on gates: a characterised open bug

A minimal case — spawn_link, display, halt — produces **459 outputs
alternating 2, 1, 2, 1** where the model produces one. Both processes
restart, repeatedly.

What is known: it is not the comprehension or the prelude, both of
which pass on gates on their own; `erlsup` does spawn → link → … → halt
and works, so the difference is either how soon `main` halts after
linking or that `erlsup` traps exits. The front end recycles the
spawn's destination register immediately afterwards, because the value
is dead — which is correct for the model and may not be for a machine
whose spawn write-back is late.

Enough to name it precisely and not enough to fix it here.

---

## Postscript — both rows are now green, and one of them was a lie

Written the day after. The table above has two `no`s in it; both are
`yes` now, and the first one was not the bug it says it was.

**`spawn_link/3` was innocent.** Deleting the `link` reproduced the
459 outputs exactly. The real fault was that a process whose entry
function RETURNED did not exit: `ret` at frame depth zero popped an
empty stack, read link zero, and continued at bundle 0 — the image's
entry point. The child re-ran `main`, spawned a grandchild, and so on.
Nothing above about register recycling or trapped exits was right; the
paragraph is left standing because a wrong diagnosis, clearly labelled,
is worth more than a quiet edit. `notes/31` has the trace.

**`try`/`catch` has RTL.** A per-process catch stack four deep, an
absolute pop so a fault several calls down unwinds in one step, and two
landings — one riding the ret fill's own write turn, one taking a
parked context's free X turn. `notes/32` has the design and the reason
the obvious version of it is wrong. `tb_fixed:try` checks four answers
against the model, including a `try` nested inside another one's
protected expression.

The corrected table:

| | model | gates |
|---|---|---|
| application atoms | yes | **yes** — `tb_fixed:srv` |
| `tailcall` | yes | **yes** — `tb_fixed:tailloop` |
| gen_server-shaped loop | yes | **yes** — `tb_fixed:srv` |
| list comprehensions | yes | **yes** — `tb_fixed:otp` |
| `lists:` prelude | yes | **yes** — pointers match exactly |
| `spawn_link/3` | yes | **yes** — `tb_fixed:slink` |
| `try` / `catch` | yes | **yes** — `tb_fixed:try` |

Seven of seven. The remaining divergence is not in this table at all:
`erlang:halt()` stops the VM in the model and exits one process on the
gates (`notes/26` bug 2). `tb_fixed:slink` is written so the parent
halts last, which is how you can tell it is still there.

## And it found a real concurrency bug

The gen_server test failed the first time, replying `1` twice instead
of `1` then `2`. The tail call was innocent — N advanced 0, 1, 2
correctly. The client's `recv_take` was not removing its message, so
its second `receive` re-matched the first reply.

`Mailbox` has one write site for the scan cursor, shared by four
writers, and it was addressed by `cmd_slot` for all of them. Start,
skip and take are COMMANDS and act on `cmd_slot` correctly. The scan's
park is not a command: it happens whenever the scan FSM finishes, which
is cycles after the `peek` that started it, with no relationship to
whatever is on the command port at that instant.

So one process's scan parked its cursor **in another process's slot**.
A take reclaims at the head only when the cursor is at the head, and
the cursor was a number some other process had written.

With one process receiving this never happens. With two — a server and
a client, which is to say all of OTP — it happens constantly. The
cursor write now addresses `sc_slot`.

A second, smaller thing fell out: a take reset the cursor to zero,
which is correct only while the head is zero. It resets to the new
head now, past the message just reclaimed, which is what BEAM does
after a successful receive.
