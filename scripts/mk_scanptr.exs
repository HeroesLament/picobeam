# Does the Cheney SCAN follow every pointer the roots do? (`notes/46`)
#
#   mix run scripts/mk_scanptr.exs   -> _emit/m3/scanptr{,_expect}.hex
#
# `notes/40` made the collector's pointer tags `param`s so that adding a
# tag would be one line in one place, after `:fun` had already drifted
# once. The ROOT path took the params. The SCAN path — states 7, 8 and
# 12, where a pointer found INSIDE a copied object is evacuated — kept
# its literals, and its literals are 3 and 4: cons and tuple.
#
# So this program builds a map and a binary, hides both inside a tuple,
# drops every direct reference to them, and collects. The tuple is a
# root and is evacuated by the path that knows about maps. The map and
# the binary are found by the path that does not.
#
# If the scan is right, the answers are 70, 2 and 111.

alias PicoBEAM.{Asm, Encoding, Machine}

program =
  Asm.assemble(%{
    main:
      {0,
       [
         # %{7 => 70}
         [{:ldi, 15, 1}],
         [{:mkmap, 1, 15}],
         [{:ldi, 2, 7}],
         [{:ldi, 3, 70}],
         [{:tset, 1, 1, 2}],
         [{:tset, 1, 2, 3}],
         # <<111, 112>>
         [{:ldi, 15, 2}],
         [{:mkbin, 4, 15}],
         [{:ldi, 5, 111}],
         [{:ldi, 6, 112}],
         [{:tset, 4, 1, 5}],
         [{:tset, 4, 2, 6}],
         # {map, binary} — the tuple is about to be the ONLY root
         [{:mktup, 7, 2}],
         [{:tset, 7, 0, 1}],
         [{:tset, 7, 1, 4}],
         # ...which it is not until these two stop pointing at them.
         # Leave them in a register and the ROOT path evacuates them and
         # the bug hides.
         [{:ldi, 1, 0}],
         [{:ldi, 4, 0}],
         [{:ldi, 15, 0}],
         # 200 cells of garbage through a 128-cell semispace
         [{:ldi, 8, 200}],
         [{:ldi, 9, 1}],
         [{:ldi, 10, 0}],
         :loop,
         [{:mktup, 11, 2}],
         [{:tset, 11, 0, 8}],
         [{:tset, 11, 1, 8}],
         [{:sub, 8, 8, 9}],
         [{:cmpeq, 12, 8, 10}],
         [{:biff, 12, :loop}],
         [{:ldi, 11, 0}],
         # read both back THROUGH the tuple
         [{:tget, 1, 7, 0}],
         [{:ldi, 2, 2}],
         [{:mapat, 3, 1, 2}],
         [{:out, 3}],
         [{:tget, 4, 7, 1}],
         [{:ldi, 5, 0}],
         [{:binat, 6, 4, 5}],
         [{:out, 6}],
         [{:ldi, 5, 1}],
         [{:binat, 6, 4, 5}],
         [{:out, 6}],
         [{:halt}]
       ]}
  })

img = Encoding.image(program, :main)
m = program |> Machine.new(heap_words: 256) |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/scanptr.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/scanptr_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

gcs = length(Map.get(m.stats, :gc, []))
IO.puts("bundles=#{length(img.image)} status=#{status} collections=#{gcs}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("__SCANPTR_DONE__")
