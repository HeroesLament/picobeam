# Blinky — the hello-world of FPGAs, as a BEAM process.
#
#   mix run scripts/mk_blinky.exs   -> _emit/sd/blinky.img
#
# The program lives in examples/blinky.ex — see its header for the
# whole story (no new RTL: display's low byte reaches the LEDs while
# BTN2 is held, and `receive after N` is the timer wheel, N in
# machine cycles at 12 MHz).
#
# The program never halts, so there is no expect file and no
# testbench — the verdict is the board's LEDs, and the status line's
# OO byte alternating 00/ff. The model check below runs a
# short-period twin of the same source for a few thousand cycles and
# insists on the alternation.

alias PicoBEAM.{Ex, Encoding, Machine}

prog = Ex.compile_file("examples/blinky.ex")
img = Encoding.image(prog, :"main/0")

short = File.read!("examples/blinky.ex") |> String.replace("6_000_000", "400")
File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/blinky_short.ex", short)
mprog = Ex.compile_file("/tmp/pb_erl/blinky_short.ex")
{_status, m} = mprog |> Machine.new() |> Machine.boot(:"main/0", []) |> Machine.run(5_000)

expected = Enum.take(Stream.cycle([0, 255]), length(m.out))

if m.out != expected do
  raise "model blink pattern wrong: #{inspect(m.out)}"
end

bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>
pool_bin = for w <- img.pool, into: <<>>, do: <<w::40>>

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <> bundles_bin <> pool_bin

pad = rem(512 - rem(byte_size(body), 512), 512)
File.mkdir_p!("_emit/sd")
File.write!("_emit/sd/blinky.img", body <> :binary.copy(<<0>>, pad))

IO.puts("blinky: #{length(img.image)} bundles, pool=#{length(img.pool)}")
IO.puts("model (short period): #{inspect(m.out)}")
IO.puts("image: #{byte_size(body)} bytes on the wire")
IO.puts("__BLINKY_DONE__")
