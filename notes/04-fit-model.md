# 04 — The fit model

Bet 4: **the fabric's shape is a computed value.** Engine count, thread count,
heap depth and NoC topology are solved at elaboration from a LUT and BRAM
budget, by an ordinary Elixir function, then instantiated with `generate`.

This is the one place where writing the HDL in Elixir is not a preference but a
capability the alternatives don't have. An EHDL component body is *ordinary
Elixir, evaluated at compile time* — so a sizing solver isn't a code generator,
a Tcl script or a preprocessor pass. It's a function you call in the module
body, whose return value shapes the netlist.

## The solver

```elixir
# lib/pico_beam/fit.ex — plain Elixir. No macros, no HDL.
defmodule PicoBEAM.Fit do
  # Calibrated from one real nextpnr-ecp5 report at M2.
  # Until then these are estimates and the table below says so.
  @engine_lut      3_800
  @noc_lut_per_hop   420
  @infra_lut       6_500   # SDRAM ctrl, USB debug, name registry
  @ebr_bits       18_432
  @word               36

  def solve(luts, ebrs, opts \\ []) do
    threads = Keyword.get(opts, :threads, 4)
    heap    = Keyword.get(opts, :heap_words, 4096)

    per_engine =
      words_to_ebr(2 * heap)          # semispaces
      + words_to_ebr(512)             # mailbox
      + words_to_ebr(threads * 256)   # data + return stacks
      + 1                             # process table

    n = min(div(luts - @infra_lut, @engine_lut + @noc_lut_per_hop),
            div(ebrs - shared_ebr(),  per_engine))

    %{engines: n, threads: threads, heap_words: heap,
      topology: if(n <= 4, do: :crossbar, else: :ring),
      resident: n * threads, pid_engine_bits: bits_for(n)}
  end

  defp words_to_ebr(w), do: ceil(w * @word / @ebr_bits)
  defp shared_ebr, do: 20   # code ROM 15 + atom table 2 + misc 3
  defp bits_for(n), do: max(1, ceil(:math.log2(n)))
end
```

## The netlist follows the solution

```elixir
# designs/pico_beam/fabric.ex
defmodule PicoBEAM.Fabric do
  use Hw.Component

  @fit PicoBEAM.Fit.solve(84_000, 208, threads: 4)

  clock :clk, freq: 50.0
  input :rst, 1

  generate i <- 0..(@fit.engines - 1) do
    instance :"pe_#{i}", PicoBEAM.Engine,
      ENGINE_ID:  i,
      THREADS:    @fit.threads,
      HEAP_WORDS: @fit.heap_words,
      clk: :clk, rst: :rst,
      noc_in:  :"link_#{rem(i + @fit.engines - 1, @fit.engines)}",
      noc_out: :"link_#{i}"
  end
end
```

**Correction (2026-08-22, Probe B):** the sketch above does not parse.
EHDL's `generate` replicates only combinational statements (its body goes
through `Parse.parse_statements`), so `generate` over `instance` is
aspirational. The working mechanism is a plain compile-time `for`
comprehension — a component body is ordinary Elixir and module attributes
accumulate inside the loop:

```elixir
  for i <- 0..(@fit.engines - 1) do
    wire :"link_#{i}", 36
    instance :"pe_#{i}", PicoBEAM.Engine, ...
  end
```

Proven in `../ehdl/_prim/probe_b.exs`. Bet 4 needs no DSL work; the
original sketch is kept above so the correction has something to correct.

## Three operating points from one source

LFE5U-85F: 84K LUT4, 208 EBR. Shared overhead: 20 EBR (code ROM 15, atom table
2, misc 3), leaving 188 for engines.

| Fit | Engines | Ctx/eng | Heap words/eng | Resident procs | Total heap | EBR | LUT4 est. |
|---|---|---|---|---|---|---|---|
| `:deep` | 4 | 4 | 10,752 | 16 | 43,008 | 204 | ~23,400 · 28% |
| **`:balanced`** | **9** | **4** | **4,096** | **36** | **36,864** | **200** | **~44,500 · 53%** |
| `:wide` | 10 | 8 | 2,048 | 80 | 20,480 | 160 | ~54,700 · 65% |

### The arithmetic, so it can be checked

One EBR = 18,432 bits = 512 words of 36 bits.

**`:balanced`, per engine:**

```
heap    4,096 words × 36 b × 2 semispaces = 294,912 b = 16 EBR
mailbox   512 words × 36 b                =  18,432 b =  1 EBR
stacks  4 threads × 256 words × 36 b      =  36,864 b =  2 EBR
proc tbl                                              =  1 EBR
                                                        ------
                                                         20 EBR
9 engines × 20 = 180, + 20 shared = 200 of 208            ✓

LUT: 9 × 3,800 + 9 × 420 + 6,500 = 44,480 of 84,000 = 53%
```

**`:deep`:** 188/4 = 47 EBR each; mailbox 1 + stacks 2 + ptbl 1 = 4, so heap
gets 42 EBR = 774,144 b / 2 / 36 = 10,752 words. 4 × 46 = 184, + 20 = 204.
LUT: 4 × 3,800 + 4 × 420 + 6,500 = 23,380.

**`:wide`:** T=8, so stacks are 8 × 256 = 2,048 words = 4 EBR. Heap 2,048 words
× 2 × 36 = 147,456 b = 8 EBR. Per engine 8+1+4+1 = 14; 10 × 14 = 140, + 20 =
160. LUT at 4,400/engine (more context storage): 44,000 + 4,200 + 6,500 =
54,700.

### Reading the table honestly

- **EBR columns are arithmetic on the 18,432-bit block. They are firm.**
- **LUT columns are pre-synthesis estimates** extrapolated from Actora
  (1,087 ALM) and JOP (1,831 LC), and should be read as **±50% until M2
  produces a real nextpnr report.** M2 exists precisely to replace them.
- Same solver against an LFE5U-25F (24K LUT4, 56 EBR) shrinks the shared ROM and
  yields **3 engines with 2,048-word heaps**. That is the point of writing it
  this way.

## The loop worth closing

Once the cost model is calibrated: a `mix hw.fit` task that builds, reads
nextpnr's real utilisation report, rewrites the model constants, and re-solves.
The fabric then sizes itself against measurements rather than guesses.

## Two other EHDL features that land unusually well

- **`hdl_case` with `<<field::width>>` patterns** means the instruction decoder
  is *literally written as binary pattern matching* — which is what an ISA
  decoder is, and which every other HDL makes you spell out as a case over
  concatenated slices. (Mind the first-match-wins mux semantics; see
  `06-risks.md`.)
- **`defhw`** gives tag-check and tag-extract as inlinable one-liners used a
  hundred times across the datapath with no module boundary. (Mind the inlining
  fixpoint; see `06-risks.md`.)
