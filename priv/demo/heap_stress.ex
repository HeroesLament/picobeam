# The program the collector has to fix (`notes/40`).
#
# A loop that builds a fresh 2-tuple every iteration and keeps only the
# newest — so live data stays at one cell and garbage accumulates at one
# cell per turn. On a 128-cell semispace with no collector it gets a few
# dozen iterations and dies of `heap_full`; with one it should run as
# long as it likes.
#
# Four hundred iterations is several collections deep, and that is the
# point. Surviving ONE collection proves the evacuation. Surviving more
# than the heap has cells proves the ROOTS were rewritten, because the
# second collection has to walk what the first one moved.
#
# `churn/2` is a non-tail call that allocates, so the caller's window —
# holding the only live pointer — is a SPILLED FRAME while it runs. A
# collection triggered inside it has to walk the frame store to find
# `acc`, which is the root class a tail-recursive loop would never
# exercise.

defmodule HeapStress do
  def main do
    :erlang.display(spin(400, 0, {0, 0}))
  end

  def spin(0, _k, acc), do: :erlang.element(1, acc)

  def spin(n, 0, acc) do
    show(n, acc)
    spin(n - 1, 100, {n, :erlang.element(1, acc)})
  end

  def spin(n, k, acc) do
    churn(n, acc)
    spin(n - 1, k - 1, {n, :erlang.element(1, acc)})
  end

  # allocates, one frame down, with the caller's live pointer spilled
  defp churn(n, acc), do: :erlang.element(2, {n, acc})

  defp show(n, acc) do
    :erlang.display(n)
    :erlang.display(:erlang.element(1, acc))
  end
end
