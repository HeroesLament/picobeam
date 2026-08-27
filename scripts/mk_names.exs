# The notes/50 demo — registered names + the recycling front end —
# as a tb_fixed vector pair and a pushable board image.
#
#   mix run scripts/mk_names.exs
#     -> _emit/m3/names{,_pool,_expect}.hex
#     -> _emit/sd/names.img

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/names_demo.ex")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/names.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/names_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/names_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>
pool_bin = for w <- img.pool, into: <<>>, do: <<w::40>>

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <> bundles_bin <> pool_bin

pad = rem(512 - rem(byte_size(body), 512), 512)
File.mkdir_p!("_emit/sd")
File.write!("_emit/sd/names.img", body <> :binary.copy(<<0>>, pad))

IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("image: #{byte_size(body)} bytes on the wire")
IO.puts("__NAMES_DONE__")
