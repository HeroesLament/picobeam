# An Elixir module that runs on the fabric.
#
# Compiled by the real Elixir compiler, lowered through
# `:elixir_erl.debug_info/4` and `:compile.forms(:to_core)`, and handed
# to the same Core Erlang front end that has compiled `.erl` since
# `notes/25`. Nothing here re-implements Elixir; this file goes through
# `elixirc` and comes out the other side as picoBEAM bundles.
#
# It is written to the MACHINE's Elixir, which is smaller than Elixir:
# integers, atoms, tuples, lists, pids; calls, guards, patterns, `case`,
# `receive`, `send`, `spawn`, `try`. No maps, binaries, floats, strings,
# protocols, structs or anonymous functions — the machine has none of
# them, which is `notes/26`-shaped debt and not a translation problem.
#
# `main/0` does NOT halt. `erlang:halt/0` stops the whole VM
# (`notes/33`), and the VM is both engines — a root that halted would
# take the other engine down with it mid-sentence. Returning is what
# "this process is finished" means here, and when both engines run out
# of work the machine goes idle and the UART line freezes on the answer.
#
#   mix run scripts/mk_elixir.exs

defmodule PicoDemo do
  def main do
    me = :erlang.self()
    :erlang.spawn(PicoDemo, :worker, [me, 10])

    n =
      receive do
        x -> x
      end

    # 55, computed in another process and sent back over the mailbox
    :erlang.display(n)

    # 55 again, this time through the Erlang prelude's lists:sum/1
    :erlang.display(:lists.sum(build(5, [])))

    # [9, 4, 1] — cons cells on the heap, reversed
    :erlang.display(:lists.reverse(build(3, [])))

    # :overflow — a fixnum that does not fit, caught rather than fatal
    :erlang.display(guarded(1))
  end

  # Engine 1's entry point. The image carries both (`notes/36`), so
  # where each engine starts is a property of the program rather than of
  # the bitstream — which is what makes a second engine worth having on
  # a board that can only be reflashed in twenty minutes.
  #
  # It does its own spawn/send/receive rather than talking to engine 0:
  # cross-engine SPAWN and cross-engine SIGNALS are not built
  # (`notes/29`), and a demo that pretended otherwise would be a demo of
  # a hard-coded pid literal.
  def node1 do
    me = :erlang.self()
    :erlang.spawn(PicoDemo, :worker, [me, 12])

    n =
      receive do
        x -> x
      end

    # 7 first, then 145 — fib(12) plus one. The ORDER is load-bearing:
    # the board's UART shows only the LAST `out` byte, so the last value
    # a program produces is the one field on that line that a change to
    # the program has to move. Swapping these two and watching `OO` go
    # 07 → 91 is how the board was confirmed to be running THIS image
    # and not agreeing by coincidence (`notes/36`).
    :erlang.display(:lists.length(build(7, [])))
    :erlang.display(n + 1)
  end

  def worker(parent, n), do: send(parent, fib(n))

  def fib(n) when n < 2, do: n
  def fib(n), do: fib(n - 1) + fib(n - 2)

  def build(0, acc), do: acc
  def build(n, acc), do: build(n - 1, [n * n | acc])

  def guarded(a) do
    try do
      2_147_483_647 + a
    catch
      _kind, reason -> reason
    end
  end
end
