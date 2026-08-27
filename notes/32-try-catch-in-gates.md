# 32 — try / catch in gates

`notes/30` measured which Erlang the front end accepts and was honest
about the one row it could not colour in:

> | `try` / `catch` | yes | **no** — `try_begin`/`try_end` have no RTL |

This note fills it in. The machine now catches, and it catches the way
BEAM does — including a fault raised several calls below the `try`, and
a `try` opened inside another one's protected expression.

## The design I built first was wrong

The obvious shape, and the one I started with, is to make `try_begin` a
**call that does not move the pc**: spill the window into a frame, mark
that frame as catchable, and let a fault unwind frames one at a time
until it pops a marked one. It reuses the whole ret path — the pop, the
fill, the landing pc from the frame's link — and it needs one extra bit
in the link store and no new memory at all. `try_end` becomes a pop
with no fill.

It is wrong twice, and the second reason is the interesting one.

The shallow reason: `try_begin` would spill the window while the
protected expression keeps writing to it. The drain streams sixteen
words over sixteen owner turns; the program is running the whole time.
The "snapshot" would be a smear.

The deeper reason: **there is no snapshot to take.** Look at what the
model actually does when a raise finds a catch frame:

```elixir
windows = Enum.drop(p.windows, length(p.windows) - frame.ws)
window  = windows |> hd() |> Map.put(frame.rd, class_word)
                          |> Map.put(frame.rd + 1, reason_word)
```

It drops the *deeper* windows and lands in the try-owner's window **as
it stands**. Registers the protected expression wrote before it called
out are still there — that is ordinary Erlang, where bindings made
before a `try` are visible in its handler. `try` unwinds a stack; it
does not roll back registers. A hardware `try` that restored a snapshot
would be *more* than BEAM does, and wrong.

Which is a relief, because it means `try_begin` has nothing to save.

## What it is instead

Per process, four deep, in one distributed memory:

```elixir
#   {depth:4, pc:9, rd:4}   at {slot:5, idx:2}
memory :ctch, width: 17, depth: 128
wire :ccnt, 96, init: 0        # 32 x 3-bit nesting counters
```

`try_begin` writes the frame depth it is standing at, the handler
label, and its `rd`, and bumps the counter. `try_end` decrements it.
Neither touches a frame, a window, or the pc beyond the next bundle —
they are one-cycle ops, and the sequencer does not need to know they
exist.

A fault asks one question: `cc_n != 0`. If the answer is no, the
process dies exactly as it always has, on exactly the path it always
took. That was a deliberate constraint — the unwind is reached only by
programs that asked for it, so every existing test's crash behaviour is
untouched by construction rather than by hoping.

If the answer is yes, there are two landings.

**Deep** — the fault is below the frame the `try` was in, which is the
shape `erlc` emits, because the protected expression is usually a call.
The frame store learned an absolute pop:

```elixir
d_new =
  push_ok * (op_depth + 1) + band(pop_ok, bnot(pop_abs)) * (op_depth - 1) +
    band(pop_ok, pop_abs) * pop_to
```

One pop lands on the try's depth however many frames are in between,
and the fill that follows reads the window the try-owner spilled when
it made the call — which is exactly `hd(windows)` in the model, for
exactly the same reason. The landing then rides the ret's own dest
turn: same port, same cycle, a different address and a different word.

**Shallow** — the fault is in the try's own frame, so there is nothing
to unwind and no fill to ride. `BarrelSeq` gets one state (20) whose
only job is to take the context's next X turn, which is free because no
bundle is in flight for it, and let the engine write one register.

## One register, not two

The handler wants `rd` = class and `rd + 1` = reason. Two writes to one
port is two turns, or a second port.

Neither, as it turns out: the class is *always* `error`. Every raise
this machine can produce is an error class — `throw` and `exit` carry
their own and the front end does not emit them yet — so `try_begin`
pre-loads `rd` with reserved atom 17 as it retires, on the system-op
write path `self` and `monitor` already use. `Erl` allocates `rd` and
`rd + 1` for the `try` alone, so nothing can observe it early, and the
landing has one register left to write.

When `throw` and `exit` arrive they will want a real class, and the
place to put it is the `ctch` entry — there are fifteen unused bits in
it.

## The bug this uncovered

State 20 did not exist. Neither, it turns out, did state 16.

```elixir
wire :cstate0, 4, init: 0
```

Four bits. The moduledoc says so, and explains at length that it was
three until `spawn_park` arrived as state 9 and truncated to 1, and the
context re-fetched its spawn bundle forever. The note ends "same
species as the M2 `pidx` collapse and the emitter width bugs in
`notes/15`".

It happened again. `send_claim` assigns `cstate = 16`, and has since
`notes/22`. In four bits that is **zero — idle**. Every context
streaming a message out of the serialiser has been sitting in a state
the rest of the machine reads as an empty seat. It has not bitten
because nothing consults the status field for a decision a sending
context can lose: the kill and wake paths test for 1 and 12, and the
seat allocator keeps its own occupancy. But it was one read away from
being a real one, and the third instance of the same failure mode in
this project.

Five bits now. `DbgUart` takes five and prints the low nibble, because
a twenty-state field in one hex character was always a lossy *display*
and widening the format is a different decision from widening the
signal.

## What is checked

`tb_fixed:try` runs one program with four answers, all compared
word-for-word against the model:

| call | what it exercises | answer |
|---|---|---|
| `deep(1)` | fault one frame down — the `erlc` shape | `:overflow` |
| `deep(0)` | happy path; `try_end` must leave the result alone | `2147483647` |
| `shallow()` | raise in the try's own frame, no unwind | `:badarg` |
| `nest()` | inner `try` catches, outer must still be there | `:badarith` |

`nest/0` is the one that earns its place. It opens a `try`, calls a
function that opens a *second* one and catches with it, returns, and
then faults again so the first one has to fire. A machine that kept its
catch state in a single register instead of a per-process stack passes
every other row in that table.

Reasons are asserted, not just the fact of catching. `:overflow` is 5,
`:badarg` is 10 and `:badarith` is 3, and a handler that caught the
wrong one would still look like it worked.

## Limits, stated

* **Four nested `try`s per process.** A fifth raises `:system_limit`
  (reserved atom 9) rather than overwriting the stack silently — the
  same answer the proc table gives a spawn it cannot seat.
* **No stacktrace.** `Erl` binds it to `nil`, which is honest; the
  machine does not keep one.
* **Class is always `error`.** See above.
* **A `try` costs a frame in the model and none in the gates**, which
  is the opposite of the usual direction and worth remembering when
  `@max_rstack` next comes up.
* **`try_end` must run before the enclosing function returns.** Well
  formed code from `erlc` always does; the model has the same hazard
  with a stale `catches` list, so at least they are wrong together.

## Where that leaves the conformance table

`notes/30` measured 14 of 15 OTP shapes in the model and was clear that
the model was not the point. On the netlist, with `notes/31` and this
note, the shipped features and the hardware now agree everywhere except
one: `erlang:halt()` stops the VM in BEAM and in the model, and exits
one process on the gates. That is `notes/26` bug 2, and it is the last
one.
