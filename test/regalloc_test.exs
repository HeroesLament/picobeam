defmodule PicoBEAM.RegallocTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Ex, Machine}

  # `notes/26` entry 22 / `notes/50`. The front end used to allocate a
  # fresh register per binding and never free one: a straight-line chain
  # of ~8 bindings exhausted the sixteen-register window, and `notes/45`
  # records `new_reg` raising four times while writing `board_demo`
  # alone. Liveness-based recycling makes register pressure a function
  # of how many values are LIVE, not how many were ever named.

  defp run_main(src) do
    prog = Ex.compile_string(src)
    {status, m} = prog |> Machine.new() |> Machine.boot(:"main/0", []) |> Machine.run(500_000)
    assert status in [:halted, :idle]
    m.out
  end

  test "a 40-step straight-line chain compiles and runs (old limit: ~8)" do
    steps = Enum.map_join(1..40, "\n", fn i -> "    a#{i} = a#{i - 1} + #{i}" end)

    out =
      run_main("""
      defmodule ChainDemo do
        def main do
          a0 = 0
      #{steps}
          :erlang.display(a40)
          :erlang.halt()
        end
      end
      """)

    assert out == [Enum.sum(1..40)]
  end

  test "interleaved live values across a chain keep their registers" do
    # x and y stay live across twenty intermediate bindings each — the
    # recycler must not hand their registers to the chain temporaries
    steps = Enum.map_join(1..20, "\n", fn i -> "    b#{i} = b#{i - 1} + x + y" end)

    out =
      run_main("""
      defmodule LiveDemo do
        def main do
          x = 7
          y = 11
          b0 = 0
      #{steps}
          :erlang.display(b20)
          :erlang.display(x)
          :erlang.display(y)
          :erlang.halt()
        end
      end
      """)

    assert out == [20 * 18, 7, 11]
  end

  test "a chain through tuples, maps and calls recycles too" do
    out =
      run_main("""
      defmodule MixDemo do
        def main do
          a = {1, 2}
          b = elem(a, 0) + elem(a, 1)
          c = %{k: b}
          d = :maps.get(:k, c) + 1
          e = [d | [b]]
          f = hd(e) + hd(tl(e))
          g = f + step(f)
          h = g + step(g)
          i = h + step(h)
          j = i + step(i)
          k = j + step(j)
          l = k + step(k)
          m = l + step(l)
          n = m + step(m)
          o = n + step(n)
          p = o + step(o)
          :erlang.display(p)
          :erlang.halt()
        end

        def step(v), do: v + 1
      end
      """)

    # value checked against plain Elixir below
    a = {1, 2}
    b = elem(a, 0) + elem(a, 1)
    c = %{k: b}
    d = Map.get(c, :k) + 1
    e = [d | [b]]
    f = hd(e) + hd(tl(e))
    expect =
      Enum.reduce(1..10, f, fn _, acc -> acc + (acc + 1) end)

    assert out == [expect]
  end

  test "genuinely exceeding 16 LIVE values still raises, honestly" do
    # every a_i is used at the END, so all 17 are simultaneously live —
    # no allocator with 16 registers can compile this window
    # opaque calls, or erlc constant-folds the whole thing away
    binds = Enum.map_join(1..17, "\n", fn i -> "    a#{i} = step(#{i})" end)
    sum = Enum.map_join(1..17, " + ", fn i -> "a#{i}" end)

    assert_raise PicoBEAM.Erl.CompileError, ~r/LIVE values/, fn ->
      Ex.compile_string("""
      defmodule TooLive do
        def main do
      #{binds}
          :erlang.display(#{sum})
          :erlang.halt()
        end

        def step(v), do: v + 1
      end
      """)
    end
  end
end
