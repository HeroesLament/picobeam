# 21 — Fixed point: three bugs, one new op

`notes/20` wrote the Metronome as a picoBEAM program and the code
presented a bill. This is that bill, paid. The headline item was
`mul` returning zero. It was not the worst thing wrong.

## What the question found

The plan was "implement mul." Asking the ALU directly what it did — one
testbench, one case per line of `term.ex`'s fixnum contract — found
**twelve failures out of sixteen**, in three unrelated bugs.

`term.ex` has said since M1:

> Fixnums are signed 32-bit two's complement in the payload. Arithmetic
> that leaves that range TRAPS (exit reason `:overflow`) — it never
> wraps.

The ALU implemented none of it.

**1. Arithmetic ran through the tag.** `y = a + b` added the whole
36-bit word. `5 - 7` produced `0xFFFFFFFFE`: payload right, tag `0xF`,
a term that is not an integer and never was one. `-2 + 3` produced tag
`0x1` — the answer, wearing the ATOM tag.

**2. Comparisons were unsigned.** `cmplt` compared whole words, so
`-2 < 3` was **false**. And `cmplt`/`cmple` were outside the
tag-checked group entirely, although the model reaches them through
`int!` and traps on a non-integer.

**3. Overflow wrapped silently.** `INT_MAX + 1` gave `INT_MIN` with a
clean INT tag and no fault. `notes/09` consequence 4 named exactly this
case — *"silent wraparound in a motion controller is a safety hazard"* —
and filed it for M1. It had been open ever since.

None of it showed because every program the machine had run was
positive, small, and multiply-free. **`fib` is not a test of
arithmetic. It is a test of one quadrant of arithmetic.**

## And a fourth, upstream: atoms had no tag

Fixing the ALU exposed something older. ehdl's `build_expr({:const, n})`
hardcoded `width: 32`, so a 33-bit literal emitted as `32'd...` and
truncated. `0x100000000 + 14` — the ATOM word for `true` — reached the
netlist as `32'd4294967310`, which is `14`.

So the ALU produced a tagless `14` and the engine's `bift` compared
against a tagless `14`, and the two agreed. **Every atom in the machine
had been running untagged since M2, and `fib` passed because both sides
of every comparison truncated identically.** `istag` on an atom would
have said INT. Nothing had asked.

The fix is one line and the same species as the two ehdl width bugs
that came before it: a literal is now born at least 32 bits wide but
never narrower than its own value.

Recorded because the pattern is now three-for-three: **every silent
failure in this project has been an inferred width smaller than the
value it had to carry.**

## `mulsr`: multiply then shift, as one op

Fixed point needs `(a * b) >> k`. picoBEAM could express neither half:
`mul` returned zero, and the front end exposes `+ - * band bor bxor`
and comparisons and *nothing else* — no `div`, no `rem`, **no shifts at
all**, though the ISA has `shl` and ehdl uses it.

Adding a plain `bsr` would have fixed that badly. `a * b` would produce
a 32-bit fixnum that overflows before the shift runs, so every Q12
product would raise a spurious `overflow` and the only workaround is
pre-scaling away the precision you wanted. The two-op form cannot be
made safe.

Fusing them means **the 64-bit intermediate never becomes a term.** It
lives between the DSP tiles and the shifter; the overflow test applies
to the shifted result, which is the number the program meant. Fixed
point becomes safe by construction rather than by convention.

    mulsr rd, ra, rb, k        # rd = (ra * rb) >> k,  k in 1..16
    op 0x0C, four-field shape: rd=f1, ra=f2, rb=f3, k-1=f4

`k` is **biased by one** — encoded 0..15 means 1..16 — because a shift
of zero is just `mul`, so spending the code point on it would cost the
only value that reaches Q16, the format a 32-bit fixed-point machine
most wants after Q12.

The shift is an instruction field, not a value: a variable shift would
need a barrel shifter the ISA deliberately does not have, and the front
end raises rather than accepting a non-literal.

The ALU's `sel` widened from 4 to 5 bits. `mulsr` is sel 16 because
sels 0..15 were full — 0..11 are `Encoding`'s ALU nibble verbatim and
12/13/14/15 are `Classify`'s ldi/ldn/lda/pass extensions — and 0x0C's
own low nibble, 12, already names ldi's. Carving 0x0C out of the
group-0 term was cheaper than renumbering a table the testbench is
written against.

