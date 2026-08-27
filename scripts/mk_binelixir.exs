# Elixir binaries and strings, through the whole engine (`notes/43`).
#
#   mix run scripts/mk_binelixir.exs -> _emit/m3/binelixir{,_pool,_expect}.hex

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/bin_demo.ex")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(heap_words: 256) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/binelixir.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/binelixir_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/binelixir_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("functions: #{length(Map.keys(prog))}")
IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("collections=#{length(Map.get(m.stats, :gc, []))}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("__BINELIXIR_DONE__")
