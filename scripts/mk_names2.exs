# The Phase-3 gate (notes/53): registered names across TWO engines.
#
#   mix run scripts/mk_names2.exs   -> _emit/m3/names2{,_pool,_expect}.hex
#
# The expectations come from `Machine` running the same program with
# `engines: 2` — model versus gates, not a hand-written guess.

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/names2_demo.ex")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(engines: 2) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/names2.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!(
  "_emit/m3/names2_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n"
)

File.write!(
  "_emit/m3/names2_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n"
)

IO.puts("names2: #{length(img.image)} bundles, pool=#{length(img.pool)}")
IO.puts("model out: #{inspect(m.out)}")
IO.puts("model raw: #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("status=#{status} halted=#{m.halted} cycles=#{m.cycle}")
IO.puts("__NAMES2_DONE__")
