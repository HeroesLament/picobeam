# Maps, through the whole engine (`notes/42`).
#
#   mix run scripts/mk_maps.exs   -> _emit/m3/maps{,_expect}.hex
#
# A flatmap is a tuple-shaped object with a tag of its own: header, pair
# count, then one key/value pair per CELL. `mkmap` allocates it, `tset`
# fills it at literal indices — which is what a map LITERAL needs, since
# its size is known — and `mapat` reads it at a computed one, which is
# what a probe loop needs.
#
# `mseti`/`mset` are the write half of that: a heap op has two register
# reads and a fill needs three things, so the index comes in a separate
# pure op. What it latches is an integer, which is why it survives a
# collection where a latched POINTER would not.
#
# The churn between the two halves is not decoration: it makes the
# second map, and every probe of the first, run on a heap where
# everything has moved.

alias PicoBEAM.{Asm, Encoding, Machine}

program =
  Asm.assemble(%{
    main:
      {0,
       [
         # %{7 => 70, 9 => 90}, built with literal indices
         [{:ldi, 15, 2}],
         [{:mkmap, 1, 15}],
         [{:ldi, 2, 7}],
         [{:ldi, 3, 70}],
         [{:tset, 1, 1, 2}],
         [{:tset, 1, 2, 3}],
         [{:ldi, 4, 9}],
         [{:ldi, 5, 90}],
         [{:tset, 1, 3, 4}],
         [{:tset, 1, 4, 5}],
         # collect around it
         [{:ldi, 6, 200}],
         [{:ldi, 7, 1}],
         [{:ldi, 8, 0}],
         :loop,
         [{:mktup, 9, 2}],
         [{:tset, 9, 0, 6}],
         [{:tset, 9, 1, 6}],
         [{:sub, 6, 6, 7}],
         [{:cmpeq, 10, 6, 8}],
         [{:biff, 10, :loop}],
         # ...and read it back on the other side
         [{:arg, 0, 1}],
         [{:tailcall, :probe, 1}]
       ]},
    probe:
      {1,
       [
         [{:ldi, 1, 0}],
         [{:mapat, 2, 0, 1}],
         [{:out, 2}],
         [{:ldi, 3, 1}],
         [{:mapat, 4, 0, 3}],
         [{:out, 4}],
         [{:ldi, 5, 2}],
         [{:mapat, 6, 0, 5}],
         [{:out, 6}],
         [{:ldi, 7, 3}],
         [{:mapat, 8, 0, 7}],
         [{:out, 8}],
         [{:ldi, 9, 4}],
         [{:mapat, 10, 0, 9}],
         [{:out, 10}],
         [{:tailcall, :built, 0}]
       ]},
    built:
      {0,
       [
         # a map filled through the latched index, at indices a literal
         # `tset` could not reach without knowing them at assembly time
         [{:ldi, 15, 2}],
         [{:mkmap, 0, 15}],
         [{:ldi, 1, 1}],
         [{:mseti, 1}],
         [{:ldi, 2, 42}],
         [{:mset, 0, 2}],
         [{:ldi, 3, 2}],
         [{:mseti, 3}],
         [{:ldi, 4, 43}],
         [{:mset, 0, 4}],
         [{:mapat, 5, 0, 1}],
         [{:out, 5}],
         [{:mapat, 6, 0, 3}],
         [{:out, 6}],
         # a map is a map, and `element/2` on one raises
         [{:istag, 7, 0, :map}],
         [{:out, 7}],
         [{:istag, 8, 0, :tuple}],
         [{:out, 8}],
         [{:halt}]
       ]}
  })

img = Encoding.image(program, :main)

m = program |> Machine.new(heap_words: 256) |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/maps.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/maps_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("collections=#{length(Map.get(m.stats, :gc, []))}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("__MAPS_DONE__")
