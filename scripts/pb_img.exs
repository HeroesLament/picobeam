# Build a pushable picoBEAM image from an Elixir source file, and run it on
# the ISA model for the expected output.
#
#   mix run scripts/pb_img.exs SRC.ex [OUT.img]
#
# SRC defines `main/0` (engine 0) and optionally `node1/0` (engine 1), as
# `priv/demo/pico_demo.ex` does. OUT defaults to _emit/sd/<SRC basename>.img.
# The last stdout line is JSON: {"img", "bundles", "pool", "entry0",
# "entry1", "status", "model_out"} (model_out: engine 0's `out` words on
# `PicoBEAM.Machine`, main/0 alone). fabfarm's `FabFarm.Pb` reads it.

alias PicoBEAM.{Ex, Encoding, Machine}

{src, out} =
  case System.argv() do
    [src] -> {src, Path.join("_emit/sd", Path.basename(src, ".ex") <> ".img")}
    [src, out] -> {src, out}
    _ -> raise "usage: mix run scripts/pb_img.exs SRC.ex [OUT.img]"
  end

prog = Ex.compile_file(src)
img = Encoding.image(prog, :"main/0")
e1 = Map.get(img.bases, :"node1/0", 0x1FF)

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, e1::16-little>> <>
    for(w <- img.image, into: <<>>, do: <<w::72>>) <>
    for(w <- img.pool, into: <<>>, do: <<w::40>>)

File.mkdir_p!(Path.dirname(out))
File.write!(out, body)

IO.puts(
  JSON.encode!(%{
    img: Path.expand(out),
    bytes: byte_size(body),
    bundles: length(img.image),
    pool: length(img.pool),
    entry0: img.entry,
    entry1: e1,
    status: inspect(status),
    model_out: Enum.map(m.out, &(if is_integer(&1), do: &1, else: inspect(&1)))
  })
)
