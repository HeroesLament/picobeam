# 02 — Prior art

Survey done August 2026. Numbers are quoted from the cited source; where only
an abstract or a slide deck was reachable, that is said explicitly.

## The headline

| Machine | Year | What | Size | Clock | HW GC | Concurrency |
|---|---|---|---|---|---|---|
| ECOMP | 2000 | Erlang RISC/LIW, XC40150 | — | — | yes, concurrent | **yes — the only one** |
| Actora | ~2020 | Erlang-*like* stack machine | 1,087 ALM | 254 MHz | yes, copying | none |
| Reduceron | 2008 | Haskell graph reduction | — | 60–150 MHz | yes | n/a |
| Heron + Cloaca | 2023–24 | Lazy FP core, in Clash | — | 185–193 MHz | yes, concurrent | n/a |
| picoJava | 1997 | Java in silicon, Sun | 27,500 LC | 40 MHz | write barriers | no |
| JOP | 2003 | Java, WCET-analysable | 1,831 LC | 100 MHz | no | no |
| SHAP | 2007 | Java, GC in the MMU | 5,600 LC | 80 MHz | yes | no |
| PLM | 1987 | WAM in silicon | — | — | no | no |
| **picoBEAM** | — | Erlang fabric, ECP5 | ? | ~50 MHz | yes, per-engine | **the point** |

## Actora — the state of the art, and almost nobody knows about it

`github.com/blarney-lang/actora`. Compiles **Elite**, "a small Erlang-like
language," to a custom stack-machine ISA and to a hardware core. (`blarney-lang`
is Matthew Naylor's Blarney HDL org, so this is Reduceron lineage; the README
names no authors.)

- 26 instructions, 26-bit words. Three-stage pipeline (F/D/E).
- Separate instruction, stack and heap memories. **Dual-port stack RAM, two
  elements per cycle.** Two-cell-wide heap memory.
- **Tagged cells** carrying type, length, arity.
- **A fast copying GC implemented as a small hardware state machine.**
- DE5-Net: NIOS-II 850 ALMs @ 323 MHz vs **Actora 1,087 ALMs @ 254 MHz**.
  DE10-Pro: 1,154 @ 345 vs **1,229 @ 301**.
- Speedups vs NIOS-II at 56 KB heap: braun 4.10×, while 3.67×, adjoxo 2.86×,
  redblack 2.31×, fib 1.90×, mss 1.65×, shiftsub 1.55×, queens 1.30×. Largest
  gains on GC-heavy workloads.
- **"no concurrency features yet."**

Actora is the calibration point for everything picoBEAM's single-engine
milestone (M2) will measure, and it is the thing to be *compatible in spirit
with and different from*.

## picoJava — the namesake, and the warning

Sun's Java processor. 27,500 logic cells on Altera; ~440K gates in silicon;
40 MHz; write barriers, segment-based GC. Sun cancelled the microJava/picoJava
silicon.

Six years later **JOP did the same job in 1,831 logic cells at 100 MHz.** The
difference was not cleverness, it was scope: JOP is small, caches whole methods,
and is worst-case analysable rather than feature-complete. This is why the v1
subset in `00-charter.md` is austere, and it is why the project is called
picoBEAM.

## JOP — the mechanisms worth stealing

Schoeberl, *Evaluation of a Java Processor* and the JOP dissertation.

- 1,077 / 1,452 / 1,831 LCs (min / basic / typical, Cyclone EP1C6), 3.25 KB.
  100–101 MHz on Cyclone, 83 MHz on Spartan-3.
- **Stack cache in on-chip memory, fill/spill under microcode control** —
  therefore time-predictable. This is the entire real-time argument.
- **Method cache: 4 KB in 16 blocks, caching *whole methods*.** Misses can only
  occur at invoke and return, which makes WCET analysis tractable. **Erlang's
  function boundaries are exactly as sharp as Java's — this transfers
  directly.**
- Measured microcode costs: `iload+iadd` 2 cycles, `iinc` 11, `ldc` 9,
  `getfield` 23, `invoke` **126**.
- 10,657 iterations/s at 100 MHz; normalised, 107 it/s per MHz vs aJ100's 92.
- Real-time claim is a jitter ratio (longest/shortest execution period) of
  **3 for JOP vs 5 for the JStamp.** That is the shape of the number picoBEAM
  should be publishing.

## Hardware garbage collection

**Bacon, Cheng & Shukla, "And then there were none: a stall-free real-time GC
for reconfigurable hardware," PLDI 2012.** The template.

- Snapshot-at-the-beginning concurrent collector; root-snapshot, tracing and
  sweeping engines.
- **The key mechanism is dual-ported BRAM.** Mutator on port A, collector on
  port B — the root snapshot pause is *eliminated*, not shortened. Write
  barriers use **read-before-write BRAM mode**, capturing the overwritten
  pointer in one cycle with no mutator stall.
- **"Miniheaps":** fixed-size uniform objects, each field in its own BRAM,
  pointers exactly ⌈log₂N⌉ bits wide.
- **Virtex-5 LX330T: collector costs <0.7% of slices** even at a 64K-object
  heap. 24% more memory than malloc; clock 15–39% lower; runtime 4–17% slower.
  **100% mutator utilisation at heaps only 1.01–1.4× minimum live data.**

