# Closures, in Elixir, on the machine (`notes/42`).
#
# `fn x -> x + n end` is a `c_fun` in Core Erlang with `n` free. The
# front end lifts it to a top-level function of arity two — the visible
# parameter, then the closure — computes what it captured, and leaves a
# heap object behind in its place. The lifted function unpacks `n` out
# of that object with `fget` before its body runs, so nothing after the
# prologue knows it is a closure.
#
# `twice/2` is the part that matters: the fun escapes into another
# function as a VALUE and is called there. That is what separates a
# closure from an inlined lambda, and it is why the demo passes one
# around rather than only calling it where it was made.
#
# The counter loop between the calls is not decoration. It allocates
# hard enough to collect, so the second half of the demo runs against a
# heap where everything — the closure included — has moved.

defmodule FunDemo do
  def main do
    # `base/0` is a function call, so `n` is not a constant erlc can fold
    # into the fun body — the closure has to actually carry it. A literal
    # `n = 100` does not test anything: the optimiser inlines it and what
    # is left is a closure over nothing.
    n = base()
    add = fn x -> x + n end

    :erlang.display(add.(5))
    :erlang.display(twice(add, 7))

    :erlang.display(churn(150, 0))

    # ...and again, on the other side of a collection
    :erlang.display(add.(1))
    :erlang.display(twice(add, 0))

    pair(3, 4)
  end

  # a closure over TWO variables, made after the heap has moved
  def pair(a, b) do
    both = fn x -> x * a + b end
    :erlang.display(both.(10))
    :erlang.display(twice(both, 1))
  end

  def twice(f, x), do: f.(f.(x))

  def base, do: 100

  # allocates a tuple per turn and keeps only the newest, so the heap
  # turns over several times. Taking an element of the fresh tuple is
  # what stops the optimiser folding the whole loop away — which it
  # does, silently, if the allocation's result is discarded.
  def churn(0, acc), do: acc
  def churn(n, acc), do: churn(n - 1, :erlang.element(1, {n, acc}))
end
