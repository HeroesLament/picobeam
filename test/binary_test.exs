defmodule PicoBEAM.BinaryTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Ex, Machine, Term}

  # `notes/43`. A binary is a tuple-shaped object with a tag of its own:
  # header, byte count, then the bytes — one per word in v1, which is a
  # layout the ISA hides.
  defp run(prog, opts \\ []) do
    prog
    |> Machine.new(Keyword.merge([heap_words: 256], opts))
    |> Machine.boot(:main, [])
    |> Machine.run(100_000)
  end

  test "a binary is built, read by byte, and knows its own size" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 2}],
             [{:mkbin, 1, 0}],
             [{:ldi, 2, 104}],
             [{:ldi, 3, 105}],
             [{:tset, 1, 1, 2}],
             [{:tset, 1, 2, 3}],
             [{:ldi, 4, 0}],
             [{:binat, 5, 1, 4}],
             [{:out, 5}],
             [{:ldi, 6, 1}],
             [{:binat, 7, 1, 6}],
             [{:out, 7}],
             [{:ldi, 8, 2}],
             [{:binat, 9, 1, 8}],
             [{:out, 9}],
             [{:halt}]
           ]}
      })

    {status, m} = run(prog)
    assert status == :halted
    assert m.out == [2, 104, 105]
  end

  test "a binary is a binary, and element/2 on one raises" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 1}],
             [{:mkbin, 1, 0}],
             [{:istag, 2, 1, :bin}],
             [{:out, 2}],
             [{:istag, 3, 1, :tuple}],
             [{:out, 3}],
             [{:tget, 4, 1, 0}],
             [{:halt}]
           ]}
      })

    {_status, m} = run(prog)
    assert Enum.take(m.out_raw, 2) == [Term.atom(14), Term.atom(15)]
    assert [{_pid, :bad_tag}] = m.stats.deaths
  end

  test "a binary survives collections with its bytes intact" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 0, 1}],
             [{:mkbin, 1, 0}],
             [{:ldi, 2, 42}],
             [{:tset, 1, 1, 2}],
             [{:ldi, 3, 60}],
             [{:ldi, 4, 1}],
             [{:ldi, 5, 0}],
             :loop,
             [{:mktup, 6, 2}],
             [{:tset, 6, 0, 3}],
             [{:tset, 6, 1, 3}],
             [{:sub, 3, 3, 4}],
             [{:cmpeq, 7, 3, 5}],
             [{:biff, 7, :loop}],
             [{:binat, 8, 1, 4}],
             [{:out, 8}],
             [{:halt}]
           ]}
      })

    {status, m} = run(prog, heap_words: 64)
    assert status == :halted
    assert m.out == [42]
    assert length(Map.get(m.stats, :gc, [])) > 1
  end

  test "Elixir strings: concatenation, byte access, and a literal pattern" do
    File.mkdir_p!("/tmp/pb_bin_test")
    src = "/tmp/pb_bin_test/strs.ex"

    File.write!(src, """
    defmodule Strs do
      def main do
        c = k("ab") <> k("cd")
        :erlang.display(:erlang.byte_size(c))
        :erlang.display(:binary.at(c, 3))
        pats()
      end

      def pats do
        :erlang.display(greet(k("hi")))
        :erlang.display(greet(k("no")))
        :erlang.display(head(k("abc")))
      end

      def greet("hi"), do: 1
      def greet(_), do: 0
      def head(<<c, rest::binary>>), do: {c, :erlang.byte_size(rest)}
      def k(x), do: x
    end
    """)

    prog = Ex.compile_file(src)

    {status, m} =
      prog
      |> Machine.new(heap_words: 512)
      |> Machine.boot(:"main/0", [])
      |> Machine.run(500_000)

    assert status == :quiescent
    assert m.out == [4, 100, 1, 0, {97, 2}]
  end
end
