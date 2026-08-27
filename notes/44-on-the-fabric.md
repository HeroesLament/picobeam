# 44 — On the fabric

```
p000 0 9 00 000 001 0 5 9e 80 00 00
                          ^^
```

`OO = 9e` is 158. That is a number the ECP5 worked out.

`notes/41` closed with the collector wired into the engine and a
sentence that had to be written carefully: *"Fmax is not measured here —
nextpnr is not in this container."* Everything since — funs, maps,
structs, binaries, strings — was proven against a netlist and a model
and nothing else. This note is the run where the design was placed,
routed, and made to do it.

## What the board costs now

`scripts/build_m5.sh`, two engines, on the ULX3S 85F:

```
   42,203  LUT4              50% of 83,640
   10,589  TRELLIS_FF
    1,138  TRELLIS_DPR16X4
      116  DP16KD            56% of 208
       26  MULT18X18D
        1  EHXPLLL

Max frequency for clock '$glbnet$clk_12': 14.59 MHz (PASS at 12.00 MHz)
```

Half the fabric, half the block RAM, and 2.59 MHz of headroom over the
12 MHz the design asks for. The collector, `mkfun`/`callfun`, the map
ops and the binary ops all landed inside the margin that was already
there; nothing had to be given back to make timing.

The 116 DP16KD is the number to watch. It was 114 before the collector,
and it is 116 now only because `FrameRamProc`'s GC port was built as a
muxed read rather than a second one (`notes/41`) — a true dual port
would have cost 32 more EBRs, and 148 of 208 is a different
conversation about what else can be put on this chip.

## One byte, on purpose

The debug UART is a status view, not a transcript. `DbgUart` carries
`OO`, the low byte of the LAST `out`, and nothing else of the output
stream. So a board program cannot be checked the way `tb_fixed` checks
one — word for word against the model's `out`.

`priv/demo/board_demo.ex` is written around that. It exercises four
things and then folds all four into a single byte:

```elixir
def main do
  a = funs()     #  22 — two closures, one over a free variable,
  b = maps()     #  12   both passed as values and called through
  c = bins()     # 116   a variable
  d = churn(k(40), 0)   # 1800 — forty turns of allocation
  :erlang.display(:erlang.band(a + b + c + d, 255))   # 158
end
```

`churn/2` builds a map, a binary and a list on every turn and keeps
nothing, which is what makes the collector run and what makes the four
answers above it have to survive being moved.

The claim on silicon is three fields, not one:

```
FL = 9    idle set, out seen
OO = 9e   the checksum
NN = 00   zero abnormal deaths
```

`NN` is the field that makes the other two mean something. It is the
count of processes that died of anything other than `normal`, and a
program that faulted its way to a plausible-looking byte would show it
here. `notes/26`'s whole argument for adding `XX`/`NN` to the line was
that the sticky fault bit could not tell a supervisor doing its job from
a crash loop; this is the first time that pair has been read in anger.

The netlist checks the whole stream — `board.hex outs=5/5
[22 12 116 1800 158]` — and the board checks the byte. It is the same
image both places: the container built `_emit/sd/board.img`, the
netlist ran the `.hex` beside it, and the `.img` was pushed down the
debug cable byte for byte.

## The push that did nothing

`pbpush.exs` reported success and the board kept running the card image:

```
pushed 3748 bytes to /dev/cu.usbserial-D01477
  414 bundles, 2 pool words, entry0=0, entry1=none
```

...and the next debug line was the OLD program's, unchanged. No error,
no partial load, no wrong answer — the bytes simply were not there.

This is the FTDI-after-JTAG gotcha wearing a different hat. The known
form of it is that reads on `/dev/cu.usbserial-*` hang forever after a
`fujprog` programming run; the form found here is that a WRITE is
accepted and dropped. `notes/37` recorded `pbpush.exs` working, and it
did — on a board that had been powered up rather than freshly
programmed over JTAG.

The way through is fujprog's own raw-send, which reopens the FTDI
itself and then hands the port to its terminal without an intervening
close:

```
fujprog -P /dev/cu.usbserial-D01477 -b 115200 -a _emit/sd/board.img -t
```

One process, one open, push and read. Use it after any JTAG operation.
`pbpush.exs` remains the right tool on a board that has only been
power-cycled, and it is worth keeping for that: it trims the sector
padding a card needs and a wire does not.

## Where this leaves things

The gate is 62 tests with `tb_fixed:board` in it. Everything from
`notes/40` through `notes/43` — the collector, closures, maps, structs,
binaries and strings — has now been placed and routed and run, not just
simulated. What has NOT been run on the board is the multi-process side
of all of it: `board_demo` is one process. Two engines are on the chip
and the ring is wired between them, but `notes/29`'s cross-engine spawn
and signals are still unbuilt, and the demo gives engine 1 nothing to
do. That is the next thing the LEDs should be made to show.
