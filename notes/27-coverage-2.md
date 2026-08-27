# 27 — Coverage, measured again

`notes/23` counted coverage this morning. A lot moved in between —
supervision landed, the deserialiser was integrated, a real Erlang
module ran, three bugs and an EHDL bug were fixed — so this is the
same count taken again, the same way, so the two can be compared.

Taken 2026-08-24, after the timer pipeline.

## The gate

`scripts/run_tbs.sh` — **37 runs, all green** (was 31).
`mix test` — **44 tests, all green** (unchanged).

The per-testbench timeout is 900 s now, not 300: the signed multiply
makes iverilog evaluate a real 64×64 signed product, and `tb_m3_top`
crossed the old cap while passing every assertion. `notes/21`'s
postscript has that story.

## Opcodes: 43 of 52 have executed, up from 32

Measured the same way — decode every `.hex` image any testbench loads,
collect the op bytes that actually appear.

**Executed (43).** add arg biff bift call cmpeq cmplt cmpne cons exit2
fail halt hd istag jmp lda ldc ldi ldn link mktup monitor mov mul mulsr
nop out recv_peek recv_skip recv_start recv_take recv_wait recv_waitt
ret self send spawn sub tarity tget tl trapexit tset

**Not executed (9).**

| op | state |
|---|---|
| `band` `bor` `bxor` `cmple` | unit-tested in `tb_alu_signed` against the model; no program has run one |
| `recv` | deliberately refused by `Encoding` — the fused form does not exist in hardware |
| `recv_hash` `tailcall` `unlink` `yield` | wired into the engine, never executed anywhere |

The eleven that closed since this morning are the whole supervision
set plus the heap and literal-pool ops: `ldc` `fail` `link` `monitor`
`exit2` `trapexit` `recv_waitt` `recv_skip` `cons` `hd` `tl` and the
tuple family, all of them driven by real programs rather than by a
strobe test.

The four ALU micro-ops are the cheapest thing on this list — one
bitwise demo image closes them. `tailcall` is the one that matters:
it is load-bearing for any Erlang loop and `PicoBEAM.Erl` does not
emit it, so nothing will exercise it by accident.

## RTL modules: 23 of 33 exercised, up from 18 of 31

**Newly covered today: `dbg_uart`.** `scripts/tb_dbguart.v` recovers the
115200 8N1 bit stream off `txd`, reassembles the line and compares it
against the string the format promises. It is the only part of this
machine a person looks at directly and it had never been tested — which
is exactly how its format string came to claim a field was the fault
reason while the board wired that field to occupancy.

**`ser_unit` is exercised but not integrated.** It passes `tb_ser` and
`tb_roundtrip` against the oracle, and `BarrelEngine` does not
instantiate it. That is `notes/26` bug 1, and it is the reason the
design's module list has twenty entries where it should have
twenty-one.

**The ten that are not exercised (3,056 lines):**

* `sd_boot` (525) and `sd_tb` (53) — the SD loader, written, never
  simulated end to end. Still the largest genuinely untested thing.
* **2,478 lines of dead M2 code** in eight modules — `engine` (730),
  `reg_window` (492), `sequencer` (268), `reg_window_ram` (260),
  `reg_window_narrow` (246), `ulx3s_top` (236), `demo_fib` (139),
  `frame_ram` (107). Every one superseded by an M3 replacement. This
  number has not moved since `notes/23` and it is a decision nobody has
  made, not a gap anybody has to close.

## The model, and one number that is worse than it looks — and one that is worse than it reads

`mix test --cover` says **69.81 % total**. Ignore that number. It
averages in every `PicoBEAM.RTL.*` module at 0 %, and those are
declarative hardware descriptions exercised by iverilog, not by
ExUnit — line coverage of a `comb do` block means nothing.

The modules the number is actually about:

| module | coverage |
|---|---|
| `Term` | 93.10 % |
| `Asm` | 87.69 % |
| `Machine` | 86.76 % |
| `Serial` | 86.49 % |
| `ISA` | 84.00 % |
| `Erl` | 61.54 % |
| **`Encoding`** | **0.00 %** |

### `Encoding` has no tests at all

Not "low coverage" — **zero references to it anywhere in `test/`**.

It is not unexercised: every image the gate runs came out of
`encode_slot/1`, and those images produce correct behaviour on the
netlist, which is a strong end-to-end check on the paths programs
happen to take. But nothing asserts that a given slot tuple maps to a
given 24-bit word, and none of its nine `raise Error` paths — the tset
ceiling, the unencodable slot, the image-too-large check, the refusal
of `recv` — has ever been run.

Pair that with `Erl` at 61.54 %, whose fifteen `unsupported` refusals
are also untested (`notes/26` bug 8), and the shape of the gap is
clear: **the front end is well tested on what it accepts and untested
on everything it rejects.** A refusal that crashes, or worse emits
something, would not be caught today.

That is new since `notes/23`, which measured `Erl` and did not think to
look at `Encoding`.

## Still true, and still the honest caveat

Everything from `notes/22` onward — the serialiser, the deserialiser,
links, monitors, trap_exit, timers, the heap, `sup.erl` — is
synthesised into the current bitstream and **has never executed on the
chip**. Sim and silicon have agreed at every step of M2–M4 including on
two bugs. That is a track record, not a proof.

## What would close the most, per hour spent

1. **One bitwise demo image** — closes `band` `bor` `bxor` `cmple`,
   taking opcodes to 47 of 52. An hour.
2. **A unit test file for `Encoding`** — round-trip every slot shape
   through `encode_slot/1`, and assert each refusal raises. Closes the
   largest genuinely untested surface in the model.
3. **`tailcall`** — emit it from `PicoBEAM.Erl` for self-recursive
   tail calls, which is the case every Erlang loop is. Closes an
   opcode and fixes a real front-end gap at the same time.
4. **Flash the board.** Nothing above substitutes for it.
