# 36 — Two engines, a card, and Elixir on silicon

```
p000 6 9 00 001 004 0 0 07 86 00 00
```

That is the ULX3S's debug UART, and it is the whole thing. Read left to
right:

| field | value | what it says |
|---|---|---|
| `S` | 6 | engine 0's seat 0 is *halted* — its process finished |
| `F` | 9 | idle, no faults, an `out` was seen |
| `RR` | 00 | occupancy zero on both engines |
| `AAA` | 001 | engine 0 spawned one process |
| `LLL` | 004 | four processes died in total |
| `OO` | 07 | the last `out` value |
| `W` | 8 | **`SdBoot` state 8 — done** |
| `D` | 6 | engine 1's seat 0 is halted too |
| `NN` | 00 | **zero abnormal deaths** |

Four processes: `main/0` and its worker on engine 0, `node1/0` and its
worker on engine 1. Both engines read the same image off the same
microSD card, started at the two entry points the image's header named,
ran an Elixir module to completion, and stopped.

## What had to be true for that line to appear

**A microSD loader that had never been executed.** `notes/34` is the
long version: 525 lines, no tests, and a Verilog SD card written to give
it something to talk to. It read three sectors, parsed a header,
delivered 122 bundles and a pool word — first run, no changes.

**A header that names entry points.** v1 had none; the board top
hard-coded `boot_pc`, which is fine with one engine and stops being fine
the moment a second one needs a second entry. The magic is `pBM2` now:

```
bytes 0..3    "pBM2"
bytes 4..5    bundle count
bytes 6..7    pool-word count
bytes 8..9    entry 0
bytes 10..11  entry 1   (0x1FF = do not boot this engine)
```

Where each engine starts is a property of the PROGRAM. That matters
more than it sounds: writing a card takes seconds, and a bitstream
rebuild takes twenty minutes.

**A core that is not a board.** `M5Core` holds the loader, both
engines, both ring links, the halt sideband and the UART; `Ulx3sM5Top`
holds the pins and the PLL. That split was forced rather than chosen —
EHDL promotes an *internal* clock to a port when a component is
flattened into another one, so a core whose 12 MHz came from a PLL
inside it could not be instantiated by a simulation wrapper without the
wrapper sprouting a `clk_12` input that nothing drove. Two nets with the
same idea and no connection between them, which simulates as a design
that never clocks. It cost an hour and left the design better: the part
that can be simulated is now cleanly separated from the part that
cannot.

**And a name that was not `sd`.** `instance :sd, SdBoot` collides with
this top's own `sd_lrx` wire once EHDL flattens the instance's internals
under its name. Invisible one level deep, a duplicate declaration two
levels deep. It is `:loader` now.

## The numbers

Two engines on the ECP5-85F:

| | one engine (`notes/24`) | two engines + ring + loader |
|---|---|---|
| LUT4 | 16,959 | **37,845** |
| TRELLIS_FF | — | 8,679 |
| DPR16X4 | 479 | 1,138 |
| DP16KD | — | 110 / 208 (52%) |
| MULT18X18D | 12 | 24 / 156 (15%) |
| fmax | 19.37 MHz | **18.09 MHz** |

It fits with room, and it passes timing at 12 MHz with 50% margin. The
7% fmax drop from one engine to two is routing congestion, not a new
critical path — the path is still `core_eng0_lt_links`, the
`SignalTable` link-bitmap read-modify-write that `notes/24` named, at
22.19 ns of logic and 33.08 ns of routing. Routing is 60% of it, which
is what a design at 45% utilisation looks like.

## The simulation and the silicon agree, number for number

`tb_m5_top` runs the same core in iverilog, against the same card model,
from power-up:

```
  entries: engine 0 at 0, engine 1 at 97
  engine 0: spawns=1 deaths=2   engine 1: spawns=1 deaths=2
  last out=0007
  __M5_OK__
```

The board said `AAA=001`, `LLL=004`, `OO=07`. The simulation says
spawns 1 and 1, deaths 2 and 2, out `0007`. There is nothing to
reconcile.

That is worth dwelling on, because `notes/15` set the rule at M2 —
*simulate the top, not just the parts* — and then the three top-level
testbenches quietly drifted out of the gate and the fixed-point demo had
to be checked on silicon instead. This is the first time the rule has
been followed for a board top that had never been built before, and the
first bitstream held no surprises.

It is slow. Two engines in iverilog manage about fifty clocks a second,
so the run is thirty-five minutes and it lives with the other board tops
outside `run_tbs.sh quick`. That is the correct price.

## The card was the bug, and it was an old friend

First boot after flashing: `W = 9`, the loader's error state, with the
engines idle and empty. The card had not been touched since August, and
LBA 8192 still read

```
00000000: 7042 4d31 1100 0000  pBM1....
```

`pBM1`, seventeen bundles — the fib demo from `notes/16`. Error 5, bad
magic, which is exactly what a v2 loader should say about a v1 image.
The fix was `dd`, and the readback is byte-identical:

```
00000000: 7042 4d32 d400 0100 0000 6100  pBM2......a.
```

212 bundles, one pool word, entry 0 at 0, entry 1 at 97.

One thing to write down for next time: that card is not blank. It
carries an MBR whose FAT32 partition begins at **exactly LBA 8192** —
picoBEAM's slot — and has done since long before this project. The
partition entry is a fossil; the filesystem was overwritten in August
and macOS has not mounted it since. But `SdBoot`'s moduledoc says
"clear of any partition table", and on this card that is not true. It is
true that nothing cares.

## What is not proven

Both engines execute independently out of one loader, and the ring is
wired between them with the halt sideband across both. **No message
crossed it on the board.** Cross-engine spawn and cross-engine signals
are still unbuilt (`notes/29`), so the demo gives each engine its own
work rather than pretending otherwise; `tb_ring2` is where a message
actually crosses, and it does so in simulation only.

The honest summary of the ring on silicon is: it is present, it is
clocked, it has never carried a flit.
