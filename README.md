# picoBEAM

**An Erlang machine in FPGA fabric.** A soft processor whose instruction set,
scheduler, mailboxes, links, monitors and garbage collector are the ones Erlang
needs — written in [EHDL](https://github.com/HeroesLament/ehdl), targeting the
Lattice ECP5-85F on a ULX3S.

Elixir goes in. Bundles come out. They run on the fabric.

```elixir
def main do
  a = funs()      # closures over free variables, called through a variable
  b = maps()      # a map literal, a functional update, three lookups
  c = bins()      # <> , byte_size/1, :binary.at/2
  d = churn(40)   # forty turns of allocation, so the collector has to move it all
  :erlang.display(:erlang.band(a + b + c + d, 255))
end
```

```
p000 0 9 00 000 001 0 5 9e 80 00 00
                          ^^
```

`9e` is 158, off the board's debug UART, and it is the number the reference
model predicted and the netlist confirmed. `notes/44` has the run.

## Status

Everything below has been simulated against the reference model **and** placed
and routed. The starred rows have executed on a ULX3S.

| | |
|---|---|
| ★ barrel scheduler | 4 contexts, one pipeline, zero-cycle switch, reduction budgets |
| ★ processes | `spawn`, `self`, a 32-slot table, a run queue, swap in/out |
| ★ mailboxes | hardware match unit, shape hash, the full selective-receive family |
| ★ messages | `send` copies — serialiser out, deserialiser in — locally and across the ring |
| ★ supervision | links, monitors, `exit/2`, `trap_exit`, timers, `try`/`catch` |
| ★ arithmetic | signed 32-bit fixnums, trapping overflow, `mul` on DSP tiles, `mulsr` for fixed point |
| ★ heap and collector | cell-addressed two-space Cheney, per process, running concurrently with the engine |
| ★ data | cons, tuples, closures, **maps** (and structs behind them), **binaries and strings** |
| ★ Elixir | the real Elixir compiler → Core Erlang → bundles. `notes/35`, `notes/42`, `notes/43` |
| ★ boot | microSD, or a `.pbi` pushed down the debug cable in 300 ms |
| ★ one node, two engines | round-robin `spawn` across the ring (`notes/49`), a node-global registry (`notes/53`), links/monitors/`exit/2` crossing engines (`notes/54`) |
| ★ registered names | `register`/`whereis`/`unregister`, name death, `Name ! Msg` resolving node-wide (`notes/50`) |
| | ETS, external IO, distribution — which now means a SECOND BOARD (`notes/53` §4) |

```
gate        66 testbenches, 0 failed        scripts/run_tbs.sh quick
model       89 tests, 0 failed              mix test
opcodes     64 of 66 executed by a program  mix run scripts/cov_ops.exs
OTP shapes  14 of 15                        notes/30
silicon     52,327 LUT4 (62% of the 85F), 116 DP16KD (56%), 28 MULT18X18D
            Max frequency 12.15 MHz, closing at 12.00 MHz — two engines,
            ONE NODE: shared registry, supervision across the ring
```

The two opcodes no program has run are `recv`, which `Encoding` deliberately
refuses because the fused form does not exist in hardware, and `recv_hash`,
which is wired and has no emitter.

## The one-paragraph version

Ericsson built ECOMP, a processor that executed Erlang, demonstrated it on an
FPGA at the Erlang User Conference in 2000, and never made silicon. Twenty-odd
years later [Actora](https://github.com/blarney-lang/actora) rebuilt the
sequential half — a tagged stack machine with a hardware copying collector,
1,087 ALMs at 254 MHz, 1.3–4.1× faster than NIOS-II. Its README says *"no
concurrency features yet."* **Nobody has built the concurrent half of an Erlang
machine since 2000.** picoBEAM is an attempt at the half that is missing: spawn,
send, selective receive, links, monitors and exit signals as *gates* rather than
as a runtime written on top of an ISA. ECOMP's own slides list all of those as
*"implemented in machine code"*; `notes/45` scores the two machines against each
other row by row, including the rows where ECOMP is still ahead.

## The name

A nod to **picoJava**, Sun's Java processor — and a warning. picoJava tried to
be a *complete* Java machine and came out at 27,500 logic cells running 40 MHz
before the silicon was cancelled. Six years later JOP did the same job in
**1,831 logic cells at 100 MHz** by being small, caching whole methods, and
being worst-case analysable instead of feature-complete. The `pico` is a
promise about size, not a diminutive: JOP-shaped, picoJava-named.

## The four bets

| # | Bet | Consequence |
|---|-----|-------------|
| 1 | **No shared heap, ever.** Each engine owns a private heap in its own BRAM; messages are copied. | Per-engine GC, fully independent. A global stop-the-world pause is not merely rare — it is unrepresentable. |
| 2 | **The PID is the route.** The owning engine's index is a bit-field of the PID payload. | `send` needs no registry and no lookup. The destination is available in decode. |
| 3 | **Barrel threads, not context switches.** T process contexts interleave through one pipeline. | With T ≥ pipeline depth there is no bypass network and no interlock logic. A switch costs *zero* cycles. |
| 4 | **The fabric's shape is a computed value.** Engine count, thread count, heap depth and topology are solved at elaboration from a LUT/BRAM budget. | One source, every ECP5 part. This is the reason to write it in EHDL rather than SystemVerilog. |

Bet 1 paid off twice. Because `send` and `spawn` both copy, **no pointer is
ever held by two processes** — which is what lets the collector stop one process
instead of the world, with no read barrier and no tricolour invariant
(`notes/46`).

## What we are optimising for

Not throughput. The historical ceiling for special-purpose high-level-language
hardware is **2.31×** (Berkeley's PLM-vs-SPUR study, 1987), and that number
killed Lisp and Prolog machines; Azul later abandoned custom silicon for
software read barriers. picoBEAM argues on **bounds** instead — the case JOP
made for Java and won:

| claim | state |
|---|---|
| context switch between resident processes: **0 cycles** | structural — there is no switch, there are four program counters |
| allocation: **1 cycle** | measured; a cons is a pointer bump and one cell write |
| GC pause: **one process's live set**, not the engine's | measured — 350 cycles against 1,334 for the stop-the-world version it replaced (`notes/46`) |
| send of an immediate: bounded by ring diameter | measured, `notes/18` |
| selective receive: bounded by mailbox depth, not by message contents | structural — the matcher runs on the mailbox BRAM's second port |
| exit signal to supervisor: bounded by link count × ring diameter | structural — links are a bitmap, walked one bit per cycle |

The composite claim, which no BEAM has ever been able to make: **a genuine WCET
for an Erlang function including its sends and its allocation** — with the
supervision tree intact.

**One correction against earlier versions of this file**, because it was
claimed and is not true: the mutator is *not* stalled zero cycles by GC. The
collector has its own BRAM port, but the roots live in the register file and the
frame RAM, and reading them stops the process that owns them. `notes/41`
measured the stop-the-world version at 8% of wall clock; `notes/46` cut the
longest pause by 3.8× and did not cut the total. Zero remains the target and is
not the number.

## Running it

Everything but the last section runs anywhere with Elixir and iverilog.
[EHDL](https://github.com/HeroesLament/ehdl) is not a published package
yet, so check it out **beside** this repo — `mix.exs` resolves it as
`../ehdl`.

```sh
git clone https://github.com/HeroesLament/ehdl ../ehdl
mix deps.get && mix compile

mix test                        # the reference model, 89 tests
bash scripts/run_tbs.sh quick   # the gate: emit, check, simulate, 66 testbenches
bash scripts/run_tbs.sh         # ...plus the board tops, ~85% of the wall clock
```

`run_tbs.sh` is the whole story: it emits every component to Verilog, runs
`check_drivers.py` over the output, regenerates every test image from the
reference model, and compares gates against model word for word.

Compile a program and look at it:

```sh
mix run scripts/mk_board.exs    # priv/demo/board_demo.ex -> bundles + a .pbi
mix run scripts/cov_ops.exs     # which opcodes a program has actually run
```

On a ULX3S, with yosys, nextpnr-ecp5 and fujprog:

```sh
bash scripts/build_m5.sh                        # emit -> yosys -> nextpnr -> ecppack
fujprog _emit/ulx3s/picobeam_m5.bit             # program SRAM
bash scripts/board_push.sh _emit/sd/board.img   # push a program, read the status line
```

And the obligatory hello-world — `examples/blinky.ex` is a BEAM process
that sleeps on the timer wheel and lands its `display/1` byte on the
LEDs (hold BTN2 to see it):

```sh
mix run scripts/mk_blinky.exs                   # examples/blinky.ex -> 260-byte image
bash scripts/board_push.sh _emit/sd/blinky.img  # OO alternates 00/ff at 1 Hz
```

The push is `cat` with a baud rate: no handshake, no command byte, the magic
`pBM2` is the frame sync and a whole image landing is what makes the board
reboot into it (`notes/37`). Use fujprog's `-a` rather than `scripts/pbpush.exs`
after any JTAG operation — `notes/26` entry 23 for why.

## Target

| | |
|---|---|
| Board | ULX3S, `LFE5U-85F-6BG381C` (speed grade −6, the slowest) |
| Fabric | 84K LUT4, 208 × 18 kbit EBR = 3,744 kbit, 156 DSP, 4 PLL |
| Off-chip | 32 MB SDRAM (part varies by board revision), 16 MB QSPI flash |
| Flow | yosys + nextpnr-ecp5 + prjtrellis — the only fully mature open toolchain of the three candidates |
| Clock | 12 MHz today, from a PLL. `notes/44` has the timing report. |

Secondary targets, deliberately deferred: CrossLink-NX LIFCL-40 (no DRAM on the
eval board, prjoxide has not fuzzed LRAM) and Zynq-7020 on the LibreSDR (more
resources and 1 GB DDR3, but openXC7 has documented holes).

## Layout

```
lib/pico_beam/            the reference model — term, isa, asm, encoding,
                          machine, and the Core Erlang / Elixir front end
lib/pico_beam/rtl/        the machine, in EHDL. BarrelEngine and the
                          twenty-odd units around it
priv/demo/                Elixir programs that run on the fabric
scripts/                  emit, the gate, image generators, board builds
test/                     the model's tests
attic/                    M2 — superseded, kept, out of the compile path
notes/                    forty-seven of them; the project's memory
```

The notes are the design record and they are meant to be read. Some entry
points:

| | |
|---|---|
| `00-charter.md` | what this is, and what counts as success |
| `01-ecomp-2000.md` | the only surviving record of ECOMP, distilled, with verdicts |
| `03-architecture.md` | terms, engine, ring, GC, supervision |
| `26-known-bugs.md` | every bug worth the name, including the wrong diagnoses |
| `30-otp-conformance.md` | fifteen Erlang shapes, counted rather than assumed |
| `35-elixir-on-the-fabric.md` | how Elixir gets down to bundles |
| `41-stopping-the-world.md` | the collector, wired into the engine |
| `44-on-the-fabric.md` | place and route, timing, and the run on the board |
| `45-the-ecomp-scoreboard.md` | picoBEAM against ECOMP, row by row |
| `46-stopping-the-process.md` | the concurrent collector, and why it needs no barrier |
| `47-cross-engine-spawn.md` | the one subsystem that is designed and not built |

`AGENTS.md` is where to start if you are an agent.

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion shall be dual-licensed as above, without additional terms.
