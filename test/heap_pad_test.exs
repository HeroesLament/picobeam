defmodule PicoBEAM.HeapPadTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Ex, Machine}

  # `notes/40`. The heap allocates whole cells, so an object of odd word
  # count leaves a pad word. A 2-tuple is three words in two cells — and
  # until this test there was no program in the suite that collected one.
  #
  # The GC tests that existed used cons cells, which are exactly one cell
  # with nothing left over, so the hole in to-space never got walked.

  @src """
  defmodule PadStress do
    def main do
      :erlang.display(spin(400, {0, 0}))
    end

    def spin(0, acc), do: :erlang.element(1, acc)

    def spin(n, acc), do: spin(n - 1, {n, :erlang.element(1, acc)})
  end
  """

  test "even-arity tuples survive collection on a heap that must collect" do
    prog = Ex.compile_string(@src)

    m =
      prog
      |> Machine.new(heap_words: 256)
      |> Machine.boot(:"main/0", [])

    {status, m} = Machine.run(m, 2_000_000)

    assert status == :quiescent
    # 400 tuples through a 128-cell semispace cannot happen without
    # collecting, and the answer has to survive every one of them
    assert length(m.stats.gc) > 0
    assert m.out == [1]
    assert Machine.deaths(m) |> Enum.reject(&match?({_, :normal}, &1)) == []
  end

  test "the pad word is a term the collector will not follow" do
    # nil, not zero: zero is a valid `int` and would be followed as one
    # if the tag rules ever changed underneath us
    assert PicoBEAM.Term.tag_name(PicoBEAM.Term.nil_word()) == :nil
  end
end
