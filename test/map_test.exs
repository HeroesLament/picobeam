defmodule PicoBEAM.MapTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Machine, Term}

  # `notes/42`. A flatmap is a tuple-shaped object with a tag of its own:
  # header, pair count, then one key/value pair per CELL.
  defp run(prog, opts \\ []) do
    prog
    |> Machine.new(Keyword.merge([heap_words: 256], opts))
    |> Machine.boot(:main, [])
    |> Machine.run(100_000)
  end

  test "a literal map is built at literal indices and read at computed ones" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 2}],
             [{:mkmap, 1, 0}],
             [{:ldi, 2, 7}],
             [{:ldi, 3, 70}],
             [{:tset, 1, 1, 2}],
             [{:tset, 1, 2, 3}],
             [{:ldi, 4, 9}],
             [{:ldi, 5, 90}],
             [{:tset, 1, 3, 4}],
             [{:tset, 1, 4, 5}],
             # count, then both pairs
             [{:ldi, 6, 0}],
             [{:mapat, 7, 1, 6}],
             [{:out, 7}],
             [{:ldi, 8, 1}],
             [{:mapat, 9, 1, 8}],
             [{:out, 9}],
             [{:ldi, 10, 2}],
             [{:mapat, 11, 1, 10}],
             [{:out, 11}],
             [{:halt}]
           ]}
      })

    {status, m} = run(prog)
    assert status == :halted
    assert m.out == [2, 7, 70]
  end

  test "mseti/mset writes at an index the program computed" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 1}],
             [{:mkmap, 1, 0}],
             [{:ldi, 2, 1}],
             [{:mseti, 2}],
             [{:ldi, 3, 5}],
             [{:mset, 1, 3}],
             [{:ldi, 4, 2}],
             [{:mseti, 4}],
             [{:ldi, 5, 55}],
             [{:mset, 1, 5}],
             [{:mapat, 6, 1, 2}],
             [{:out, 6}],
             [{:mapat, 7, 1, 4}],
             [{:out, 7}],
             [{:halt}]
           ]}
      })

    {status, m} = run(prog)
    assert status == :halted
    assert m.out == [5, 55]
  end

  test "a map is a map, and element/2 on one raises" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 1}],
             [{:mkmap, 1, 0}],
             [{:istag, 2, 1, :map}],
             [{:out, 2}],
             [{:istag, 3, 1, :tuple}],
             [{:out, 3}],
             [{:tget, 4, 1, 0}],
             [{:out, 4}],
             [{:halt}]
           ]}
      })

    {_status, m} = run(prog)
    assert Enum.take(m.out_raw, 2) == [Term.atom(14), Term.atom(15)]
    assert [{_pid, :bad_tag}] = m.stats.deaths
  end

  test "reading a non-map through mapat is badmap, not badarg" do
    prog =
      Asm.assemble(%{
        main: {0, [[{:ldi, 0, 3}], [{:ldi, 1, 0}], [{:mapat, 2, 0, 1}], [{:halt}]]}
      })

    {_status, m} = run(prog)
    assert [{_pid, :badmap}] = m.stats.deaths
  end

  test "a map survives collections with its pairs intact" do
    # one live map, a tuple of garbage per turn, a heap far too small
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 1}],
             [{:mkmap, 1, 0}],
             [{:ldi, 2, 1}],
             [{:ldi, 3, 41}],
             [{:tset, 1, 1, 2}],
             [{:tset, 1, 2, 3}],
             [{:ldi, 4, 60}],
             [{:ldi, 5, 1}],
             [{:ldi, 6, 0}],
             :loop,
             [{:mktup, 7, 2}],
             [{:tset, 7, 0, 4}],
             [{:tset, 7, 1, 4}],
             [{:sub, 4, 4, 5}],
             [{:cmpeq, 8, 4, 6}],
             [{:biff, 8, :loop}],
             [{:ldi, 9, 2}],
             [{:mapat, 10, 1, 9}],
             [{:out, 10}],
             [{:halt}]
           ]}
      })

    {status, m} = run(prog, heap_words: 64)
    assert status == :halted
    assert m.out == [41]
    assert length(Map.get(m.stats, :gc, [])) > 1
  end
end
