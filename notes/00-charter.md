# 00 — Charter

## What picoBEAM is

A soft processor for the Lattice ECP5 whose instruction set, scheduler,
mailboxes, links and garbage collector are the ones Erlang needs, written in
EHDL. Not a RISC-V running BEAM. Not a coprocessor. The machine itself.

## Why it is worth building

Three facts, established by survey (see `02-prior-art.md`) and each with a
citation:

1. **ECOMP existed and vanished.** Ericsson demonstrated an Erlang processor at
   EUC 2000 with hardware GC, hardware process switching in ~20 cycles and a
   hardware reduction budget. There is no paper, no patent, no thesis, and no
   mention in Armstrong's HOPL III history of Erlang. Fifteen slides is the
   entire public record.
2. **The sequential half was rebuilt; the concurrent half was not.** Actora is
   a tagged Erlang-like stack machine with a hardware copying collector,
   1,087 ALMs at 254 MHz, 1.30–4.10× faster than NIOS-II across eight
   benchmarks. Its README: *"no concurrency features yet."* No spawn, no send,
   no mailbox, no scheduler.
3. **Nobody has ever put BEAM in hardware.** No academic work, no industrial
   work, no hobbyist project. Searched: BEAM-bytecode-to-hardware, Erlang-on-
   FPGA theses at Chalmers / Uppsala / KTH, 2020s actor-model hardware. Empty.

So the unbuilt thing is specific and nameable: **spawn, send, selective
receive, links, monitors and exit-signal propagation as gates.** That is the
project.

## What counts as success

In priority order, as chosen deliberately:

### 1. Determinism and bounded latency

The JOP argument, applied to Erlang. Hardware scheduling and a stall-free
concurrent collector give provable worst-case bounds a software BEAM cannot
offer. The target claim is a genuine WCET for an Erlang function *including its
message sends and its allocation*, with supervision intact. See
`05-determinism.md` for what specifically can be claimed and measured.

This is the hill because it is the only one that can be taken. Throughput is
not: Berkeley's 1987 PLM-vs-SPUR study found special-purpose Prolog hardware
beat a general tagged RISC by **2.31× on cycles**, and that number ended the
field. Azul later abandoned custom silicon for software read barriers. Do not
build the throughput argument.

### 2. It pushes EHDL forward

A CPU is the most demanding thing you can build in an HDL. It will find every
hole in the elaborator, the linter and — first and worst — the simulator, which
currently runs at 4 ticks/s and cannot simulate a processor at all. Treat
picoBEAM as a forcing function for the toolchain and count toolchain fixes as
project output, not as overhead.

### 3. It runs, and it's ours

An Erlang machine that spawns processes, passes messages, collects garbage and
restarts a crashed child under a supervisor, on real silicon, from Erlang
source. The artifact is the point. Benchmarks are gravy.

## What does not count as success

- Beating Actora on `fib` or `nrev`. The barrel makes single-process latency T×
  worse and that trade was made on purpose.
- Running unmodified `.beam` files. ~180 opcodes with variable-arity operands
  and a non-uniform heap is a different, much larger project. The v1 front end
  is Core Erlang.
- Feature completeness. See picoJava, 27,500 logic cells, cancelled.

## Scope of v1

**In:** atoms, 32-bit fixnums, tuples, lists, PIDs, funs, `spawn`, `send`,
selective `receive` with timeout, `link`, `monitor`, `exit`, `trap_exit`,
registered names, a reduction budget, per-engine copying GC.

**Out:** floats, bignums, maps, binaries and bitstring syntax, distribution,
hot code loading, ETS, string handling beyond lists of small integers.

Every item in the "out" list will look tempting at some point. The answer is in
the README.
