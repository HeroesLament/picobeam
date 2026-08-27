# Maps, in Elixir, on the machine (`notes/42`).
#
# A flatmap is a tuple-shaped object with a tag of its own: header, pair
# count, then one key/value pair per CELL. `mkmap` allocates it, `tset`
# fills a LITERAL at indices the compiler knows, and `mapat` reads it at
# an index a probe loop computes. Everything above that — get, put,
# update, keys — is Erlang in the prelude, the way the list functions
# are.
#
# The keys come from `k/1` rather than from literals for the same reason
# `fun_demo` gets its captured value from a call: erlc folds a map
# literal and every `maps:` call on it into a constant, and a demo built
# that way runs none of the code it is supposed to be testing.
#
# `bump/2` is the part that matters most. A map update is a FRESH map —
# BEAM's flatmap semantics, and the reason the collector had to come
# first — so a loop that updates one is a loop that allocates one map
# per turn, and this one runs long enough to collect several times.

defmodule MapDemo do
  def main do
    m = :maps.put(k(9), 90, :maps.put(k(7), 70, :maps.new()))

    :erlang.display(:maps.size(m))
    :erlang.display(:maps.get(7, m))
    :erlang.display(:maps.is_key(8, m))

    update(m)
  end

  # a functional update leaves the original alone
  def update(m) do
    m2 = %{m | 7 => 71}
    :erlang.display(:maps.get(7, m2))
    :erlang.display(:maps.get(7, m))
    grow(m2)
  end

  # ...and put GROWS it
  def grow(m2) do
    m3 = :maps.put(8, 80, m2)
    :erlang.display(:maps.size(m3))
    :erlang.display(:maps.get(8, m3))
    # a map pattern is a probe, and it fails the clause when the key is
    # not there rather than raising
    :erlang.display(pick(m3))
    churn(m3)
  end

  # one fresh map per turn, for long enough to move the heap under it
  def churn(m3) do
    :erlang.display(:maps.get(7, bump(m3, 120)))
    :erlang.display(:erlang.is_map(m3))
  end

  def bump(m, 0), do: m
  def bump(m, n), do: bump(%{m | 7 => n}, n - 1)

  def pick(%{9 => v}), do: v

  # opaque to the optimiser: it cannot fold a map whose keys it does not
  # know until the program runs
  def k(x), do: x
end