**One multiplier per slot, not two.** `mul` and `mulsr` share the whole
datapath: sign-magnitude operands into the DSP tiles, the product
negated back to two's complement, one arithmetic shift (distance 0 for
`mul`, `f4 + 1` for `mulsr`), one result slice, one range check. The
overflow rule is the same test for both — everything above bit 30 must
be sign extension — with no special case for `k = 0`.

## The trap inside the fix

`shk = is_msr * (imm[3..0] + 1)` was wrong, and wrong only for the
largest `k`.

`x + 1` takes **x's** width. `imm[3..0] + 1` is a four-bit add, so a
shift of 16 wrapped to 0 — a Q16 multiply silently became a Q0 one.
The randomised sweep caught it; the seven hand-written cases did not,
because I had written them at Q12.

This is not an ehdl bug. It is Verilog's self-determined width rule,
reproduced faithfully, and it is what a hardware engineer expects of
`n-bit + n-bit`. Unlike `mul` and `shl` — where the natural result is
genuinely wider and truncation was silent data loss — this one is the
language working as designed. The fix belongs in the expression: widen
`f4` to five bits *before* the bias.

Worth stating as a house rule: **in a `comb` block, `x + 1` wraps.**
Declare the intermediate at the width the value needs.

## Cost, measured

| | before | after | Δ |
|---|---|---|---|
| LUT4 (M4 top, post-pack) | 10,200 | 11,253 | +10.3% |
| MULT18X18D | 0 | **12** (3 slots × 4) | of 156 on the 85F |
| DP16KD | 46 | 46 | — |
| fmax | 24.5–27.1 MHz | **19.0–20.1 MHz** | −25% |
| cycles, B1–B6 | — | **identical** | — |

The multiply is combinational through four DSP tiles and the funnel
shifter is now the critical path. 20 MHz is still **1.67× the 12 MHz
the design runs at**, so nothing is at risk today — but the headroom
lever in `notes/18` ("clock 12 → 27 MHz, ×2.25 on everything") is now
worth less than it was, and the way to buy it back is to pipeline the
multiply into a two-cycle op. The barrel makes that nearly free:
`notes/10` already argues that a context waiting on a multi-cycle unit
simply does not fetch on its turn while the other T−1 lose nothing —
the same structural trick that dissolves the dirty-NIF problem. Costed,
not scheduled.

Every benchmark reproduces `notes/18` to the cycle — 12,020 / 12,228 /
10,508 / 8,752 / 10,820 / 201,252. The ALU is combinational, so
correctness cost no cycles at all.

## How it was checked

Three independent oracles, agreeing:

1. **`scripts/tb_alu_signed.v` — 120,024 checks, 0 failures.** Sixteen
   hand-written cases, one per line of the contract, then a 20,000-case
   randomised sweep of add/sub/mul/cmplt/cmple/mulsr against Verilog's
   own `$signed` arithmetic. That is a real cross-check: nothing in the
   netlist uses a signed type, so agreeing with `$signed` is agreement
   between two different implementations. Operands are clustered near
   `INT_MAX`/`INT_MIN` as well as spread, because that is where the
   overflow rule earns its keep.

2. **`scripts/tb_fixed.v` — gates against the model.** A full cubic
   Hermite kernel (`mk_fixed.exs`) runs on `machine.ex`, and *its*
   outputs are written as the expectation file. The testbench compares
   the netlist against the reference model rather than against anyone's
   arithmetic. Both produce `[0, 7562, 21500, 34687, 40000]`.

3. **Silicon.** Demo C on the ULX3S runs the same kernel and checks
   itself: the plain sum and the tick-weighted sum of the five results,
   each compared on-chip against what the model computes. The UART
   oracle reads `OO = a3` — both checks passed, fault bit clear.

## `scripts/run_tbs.sh` — the regression gate

New, and overdue. It emits every part, regenerates every image, and
runs all sixteen testbenches plus the six benchmarks in one command.

It earned itself immediately. The const-width fix touched every literal
in the project, and knowing within one command that thirteen functional
testbenches and six cycle counts were unchanged is the only reason that
change was safe to make.

