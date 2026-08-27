# Build a microSD boot image — and the two files that let a testbench
# check `SdBoot` byte for byte.
#
#   mix run scripts/mk_image.exs
#
# Emits into _emit/sd/:
#
#   sdimg.img         the raw image, for `dd` onto a card
#   sdimg_bytes.hex   the same bytes, one per line, for the Verilog card
#   sdimg_code.hex    the bundles the loader MUST deliver (72-bit)
#   sdimg_pool.hex    the pool words it must deliver (36-bit)
#
# Image format (`SdBoot`'s moduledoc has the authority):
#
#   magic "pBM2" | bundle_count u16le | pool_count u16le |
#   entry0 u16le | entry1 u16le |
#   bundles 9B each (BE 72-bit) | pool words 5B each (BE, top nibble 0)
#
# The entry points are v2 (`notes/36`): with two engines on the board,
# where each one starts is a property of the IMAGE and not of the
# bitstream. 0x1FF means "do not boot this engine".
#
# padded to a whole number of 512-byte sectors.
#
# The program is a real Erlang module chosen to make the loader work
# rather than to be interesting:
#
#   * it has a LITERAL POOL, because the parser has a separate state for
#     pool words (`pstate 3`) that a pool-free image never reaches;
#   * it CROSSES A SECTOR BOUNDARY, because the moduledoc claims the
#     parser is sector-agnostic and nothing had ever tested the claim —
#     the comprehension and the `lists:` prelude are there for their
#     bundle count as much as for what they compute.
#
# `notes/26` bug 9 was that none of this had ever been executed at all.
#
# Write it to a card (the WHOLE-CARD device, not a partition; LBA 8192
# = 4 MiB in, clear of any partition table):
#
#   macOS:  sudo dd if=_emit/sd/sdimg.img of=/dev/rdiskN bs=512 seek=8192
#   linux:  sudo dd if=_emit/sd/sdimg.img of=/dev/sdX    bs=512 seek=8192

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(sdimg).
-export([main/0]).

main() ->
    erlang:display(fib(10)),
    erlang:display(big() - 1),
    L = [X * X || X <- lists:seq(1, 5)],
    erlang:display(lists:sum(L)),
    erlang:display(lists:reverse(L)),
    erlang:halt().

big() -> 2147483647.

fib(N) when N < 2 -> N;
fib(N) -> fib(N - 1) + fib(N - 2).
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/sdimg.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/sdimg.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>
pool_bin = for w <- img.pool, into: <<>>, do: <<w::40>>

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <> bundles_bin <> pool_bin

pad = rem(512 - rem(byte_size(body), 512), 512)
image = body <> :binary.copy(<<0>>, pad)

File.mkdir_p!("_emit/sd")
File.write!("_emit/sd/sdimg.img", image)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/sd/sdimg_bytes.hex",
  Enum.map_join(:binary.bin_to_list(image), "\n", &hx.(&1, 2)) <> "\n")

File.write!("_emit/sd/sdimg_code.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/sd/sdimg_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

# the engine-level testbenches load hex, not images — same program, so a
# board run and a simulation run can be compared directly
File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/sdimg.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/sdimg_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/sdimg_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("image: #{byte_size(image)} bytes (#{div(byte_size(image), 512)} sectors)")
IO.puts("bundles: #{length(img.image)}  pool: #{length(img.pool)}  entry: #{img.entry}")
IO.puts("status=#{status} model out = #{inspect(m.out)}")
IO.puts("__MK_IMAGE_DONE__")
