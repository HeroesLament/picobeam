# Binaries, through the whole engine, in slots rather than in Elixir
# (`notes/43`).
#
#   mix run scripts/mk_bins.exs   -> _emit/m3/bins{,_expect}.hex
#
# A binary is a tuple-shaped object with a tag of its own: header, byte
# count, then the bytes. `mkbin` allocates it, `tset` fills it at a
# literal index and `mset` at a computed one, and `binat` reads a BYTE —
# which is the whole reason the layout underneath can change later
# without touching a compiled program.

alias PicoBEAM.{Asm, Encoding, Machine}

program =
  Asm.assemble(%{
    main:
      {0,
       [
         # "hi"
         [{:ldi, 0, 2}],
         [{:mkbin, 1, 0}],
         [{:ldi, 2, 104}],
         [{:ldi, 3, 105}],
         [{:tset, 1, 1, 2}],
         [{:tset, 1, 2, 3}],
         # size, then both bytes
         [{:ldi, 4, 0}],
         [{:binat, 5, 1, 4}],
         [{:out, 5}],
         [{:ldi, 6, 1}],
         [{:binat, 7, 1, 6}],
         [{:out, 7}],
         [{:ldi, 8, 2}],
         [{:binat, 9, 1, 8}],
         [{:out, 9}],
         # collect around it
         [{:ldi, 10, 200}],
         [{:ldi, 11, 1}],
         [{:ldi, 12, 0}],
         :loop,
         [{:mktup, 13, 2}],
         [{:tset, 13, 0, 10}],
         [{:tset, 13, 1, 10}],
         [{:sub, 10, 10, 11}],
         [{:cmpeq, 14, 10, 12}],
         [{:biff, 14, :loop}],
         [{:arg, 0, 1}],
         [{:tailcall, :after, 1}]
       ]},
    after:
      {1,
       [
         # ...and read it back on the other side
         [{:ldi, 1, 1}],
         [{:binat, 2, 0, 1}],
         [{:out, 2}],
         # write a byte at an index the program computed
         [{:ldi, 3, 2}],
         [{:mseti, 3}],
         [{:ldi, 4, 33}],
         [{:mset, 0, 4}],
         [{:binat, 5, 0, 3}],
         [{:out, 5}],
         # a binary is a binary, and `element/2` on one raises
         [{:istag, 6, 0, :bin}],
         [{:out, 6}],
         [{:istag, 7, 0, :tuple}],
         [{:out, 7}],
         [{:halt}]
       ]}
  })

img = Encoding.image(program, :main)

m = program |> Machine.new(heap_words: 256) |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/bins.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/bins_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("collections=#{length(Map.get(m.stats, :gc, []))}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("__BINS_DONE__")
