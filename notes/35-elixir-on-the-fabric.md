# 35 — Elixir on the fabric

```elixir
def fib(n) when n < 2, do: n
def fib(n), do: fib(n - 1) + fib(n - 2)
```

That is in `priv/demo/pico_demo.ex`. It goes through `elixirc`, and it
runs on the ECP5.

## There is no second front end

The thing worth saying first, because it is the whole reason this was a
day's work rather than a month's: **Core Erlang is not an Erlang
thing.** It is the BEAM's common intermediate language, and Elixir
compiles to it exactly as Erlang does. `PicoBEAM.Erl` has compiled Core
Erlang since `notes/25`. Elixir needed a route to that door, not a
door of its own.

The route:

```
.ex source
  └─ Code.compile_file/1 with debug_info    →  .beam binary
       └─ :beam_lib.chunks(bin, [:debug_info])
            └─ :elixir_erl.debug_info(:erlang_v1, ...)  →  Erlang AF
                 └─ :compile.forms(forms, [:to_core])   →  Core Erlang
                      └─ PicoBEAM.Erl.translate_core/3
```

Every step is the real compiler. Nothing parses Elixir, re-implements
it, or approximates it. The module that runs on the fabric is the one
`elixirc` produced, taken back out of its own debug-info chunk and
lowered one stage further than it usually goes.

`:elixir_erl.debug_info/4` is the same entry point decompilers use to
recover Erlang from a `.beam`; it is how the Erlang Abstract Format
survives Elixir compilation at all. `debug_info: true` is not optional
— without it the `.beam` holds bytecode, and bytecode is a stage too
far to lower back from.

## Two lines of front end changed

**`erlang:send/2`.** Erlang's `Pid ! Msg` reaches Core Erlang as
`erlang:'!'/2`; Elixir's `send(pid, msg)` reaches it as
`erlang:send/2`. BEAM treats them as synonyms and so does this now:

```elixir
defp builtin(:send, [p, msg], st, mode, node), do: builtin(:!, [p, msg], st, mode, node)
```

**`__info__/1`.** Elixir generates it on every module. It answers with
keyword lists and maps, this machine has neither, and nothing here
calls it — so `PicoBEAM.Ex` skips it by name. Compiling it would fail
loudly for a function nobody wanted, which is the wrong kind of loud.

That is the entire delta. `translate/2` grew a `skip` argument and a
public `translate_core/3`, and everything else was already there.

## What of Elixir actually works

What the MACHINE has, which is less than what Elixir has. Integers,
atoms, tuples, cons cells, pids and refs; calls, guards, pattern
matching, `case`, `receive`, `send`, `spawn`, `try`.

Maps, binaries, floats, strings, protocols, structs and anonymous
functions do not — the machine has none of them. That is
`notes/26`-shaped debt and not a translation problem: the day the heap
grows a map, Elixir maps will work without this module changing.

Two consequences worth knowing before writing a demo:

* **`for` comprehensions do not compile.** Elixir's `for` goes through
  `Enumerable`, which means protocols and anonymous functions. Erlang's
  list comprehensions do compile (`notes/30`), because `erlc` lowers
  them to a `letrec` this front end lifts. Recursion is the Elixir
  equivalent that works.
* **`try/rescue` does not; `try/catch` does.** `rescue` matches on
  exception structs. `catch kind, reason` is Erlang's `Class:Reason`
  and lands on `notes/32`'s machinery.

## The demo, and what each line proves

```elixir
def main do
  me = :erlang.self()
  :erlang.spawn(PicoDemo, :worker, [me, 10])
  n = receive do x -> x end
  :erlang.display(n)                              # 55
  :erlang.display(:lists.sum(build(5, [])))       # 55
  :erlang.display(:lists.reverse(build(3, [])))   # [9, 4, 1]
  :erlang.display(guarded(1))                     # :overflow
end
```

* **55 from the mailbox** — `spawn`, `send` and `receive` between two
  real processes, the answer computed somewhere else.
* **55 from `:lists.sum/1`** — the Erlang prelude (`notes/30`), lifted
  lazily, called from Elixir. `lists.erl` is Erlang in a real BEAM too.
* **`[9, 4, 1]`** — cons cells built on the heap by `build/2` and
  reversed. A compound term, which is the part of this machine that was
  least finished a fortnight ago.
* **`:overflow`** — a fixnum that does not fit, caught by `try` rather
  than killing the process. `notes/32`'s deep landing, from Elixir.

`main/0` deliberately does **not** call `:erlang.halt/0`. Halt stops the
whole VM (`notes/33`) and the VM is both engines; a root that halted
would take the other engine down mid-sentence. Returning is what "this
process is finished" means here.

## On gates, not just in the model

`tb_fixed:elixir` runs the netlist against the model's own output,
word for word — the same harness every Erlang program in this project
is checked with, pointed at an Elixir one. 143 bundles, one pool word,
four values.

There is a temptation, at this point, to say the machine "runs Elixir".
It runs *this* Elixir: a module written to what the hardware has. The
honest claim is narrower and still the one worth making — **the Elixir
compiler's own output, unmodified, executes on picoBEAM.** Everything
between `defmodule` and the gates is stock.
