# 34 — The card, and a parameter that lied

`notes/26` bug 9, in full:

> **9. `sd_boot` — 525 lines, zero tests.** The microSD loader is the
> largest single component in the project and nothing has ever run it in
> a testbench.

It has run now. This note is about what it took, and about the thing
that was found on the way, which is worse than the bug being fixed.

## A card, in Verilog

`SdBoot` cannot be tested without something to talk to, so
`scripts/sd_card_model.v` is a microSD card in SPI mode: MOSI sampled on
the rising edge, MISO changed on the falling one, six-byte command
frames assembled from the bit stream, and responses queued a byte at a
time. It answers CMD0, CMD8, CMD55, ACMD41 and CMD17, and it is backed
by an image file so sector *S* is image byte `(S − LBA) × 512`.

ACMD41 reports "still initialising" **twice** before it reports ready. A
card that is ready on the first ask never exercises the CMD55/ACMD41
loop, and that loop is where a real card spends its first 50 ms.

The image is three sectors, also on purpose. `SdBoot`'s moduledoc has
claimed since M2 that the parser is sector-agnostic and that images
cross sector boundaries freely. Bundle 112 of this image starts at byte
1016 and ends at 1024 — the claim, made physical.

And the assertion is the strongest one available: every bundle and every
pool word that reaches the engine's loader side-door, compared word for
word against what `Encoding.image/2` produced for the same program. Not
"it finished". "It delivered the image."

## The lie

The first run took 1.5 million clocks and delivered 115 of 122 bundles.
The obvious read is "it needs more time", and the obvious fix is a
bigger cap. Both are wrong, and the arithmetic says so: 122 bundles is
about 1,100 image bytes, 256 clocks a byte, which is 290,000 clocks.
Where did the other 1.2 million go?

Into `PWRWAIT`. The testbench instantiated

```verilog
sd_boot #(.PWRWAIT(64), .LBA(8192)) dut ( ... );
```

and got 1,200,000 anyway.

**EHDL constant-folds `param` at elaboration.** By the time the Verilog
emitter runs, `PWRWAIT` is the literal `1200000` in twenty comparisons,
and the `parameter PWRWAIT = 1200000` line at the top of the module is
decorative — nothing references it. Overriding it in Verilog is
accepted without a murmur and changes nothing.

That is a silent wrong answer in the worst possible place: a testbench
that believes it shortened a 100 ms power-up wait and did not. It is the
same species as `notes/32`'s four-bit state field and `notes/15`'s
emitter widths — a thing that looks like it works, does not, and says
nothing.

## What to do about a parameter that cannot be overridden

Not "document it". EHDL now emits **`localparam`**:

```elixir
# Elaboration CONSTANT-FOLDS every `param` use... Emitting it as
# `parameter` advertises an override surface that does not exist.
"  localparam #{p.name} = #{p.default};"
```

The same override is now a compile error. The value is still there to
read; what is gone is the invitation to override it somewhere it cannot
take effect. Override params where they are meant to be overridden: on
the `instance`, before elaboration, which is where `BarrelEngine`
already sets `SeatUnit`'s budget and where it has always worked.

That is what `SdBootSim` is — `SdBoot` with `PWRWAIT: 64` and `HALF: 2`
on the instance, all ports passed through. Same source, a short power-up
wait, and an SPI clock that does not make the testbench simulate 375 kHz
for four sectors.

`HALF` is new. The SPI half-period was a hard 16 clocks (~375 kHz at
12 MHz, inside the 400 kHz identification-mode ceiling every card must
accept). It is a parameter now because the card model does not care how
fast it is clocked — the testbench needs the protocol to be right, not
slow — and because a board that wants to go faster after
identification will want it too.

## And it caught a second one immediately

Making the override loud broke two testbenches:

```
scripts/tb_m3_pass6.v:79: error: Cannot override localparam `BUDGET` in `tb.su`.
```

`tb_m3_pass6.v` has said **"Six processes, four seats, BUDGET = 8"** in
its header since M3, and has been running at 32 the whole time.
`tb_m3_pass7` likewise at 32 instead of 24. Both passed, because what
they assert — that swaps happen, that the queue keeps its waiters, that
no process ever reads another's registers — is true at any budget. They
were just never testing the number they named.

The fix is not another wrapper. `SeatUnit`'s budget is a **port** now:

```elixir
# The scheduler quantum, as a PORT and not a `param`. A wire costs a
# mux on the reload and cannot lie.
input :budget, 6
```

`BarrelEngine` drives it with 24, the two testbenches drive 8 and 24,
and for the first time those are the budgets that run. It is also
better design — the scheduler quantum is exactly the kind of thing a
real VM would want to set at runtime.

## What the loader turned out to be

Correct. Once it was given the time it thought it had, it read three
sectors, parsed a header, delivered 122 bundles and a pool word, and
stopped with `done` up, `busy` down and the card released — first run,
no changes to `sd_boot.ex` at all beyond the new `HALF`.

525 lines that had never executed, and they worked. That is a pleasant
outcome and not a vindication: the reason to test it was never a
suspicion, it was that nobody could say either way, and now the gate
says it every run.