**Ramsay & Stewart, "Cloaca," Haskell Symposium 2024.** Concurrent hardware GC
for Heron. Mark-and-sweep tracing combined with **one-bit reference counting**.
Hardware write barriers + dual-port read-first memories make the barrier
single-cycle. ~20-cycle pauses; catches ~50% of garbage before tracing; **4.1%
of GHC's GC wall-clock across 14 of 15 nofib benchmarks despite running at
~1/25th the clock** (Heron 185 MHz vs i7-1250U 2.0/4.7 GHz). Their motivating
number: GHC's *software* concurrent low-latency GC costs a median +21% slowdown
on nofib. *(ACM and Heriot-Watt PDFs both 403; numbers from the abstract and the
authors' slides.)*

**Azul Vega.** A read-barrier *instruction* plus a fast user-level trap; most of
the GC ran in software (Click, Tene, Wolf, VEE 2005). **Azul subsequently
abandoned custom silicon and reimplemented the barrier in software on x86 (C4).**
The single most important negative datapoint for hardware-GC economics.

**Maas et al.**, ASBD 2016 / ISCA 2018. Near-DRAM mark unit + relocation unit.
Their post-mortem on why hardware GC never stuck: GC'd languages rarely run
alone, commodity cores won on Moore's-Law economics, and prior proposals were
"very invasive," requiring memory-system re-architecture. **picoBEAM avoids that
last one by construction — there is no memory system to re-architect, only
BRAM we already own.**

## The functional-language lineage

**Reduceron** (Naylor, Runciman, Reich, York). Template-instantiation graph
reduction with hardware GC. Widens the von Neumann bottleneck with very wide,
multi-ported parallel memories (separate stack / heap / template), ~6 reduction
ops per cycle. 60–150 MHz depending on FPGA. *(MHz from the repo; the JFP paper
is paywalled.)*

**Heron** (2023–24, Heriot-Watt, HAFLANG, EPSRC EP/W009447/1). Written in Clash,
targets Alveo U280 and Ultra96. 185–193 MHz; beta reduction in one clock cycle
via multiple wide multi-ported memories (**322-bit** heap word, 86-bit stacks);
mean 0.6 reductions/cycle; "up to six times as many reductions per cycle as
Reduceron"; "×5 better than GHC per cycle."

**SKIM** (1980) — the ancestor. Microcoded SK combinator reduction with
hardware-assisted cell reclamation. Established the tagged-cell + hardware-
reclaim pattern the whole lineage inherits.

**PLM vs SPUR** (Berkeley, 1987). The number that killed the field: a
general-purpose tagged RISC executed **16× more instructions** and was **14×
larger in code** than the special-purpose Prolog machine, yet took **only 2.31×
the machine cycles.** Read this before making any throughput claim.

**"Erlang Inspired Hardware"** (Ferreira et al., FPL 2010, ISEP Porto). Not a
processor — a synthesis approach: Core Erlang → FSMDs → Verilog, one hardware
unit per Erlang process, messages → hardware channels. **No quantitative
results at all.** Conceptually adjacent, empirically empty.

## Soft-core baselines, for calibration

Artix-7, from the VexRiscv README: small RV32I 504 LUT / 243 MHz / 0.52
DMIPS/MHz; full RV32IM no cache 1,418 LUT / 216 MHz / 1.21 DMIPS/MHz; Linux
RV32IMA 2,883 LUT / 180 MHz. iCE40 small: 1,130 LC @ 92 MHz.

SERV (bit-serial, the floor): iCE40 198 LUT, Artix-7 125 LUT, 2.1 kGE ASIC.

NEORV32 RTOS-capable `rv32imc`: ~2,300 LUT / 1,000 FF at 130 MHz on Cyclone IV,
CoreMark 0.95/MHz.

J1 Forth (Bowman) — closest structural analogue to a tagged stack machine:
16-bit, dual stacks (33-deep data, 32-deep return), <200 lines of Verilog,
80 MHz on Spartan-3E, ~100 Forth MIPS, most ops single-cycle, `exit` free. Code
density ~62% better than MicroBlaze. J1a "fits easily on the Lattice HX20-1K"
(~1,280 LC).

ECP5 planning rule (community, not vendor): ECP5 LUT4s run roughly 1.3–1.5× the
count of Xilinx 6-input LUTs for the same design, at roughly 60–75% of Artix-7
Fmax. **No authoritative soft-core Fmax citation for ECP5 + nextpnr was found.**
LiteX's ULX3S target defaults to 50 MHz and the board ships the −6 grade, the
slowest. Do not plan above 50 MHz without running nextpnr on real RTL.

## Dead ends, recorded so nobody repeats the search

- **No ECOMP patent, paper, thesis or retrospective exists.** One .ppt, one
  mailing-list paragraph.
- **No BEAM-bytecode-to-hardware project has ever existed.** Not academic, not
  industrial, not hobbyist.
- **No Erlang-on-FPGA thesis** at Chalmers / Uppsala / KTH surfaced.
- **PilGRIM** (Twente, IFL 2010): no free full text, no numbers obtained.
- **Nilsen & Schmidt** hardware GC (LOPLAS 1992, ASPLOS 1994, IWMM 1995): all
  paywalled, abstracts only, no hardware numbers.
- **Meyer's object-based processor**: secondary citations only.
- **Lattice Nexus soft-core baselines**: none found, at all.

## Adjacent, software, worth knowing

**AtomVM** (`atomvm.org`) runs *standard BEAM bytecode* on ESP32-class MCUs with
spawning, monitoring, message passing, preemptive scheduling and GC. The
existence proof that a BEAM subset fits in tiny memory, and the natural
reference for which opcodes actually matter. **Firefly** (formerly Lumen) — AOT
BEAM compiler via MLIR, effectively dormant; relevant only as evidence that BEAM
semantics can be lowered to a static compilation target.
