# The collector, through the whole engine (`notes/40`).
#
#   mix run scripts/mk_gcloop.exs   -> _emit/m3/gcloop{,_pool,_expect}.hex
#
# `priv/demo/heap_stress.ex` builds a fresh 2-tuple every iteration and
# keeps only the newest, so live data stays at one cell and garbage
# arrives at one cell per turn. On a 128-cell semispace that is a
# collection every sixty-odd iterations, and four hundred iterations is
# therefore several collections deep — which is the point. A program
# that survives ONE collection proves the evacuation; a program that
# survives more than its heap has cells proves the roots were rewritten,
# because the second collection walks what the first one moved.
#
# The model runs with `heap_words: 256` — two 128-cell semispaces, the
# same arena the gates have — so both sides collect on the same
# allocation and run out of memory, if they ever do, on the same one.

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/heap_stress.ex")
img = Encoding.image(prog, :"main/0")

m =
  prog
  |> Machine.new(heap_words: 256)
  |> Machine.boot(:"main/0", [])

{status, m} = Machine.run(m, 2_000_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/gcloop.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/gcloop_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/gcloop_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

gcs = length(Map.get(m.stats, :gc, []))

IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("outs=#{length(m.out_raw)} collections=#{gcs}")
IO.puts("first out = #{inspect(Enum.take(m.out, 3))}")
IO.puts("last out  = #{inspect(Enum.take(m.out, -3))}")
IO.puts("__GCLOOP_DONE__")
