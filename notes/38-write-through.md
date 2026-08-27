# 38 — Write-through

`notes/37` ended with a caveat:

> **The card is not written.** This is volatile by design: push to
> iterate, `dd` when you want an image to survive a power cycle.

It is written now. A pushed image reaches the engines through the side
door *and* the card through CMD24, in that order, and the order is the
whole design.

## The reboot does not wait for the card

The side door is instant and the card is not. A 512-byte block write is
a command, a token, 512 bytes, two CRC bytes, a response and then
however long the card feels like being busy — a few byte times on a good
day, a quarter of a second on a bad one, and no way to know in advance.

So the machine reboots into the pushed image the moment the last byte
lands, exactly as it did in `notes/37`, and the card write happens
afterwards, behind the running program. Nothing waits on it. The only
thing it buys is that the image is still there after a power cycle, and
that is worth having *later* rather than sooner.

That also means `wr_err` is not `err`. A failed write leaves a running
machine running, and the image it is running came off the wire.

## Where the bytes come from

Not from re-serialising what the parser took apart — that would be the
format written twice, in two places, drifting. `ImageParser` grew a raw
tap instead:

```elixir
output :store_en, 1
output :store_idx, 13
output :img_len, 13
```

Every byte that is part of a candidate image, magic included, at the
index it arrived at. The parser already tracks its position to know
whether it is reading a header, a bundle or a pool word; `store_idx` is
that position, and `img_len` is where it stopped. `SdBoot` keeps an
8 KB buffer — the largest image this machine can hold is 512 bundles at
nine bytes plus 256 pool words at five plus a twelve-byte header, which
is 5,900 — and fills it as the bytes go past.

## The card is already awake

CMD24 needs no setup. `SdBoot` did CMD0, CMD8 and the CMD55/ACMD41 loop
at power-up, and SPI mode is sticky, so a write is: raise CS, send
CMD24 with the sector, wait for R1, send `0xFE`, 512 bytes, two CRC
bytes the card ignores (SPI-mode CRC is off unless CMD59 turns it on and
nothing here turns it on), read the data-response byte, and then **wait
out the busy**.

That last one is the part that separates a writer that works from a
writer that works in simulation. The card holds MISO low while its flash
settles. State 12 sits there until it lets go. The card model does the
same for a few byte times, which is not realistic timing but is enough
to catch a writer that never looked.

Three states, one new command phase, and a table entry: CMD24 is 0x58
and carries a sector argument exactly as CMD17 does, so

```elixir
<<2::3>> -> cmd_byte = band(phase > 3, 1) * sector[23..16]
```

covers both.

## The bug, which was the one you would expect

The buffer is a sync-read memory and the byte engine latches `tx_sel`
the cycle after `byte_go`. Present the address at the same moment and
the data is one cycle late, so every byte after the first is the
previous one:

```
FAIL written byte 1: card 03, sent 0a
```

Byte 0 was right because its address had been standing since the data
token. The fix is to read one ahead — the address for byte *n+1* has to
be up while byte *n* is being sent — which costs one line and a comment
explaining why the line is not where you would put it.

Same species as `notes/28`'s collector sampling the heap a cycle early,
and it presented the same way: the first one works by accident.

## And a testbench bug, which is worth naming separately

`wr_done` is a one-cycle strobe. That is the right shape for RTL and the
wrong shape to sample from a testbench that reads at the same edge the
DUT writes: iverilog gave the old value at the edge it went high and the
new value at the next, by which time the DUT had already cleared it.

The strobe is not wrong. The observer was. `tb_sdboot` latches it now,
which is what any other consumer would do anyway.

## What is checked

**`tb_sdboot`** fills the buffer with a pattern, writes two sectors, and
then reads the card model's memory back. The model stores what it was
sent, so a writer that gets the token, the length, the CRC padding or
the response wrong cannot pass.

**`tb_m5_top`** does it the way the board does. Boot two engines off the
card, push a different image down the wire, watch the machine reboot
into it — and then read the card:

```
  after push: from_uart=1 out=00ab entry0=0 deaths=1
  card write: wrote=1 err=0
```

...and compare all 39 bytes against what was pushed. The loop is closed:
what went down the wire is what the loader will find at LBA 8192 next
time the board powers up.

## On silicon

The bitstream is 38,516 LUT4 and 17.13 MHz, and the loop closes on the
board:

```
after the push:      … 0 5 91 80 …     from_uart=1, write done, out=0x91
after a reflash:     … 0 0 91 80 …     from_uart=0, loader state 8
```

The second line is the one that matters. The board was reconfigured, the
UART loader had nothing to say, and the microSD held the image that had
been pushed down the wire — so the loader read it and booted it.
`notes/39` §8 has the field-by-field reading.

## The cost

| | `notes/36` | with the wire | with write-through |
|---|---|---|---|
| LUT4 | 37,845 | — | **38,516** |
| DP16KD | 110 | — | **114** |
| TRELLIS_FF | 8,679 | — | 9,079 |

Four block RAMs for the 8 KB buffer and about 670 LUTs for everything
else — the receiver, the parser's raw tap, three states and a mux. On a
device with 98 spare block RAMs and 45,000 spare LUTs.

## Still not done

**The write is all-or-nothing at the image level.** There is no
verification pass: the card says "accepted" and is believed. Reading the
sector back and comparing would cost one more state and the buffer is
still sitting there — worth doing, and not today.

**Nothing writes a partition table.** The image goes to LBA 8192 because
that is where the loader looks, and `notes/36` already noted that on
this particular card, LBA 8192 is inside a FAT32 partition whose
filesystem was overwritten in August. Nothing cares, and it is still
true that `SdBoot`'s moduledoc claims otherwise.
