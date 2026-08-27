# Push a `.pbi` image at the board over the debug cable (notes/37).
#
#   mix run scripts/pbpush.exs _emit/sd/elixir.img
#   mix run scripts/pbpush.exs _emit/sd/elixir.img /dev/cu.usbserial-D01477
#
# There is no handshake, no command byte and no length prefix: the
# board's parser runs loose, the magic "pBM2" is the frame sync, and a
# whole image landing is what makes it reboot. So this is `cat` with a
# baud rate, and that is the point — the entire protocol is the format
# the card already used.
#
# 2 KB at 115200 8N1 is about 180 ms. Writing the same image to a card
# means finding a reader, unseating the card, `dd`, and putting it back.
#
# The image STAYS on the card. This is volatile by design: push to
# iterate, `dd` when you want it to survive a power cycle.

[path | rest] = System.argv()

port =
  case rest do
    [p | _] ->
      p

    [] ->
      case Path.wildcard("/dev/cu.usbserial-*") do
        [p | _] -> p
        [] -> raise "no /dev/cu.usbserial-* found; pass the port explicitly"
      end
  end

img = File.read!(path)

<<"pBM2", nb::16-little, np::16-little, e0::16-little, e1::16-little, _::binary>> = img

# the trailing sector padding is zeros the parser would keep eating as
# bundles it was never promised; send exactly what the header describes
len = 12 + nb * 9 + np * 5
body = binary_part(img, 0, len)

# 115200 8N1, no flow control, and -hupcl so opening the port does not
# toggle DTR and reset anything.
{_, 0} = System.cmd("stty", ["-f", port, "115200", "raw", "-echo", "-hupcl", "cs8", "-parenb", "-cstopb"])

{:ok, fd} = :file.open(String.to_charlist(port), [:write, :raw, :binary])
:ok = :file.write(fd, body)
:ok = :file.close(fd)

IO.puts("pushed #{byte_size(body)} bytes to #{port}")
IO.puts("  #{nb} bundles, #{np} pool words, entry0=#{e0}, entry1=#{if e1 == 0x1FF, do: "none", else: e1}")
IO.puts("  ~#{Float.round(byte_size(body) * 10 / 115_200 * 1000, 1)} ms on the wire")
IO.puts("__PBPUSH_DONE__")
