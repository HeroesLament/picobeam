defmodule GcConc do
  @moduledoc """
  Four processes allocating at once (`notes/46`).

  `heap_stress.ex` is one process and measures the collector against
  itself; this is the program that measures the thing the per-process
  collector was built for. Four workers churn a 2-tuple each, on one
  128-cell semispace, so a collection happens with three other processes
  runnable — which under a stop-the-world collector is three processes
  waiting and under this one is not.

  Every worker returns its own answer so the `out` stream is an
  assertion and not just a heartbeat.
  """

  def main do
    :erlang.spawn(GcConc, :worker, [k(60), 1])
    :erlang.spawn(GcConc, :worker, [k(60), 2])
    :erlang.spawn(GcConc, :worker, [k(60), 3])
    worker(k(60), 4)
  end

  def worker(n, tag), do: :erlang.display(spin(n, {tag, tag}))

  def spin(0, acc), do: :erlang.element(1, acc)

  def spin(n, acc), do: spin(n - 1, {:erlang.element(1, acc), n})

  def k(x), do: x
end
