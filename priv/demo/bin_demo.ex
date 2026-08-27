# Binaries and strings, in Elixir, on the machine (`notes/43`).
#
# A binary is a tuple-shaped object with a tag of its own: header, byte
# count, then the bytes. v1 stores ONE BYTE PER WORD — four times the
# memory a packed layout wants — and that is a decision the ISA hides:
# `binat` and `mset` are BYTE indexed, so packing four to a word later
# changes the heap's address arithmetic and not one line above it.
#
# There is no constant area on this machine. Every literal term is
# CONSTRUCTED, so a string costs bundles proportional to its length and
# a string in a PATTERN costs them again on every match. That is the
# honest price of `notes/11`'s image format, written down rather than
# hidden.
#
# `k/1` is the optimiser fence: erlc folds `byte_size("hi")` to 2 and
# `"ab" <> "cd"` to `"abcd"` given half a chance, and a demo built out of
# constants runs none of the code it exists to test.

defmodule BinDemo do
  def main do
    build()
    walk()
    match()
    churn()
  end

  def build do
    c = k("ab") <> k("cd")
    :erlang.display(:erlang.byte_size(c))
    :erlang.display(:erlang.binary_to_list(c))
    :erlang.display(:erlang.is_binary(c))
  end

  def walk do
    s = k("abc")
    :erlang.display(:binary.at(s, 0))
    :erlang.display(:binary.at(s, 2))
    # round trip through a list, which allocates a fresh binary
    :erlang.display(:erlang.binary_to_list(:erlang.list_to_binary([104, 105])))
  end

  def match do
    # a string literal in a pattern: erlc packs "hi" into one 16-bit
    # segment, so the matcher has to unpack it into bytes itself
    :erlang.display(greet(k("hi")))
    :erlang.display(greet(k("no")))
    split()
  end

  def split do
    # a byte and a rest. The rest is a COPY — this machine has no
    # sub-binaries — so binding it allocates.
    :erlang.display(head(k("abc")))
    :erlang.display(count(k("hello"), 0))
  end

  # one fresh binary per turn, for long enough to move the heap under
  # everything. A concatenation is a COPY, so this allocates twice a
  # turn and the string it keeps is the only thing live.
  def churn do
    :erlang.display(:erlang.byte_size(grow(k("x"), 60)))
  end

  def grow(s, 0), do: s
  def grow(s, n), do: grow(shrink(s <> k("yz")), n - 1)

  # keep it short: a binary that grew for forty turns would not fit
  def shrink(<<a, b, _rest::binary>>), do: :erlang.list_to_binary([a, b])
  def shrink(s), do: s

  def greet("hi"), do: 1
  def greet(_), do: 0

  def head(<<c, rest::binary>>), do: {c, :erlang.byte_size(rest)}

  # walking a string one byte at a time, which is what every string
  # function on this machine eventually is
  def count(<<>>, n), do: n
  def count(<<_c, rest::binary>>, n), do: count(rest, n + 1)

  def k(x), do: x
end
