# The heap, through the whole engine: build a list with `cons`, walk it
# back with `hd`/`tl`, build a tuple with `mktup`/`tset`, read it with
# `tget`/`tarity` — every heap op, every one of them landing its result
# through the wb2 turn.
#
#   mix run scripts/mk_heapprog.exs   -> _emit/m3/heapprog{,_expect}.hex
#
# Everything checked here came back OUT of the heap. That used to be a
# constraint rather than a choice — `machine.ex` addressed the heap in
# words and the RTL in cells, so a pointer's payload differed between
# model and gates and no test could report one. The model moved to cell
# addressing; `mk_ptr.exs` is the test that could not be written before,
# and it compares pointers directly.

alias PicoBEAM.{Asm, Encoding, Machine}

program = %{
  main:
    {0,
     [
       # ---- build [9, 8, 7] one cons at a time
       [{:ldi, 1, 7}],
       [{:ldn, 2}],
       [{:cons, 3, 1, 2}],
       [{:ldi, 4, 8}],
       [{:cons, 5, 4, 3}],
       [{:ldi, 6, 9}],
       [{:cons, 7, 6, 5}],
       # ---- walk it, summing the heads: 9 + 8 + 7 = 24
       [{:ldi, 8, 0}],
       [{:ldi, 9, 3}],
       [{:ldi, 10, 1}],
       [{:ldi, 12, 0}],
       :walk,
       [{:hd, 11, 7}],
       [{:add, 8, 8, 11}],
       [{:tl, 7, 7}],
       [{:sub, 9, 9, 10}],
       [{:cmpeq, 13, 9, 12}],
       [{:biff, 13, :walk}],
       [{:out, 8}],
       # the walk consumed the list down to NIL, and NIL is a term the
       # tag check has to accept as an end rather than trip over
       [{:istag, 14, 7, :nil}],
       [{:out, 14}],
       # ---- a 3-tuple, written out of order, read back in order
       [{:mktup, 1, 3}],
       [{:ldi, 2, 200}],
       [{:tset, 1, 1, 2}],
       [{:ldi, 2, -50}],
       [{:tset, 1, 2, 2}],
       [{:ldi, 2, 100}],
       [{:tset, 1, 0, 2}],
       [{:tget, 3, 1, 0}],
       [{:out, 3}],
       [{:tget, 4, 1, 1}],
       [{:out, 4}],
       [{:tget, 5, 1, 2}],
       [{:out, 5}],
       [{:tarity, 6, 1}],
       [{:out, 6}],
       # ---- nesting: a tuple element that is a list, walked back out
       [{:mktup, 7, 1}],
       [{:tset, 7, 0, 5}],
       [{:ldn, 8}],
       [{:cons, 9, 3, 8}],
       [{:tset, 7, 0, 9}],
       [{:tget, 10, 7, 0}],
       [{:hd, 11, 10}],
       [{:out, 11}],
       [{:halt}]
     ]}
}

asm = Asm.assemble(program)
m = asm |> Machine.new() |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

img = Encoding.image(asm, :main)
File.mkdir_p!("_emit/m3")

File.write!(
  "_emit/m3/heapprog.hex",
  Enum.map_join(img.image, "\n", fn w ->
    w |> Integer.to_string(16) |> String.pad_leading(18, "0")
  end) <> "\n"
)

File.write!(
  "_emit/m3/heapprog_expect.hex",
  Enum.map_join(m.out, "\n", fn v ->
    w = if is_integer(v), do: PicoBEAM.Term.int(v), else: PicoBEAM.Term.atom(
      Enum.find_index(PicoBEAM.Term.reserved_atoms(), &(&1 == v)))
    w |> Integer.to_string(16) |> String.pad_leading(9, "0")
  end) <> "\n"
)

IO.puts("status=#{status} bundles=#{length(img.image)}")
IO.puts("model outs = #{inspect(m.out)}")
IO.puts("__HEAPPROG_DONE__")