It also found a drift that had been sitting there silently:
`mk_m3_image.exs` had been edited into the *board* demo — six workers
that spin forever — while `_emit/m3/demo_spawn.hex` still held the
eight-worker build `tb_m3_pass8` was written against. The artifact had
outlived its generator, and nothing noticed because nobody had
regenerated from source. Re-derived as `mk_m3_spawn8.exs`: one script,
one artifact, one testbench.

## Where this leaves `notes/20`

Of the six items that note billed the machine:

* ~~`mul` returns zero~~ — done, 12 DSP tiles.
* ~~`mulsr` as one op~~ — done, ISA through to the Elixir front end
  (`:erlang.mulsr(a, b, 12)`).
* ~~overflow must trap~~ — done, `notes/09` consequence 4 closed.
* **heap, tuples, and the M4 serialiser** — still open. This is next:
  `has_wb2` is tied 0 and neither Heap nor LitPool is instantiated, so
  `{:sp, node, pos, vel}` is not yet expressible.
* **ports** — still zero built. The largest remaining chunk.
* **`receive ... after N`** — still needs the per-context timer.

An axis process can now compute its setpoint. It cannot yet put it in
a message or hand it to a bus.

---

## Postscript, later the same milestone: the multiply was twice as big as it needed to be

The `mul` above is described as "sign-magnitude around an unsigned
32x32", on this reasoning:

> The unsigned product is a plain `*` so yosys maps it to MULT18X18D
> tiles rather than a LUT array.

That belief was wrong, and it cost more than it looked.

**The tiles do signed natively.** MULT18X18D has a signed mode; a
`$signed` multiply reaches the DSPs exactly as an unsigned one does.
EHDL can say so — `wire :spa, 32, signed: true` emits
`wire signed [31:0] spa`, and `*` between two such wires is a signed
multiply in the emitted Verilog.

**The scaffolding was on the critical path.** Sign-magnitude needed two
32-bit negates and two 32-bit muxes ahead of the multiplier, and a
64-bit negate and a 64-bit mux behind it. When `nextpnr` finally
reported the critical path in full, its sink was `alu0_mb`'s carry
chain — one of those negates.

Measured with `synth_ecp5`, per ALU instance, three instances in the
design:

| | sign-magnitude | signed | |
|---|---|---|---|
| cells | 1,791 | **1,414** | −21% |
| CCU2C carry chains | 234 | **106** | −55% |
| LUT4 | 1,155 | **903** | −22% |
| MULT18X18D | 4 | **4** | unchanged |

`tb_alu_signed`'s 120,045 checks are unchanged and still pass, which is
the point of having written them against the model rather than against
the implementation: the datapath under them was replaced wholesale and
the testbench did not need a line changed.

The risk worth naming, because it is the same family as every width bug
in this project: Verilog's context-determined widths mean
`assign p64 = a32 * b32` widens BOTH operands to 64 first. With
zero-extension yosys prunes the resulting partial products away; with
sign-extension it has more work to do and might not. It does — the DSP
count is identical — but that had to be measured, not assumed.

### Why this is worth a postscript rather than a quiet edit

The timing fix that had been on the list since `notes/16` was
"pipeline the multiply": add a register stage, accept a late
write-back, park the context. EHDL even has a `pipeline` macro with
automatic cross-stage delay balancing, which is the right tool for this
project's most persistent bug class.

None of that was needed. The cheaper move was to **delete** the logic
the timing report was pointing at rather than add registers around it —
and it was cheaper in every direction: no engine contract change, no
sequencer change, no new state, fewer cells, and an existing testbench
that proved it in thirty seconds.

`notes/18` said the combinational multiply was the critical path. It
was more nearly true to say that the multiply's *packaging* was.

### One cost, recorded honestly

The design got smaller and faster; the **simulation** of it got slower.
iverilog now evaluates a genuine 64x64 signed product where it used to
zero-extend a 32x32, and `tb_m3_top` — which pushes 33 ms of simulated
time through three ALUs to run the thousand-spawn demo — went from
under the gate's 300 s per-testbench cap to over it. Nothing was wrong;
the cap was reporting on itself. It is 900 s now.
