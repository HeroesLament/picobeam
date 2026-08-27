defmodule BoardDemo do
  @moduledoc """
  The board program: funs, maps, binaries and the collector in one
  Elixir module whose whole answer is a single byte.

  The debug UART (`DbgUart`) is a status view, not a transcript — its
  `OO` field carries the low byte of the LAST `out`. So this program
  folds everything it computed into one number and displays that last,
  after displaying the four parts. On the netlist `tb_fixed` checks the
  whole `out` stream word for word; on silicon the line says `OO = the
  checksum`, `NN = 00` (no abnormal deaths) and the idle flag set, and
  those three together are the claim.

  `k/1` is an optimiser fence. erlc constant-folds anything it can see
  through, and a demo that folds to a literal proves the compiler works,
  not the machine (`notes/42`).
  """

  def main do
    a = funs()
    :erlang.display(a)
    b = maps()
    :erlang.display(b)
    c = bins()
    :erlang.display(c)
    d = churn(k(40), 0)
    :erlang.display(d)
    :erlang.display(:erlang.band(a + b + c + d, 255))
  end

  # ---- closures: one over a free variable, one over nothing, both
  # passed as values and called through a variable
  def funs do
    n = k(7)
    f = fn x -> x + n end
    g = fn x -> x * 2 end
    apply2(f, g, k(5))
  end

  def apply2(f, g, x), do: f.(x) + g.(x)

  # ---- maps: a literal, a functional update, and three lookups
  def maps do
    m = %{:a => k(3), :b => k(4)}
    msum(:maps.put(:c, k(5), m))
  end

  def msum(m), do: :maps.get(:a, m) + msum2(m)
  def msum2(m), do: :maps.get(:b, m) + :maps.get(:c, m)

  # ---- binaries: concatenation, byte_size, indexed read
  def bins do
    s = k("pi") <> k("co")
    :erlang.byte_size(s) + :binary.at(s, k(0))
  end

  # ---- allocate hard, in a tail loop, so the collector runs and
  # everything above has to survive being moved
  def churn(0, acc), do: acc

  def churn(n, acc), do: churn(n - 1, acc + turn(n))

  def turn(n) do
    m = %{:i => n}
    :maps.get(:i, m) + turn2(n)
  end

  def turn2(n) do
    b = k("ab") <> k("cd")
    :erlang.byte_size(b) + hd([n, n])
  end

  def k(x), do: x
end
