# picoBEAM

**An Erlang machine in FPGA fabric.** A soft processor whose instruction set,
scheduler, mailboxes, links and garbage collector are the ones Erlang needs —
written in [EHDL](https://github.com/HeroesLament/ehdl), targeting the Lattice
ECP5-85F on a ULX3S.

> **Status: nothing is built.** This repository currently contains the
> architecture exploration, the prior-art survey and the roadmap. No RTL, no
> compiler, no simulator work. Start at [`notes/00-charter.md`](notes/00-charter.md),
> then [`AGENTS.md`](AGENTS.md).

## The one-paragraph version

Ericsson built ECOMP, a processor that executed Erlang, demonstrated it on an
FPGA at the Erlang User Conference in 2000, and never made silicon. Twenty-odd
years later [Actora](https://github.com/blarney-lang/actora) rebuilt the
sequential half — a tagged stack machine with a hardware copying collector,
1,087 ALMs at 254 MHz, 1.3–4.1× faster than NIOS-II. Its README says *"no
concurrency features yet."* **Nobody has built the concurrent half of an Erlang
machine since 2000, and nobody has ever put BEAM bytecode into hardware.**
picoBEAM is an attempt at the half that is missing: spawn, send, selective
receive, links, monitors and exit signals as gates rather than as a runtime
written on top of an ISA.

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

## What we are optimising for

Not throughput. The historical ceiling for special-purpose high-level-language
hardware is **2.31×** (Berkeley's PLM-vs-SPUR study, 1987), and that number
killed Lisp and Prolog machines; Azul later abandoned custom silicon for
software read barriers. picoBEAM argues on **bounds** instead — the case JOP
made for Java and won:

- context switch between resident processes: **0 cycles**
- allocation: **1 cycle**, always
- GC mutator stall: **0 cycles** (collector runs on the heap BRAM's second port)
- send of an immediate: bounded by ring diameter alone
- selective receive: bounded by mailbox depth, not by message contents
- exit signal to supervisor: bounded by link count × ring diameter

The composite claim, which no BEAM has ever been able to make: **a genuine WCET
for an Erlang function including its sends and its allocation** — with the
supervision tree intact.

## Target

| | |
|---|---|
| Board | ULX3S, `LFE5U-85F-6BG381C` (speed grade −6, the slowest) |
| Fabric | 84K LUT4, 208 × 18 kbit EBR = 3,744 kbit, 156 DSP, 4 PLL |
| Off-chip | 32 MB SDRAM (part varies by board revision), 16 MB QSPI flash |
| Flow | yosys + nextpnr-ecp5 + prjtrellis — the only fully mature open toolchain of the three candidates |
| Clock target | 50 MHz. Be pleased at 75. |

Secondary targets, deliberately deferred: CrossLink-NX LIFCL-40 (no DRAM on the
eval board, prjoxide has not fuzzed LRAM) and Zynq-7020 on the LibreSDR (more
resources and 1 GB DDR3, but openXC7 has documented holes).

## Layout

```
notes/
  00-charter.md        what this is, what counts as success
  01-ecomp-2000.md     the source deck, distilled, with verdicts
  02-prior-art.md      Actora, picoJava, JOP, Bacon, Cloaca, Reduceron, PLM
  03-architecture.md   term representation, engine, NoC, GC, supervision
  04-fit-model.md      the elastic fabric and its budget arithmetic
  05-determinism.md    what can be claimed, and how to measure it
  06-risks.md          what will hurt, EHDL-specific traps included
  07-roadmap.md        M0 … M9, each with the demo that proves it
  08-open-questions.md forks not yet decided
AGENTS.md              start here if you are an agent
```

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion shall be dual-licensed as above, without additional terms.
