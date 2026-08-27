# 37 — One wire

```
$ mix run scripts/pbpush.exs _emit/sd/elixir.img
pushed 1920 bytes to /dev/cu.usbserial-D01477
  212 bundles, 1 pool words, entry0=0, entry1=97
  ~166.7 ms on the wire
```

The board reboots into it. No card, no reader, no unseating anything,
no `dd`, no button.

`notes/36` ended with a boot from microSD, and getting there took a
physical round trip: pull the card out of the ULX3S, find a reader,
write it, put it back. That is a fine way to ship an image and a
terrible way to iterate. This is the iteration path.

## The protocol is that there isn't one

No handshake, no command byte, no length prefix, no checksum, no
acknowledgement. The parser runs in **loose** mode: bytes that are not
`"pBM2"` slide the window, the four that are start an image, and a whole
image landing is what makes the board reboot.

So pushing a program is `cat`:

```
$ cat _emit/sd/elixir.img > /dev/cu.usbserial-D01477
```

`pbpush.exs` exists only to set the baud rate and to trim the image's
sector padding — the zeros a card needs and a wire does not.

Two things fall out of that, and both are the reason it is worth having:

**The line can carry anything when it is not carrying a program.** The
board's own debug UART is never quiet, someone opens `screen` on the
port, a terminal echoes; none of it can start a load, because none of it
is `pBM2`. `tb_uartload` sends junk first — including a lone `p`, the
byte that arms the window — and checks the parser is still hunting.

**The board cannot be told to do anything else this way.** There is no
"read memory", no "write register", no "reset". One format, one effect.
That is the correct amount of attack surface for a debug cable.

## One parser, two roads

The byte-stream parser used to live inside `SdBoot`, in the middle of a
500-line SPI state machine, because there was only ever one thing
feeding it. It is `ImageParser` now, and it is deliberately dumb: bytes
in, side-door writes out, no idea where they came from or how long they
took. `byte_en` arrives every 256 clocks from a card at 375 kHz or every
104 from the UART at 115200, and nothing in it notices.

The only difference between the two callers is one bit:

```elixir
# On a card the image is at a known sector and bad magic means the wrong
# image — `SdBoot` raises error 5 and stops. On a wire there is no known
# offset ... and the magic IS the frame sync.
input :strict, 1
```

Lifting it out was a change to a module that had been tested for the
first time three hours earlier. That is exactly when to do it:
`tb_sdboot` passed unchanged on the refactored version, which is what a
testbench is *for*, and the parser now gets exercised twice per gate run
by two completely different byte sources.

## What it cost in gates

`UartRx` is a divider and a shift register — 8N1, sample at mid-bit,
two flops on the async input, and a start bit that must still be low at
its centre or the frame is abandoned. The board sits next to a
transmitter that never stops, so noise rejection is not theoretical.

The board top grew one input pin: `ftdi_txd`, site M1, which has been on
the cable since the ULX3S was designed and which nothing here had ever
listened to.

## The seam, and how it is tested

The parts are easy; the seam is where boards go wrong. In `M5Core` the
two loaders share the side door and the boot FSM has to decide whose
image is running:

```elixir
ld_ce = bor(sd_ce, ul_ce)
ent0  = from_uart * ul_e0 + band(bnot(from_uart), 1) * sd_e0
```

They cannot both be talking — the card finishes before a wire can start,
and `receiving` holds `bst` at 0 for as long as bytes are arriving, which
is also what keeps the engines in reset while their code memories are
rewritten underneath them.

`tb_m5_top` now tests that end to end. It boots the two-engine core from
the card model, checks both engines ran, and then **pushes a second
image down the wire and checks the board rebooted into it**:

```
  after push: from_uart=1 out=00ab entry0=0
```

`0xAB` is not a number any other program in this project produces. The
push image is three bundles and thirty-nine bytes — `ldi 0xAB; out;
ret` — chosen so its arrival is unmistakable and its transmission is
nothing.

## What it does not do

**The card is not written.** This is volatile by design: push to
iterate, `dd` when you want an image to survive a power cycle. Teaching
`SdBoot` CMD24 so a pushed image writes through to the card is a real
option and a bigger one — it needs a writable card model, and a bug in
it scribbles on a card that, as `notes/36` found out, is not blank.

**There is no flow control.** At 115200 the receiver has 104 clocks per
bit and the parser consumes a byte in one, so there is nothing to
throttle. A faster wire would need a `ready`, and the FTDI can do 3
Mbaud, which is 4 clocks a bit — that is where this design stops being
free.
