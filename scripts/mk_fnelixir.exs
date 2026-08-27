# Elixir closures, through the whole engine (`notes/42`).
#
#   mix run scripts/mk_fnelixir.exs -> _emit/m3/fnelixir{,_pool,_expect}.hex
#
# `priv/demo/fun_demo.ex` is compiled by the real Elixir compiler and
# lowered through Core Erlang exactly as `notes/35`'s demo is. What is
# new is that the tree contains a `c_fun` with a free variable, which
# until now was an "unsupported Core Erlang construct".

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/fun_demo.ex")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(heap_words: 256) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/fnelixir.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/fnelixir_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/fnelixir_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("functions: #{inspect(Map.keys(prog))}")
IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("collections=#{length(Map.get(m.stats, :gc, []))}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("__FNELIXIR_DONE__")
