# Four processes allocating through one semispace (`notes/46`).
#
#   mix run scripts/mk_gcconc.exs -> _emit/m3/gcconc{,_pool,_expect}.hex
#
# `mk_gcloop.exs` measures the collector on ONE process, where there is
# nothing to gain from not stopping the world: the engine has nobody
# else to run. This is the program where the difference exists.

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/gc_conc.ex")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(heap_words: 256) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/gcconc.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/gcconc_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/gcconc_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("collections=#{length(m.stats.gc)} deaths=#{length(m.stats.deaths)}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("__GCCONC_DONE__")
