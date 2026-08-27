# Elixir, on the gates (notes/35).
#
#   mix run scripts/mk_elixir.exs
#     -> _emit/m3/elixir{,_pool,_expect}.hex
#     -> _emit/sd/elixir.img + the card-model bytes
#
# `priv/demo/pico_demo.ex` is compiled by the real Elixir compiler. The
# route down is `PicoBEAM.Ex`: debug_info out of the .beam, Erlang
# Abstract Format out of `:elixir_erl`, Core Erlang out of
# `:compile.forms(:to_core)`, and then the same front end that has
# compiled `.erl` since `notes/25` — because Core Erlang is the BEAM's
# intermediate language and Elixir reaches it the same way Erlang does.

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("priv/demo/pico_demo.ex")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/elixir.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/elixir_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/elixir_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

# ...and the same program as a bootable card image
bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>
pool_bin = for w <- img.pool, into: <<>>, do: <<w::40>>

# entry0 = main/0 on engine 0; entry1 = node1/0 on engine 1. Two
# engines, one image, and where each one starts is the image's business
# (`notes/36`).
e1 = Map.get(img.bases, :"node1/0", 0x1FF)

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, e1::16-little>> <> bundles_bin <> pool_bin

pad = rem(512 - rem(byte_size(body), 512), 512)
image = body <> :binary.copy(<<0>>, pad)

File.mkdir_p!("_emit/sd")
File.write!("_emit/sd/elixir.img", image)

File.write!("_emit/sd/elixir_bytes.hex",
  Enum.map_join(:binary.bin_to_list(image), "\n", &hx.(&1, 2)) <> "\n")

# ...and a second, deliberately tiny image, for pushing over the wire.
# `notes/37`'s reload path needs something whose arrival is unmistakable
# and whose transmission is short: 0xAB is not a number any other test
# program produces, and thirty bytes is nothing at any baud rate.
push =
  PicoBEAM.Asm.assemble(%{
    main: {0, [[{:ldi, 0, 0xAB}], [{:out, 0}], [{:ret, 0}]]}
  })

pimg = Encoding.image(push, :main)

pbody =
  <<0x70, 0x42, 0x4D, 0x32, length(pimg.image)::16-little, length(pimg.pool)::16-little,
    pimg.entry::16-little, 0x1FF::16-little>> <>
    (for w <- pimg.image, into: <<>>, do: <<w::72>>)

File.write!("_emit/sd/push.img", pbody)

File.write!("_emit/sd/push_bytes.hex",
  Enum.map_join(:binary.bin_to_list(pbody), "\n", &hx.(&1, 2)) <> "\n")

IO.puts("push image: #{byte_size(pbody)} bytes, #{length(pimg.image)} bundles, out=0xAB")

IO.puts("functions: #{inspect(Map.keys(prog))}")
IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("image: #{byte_size(image)} bytes (#{div(byte_size(image), 512)} sectors)")
IO.puts("entry0=#{img.entry} entry1=#{e1}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("__ELIXIR_DONE__")
