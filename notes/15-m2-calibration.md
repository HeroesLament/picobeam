# 15 — M2 calibration log

M2 is the milestone where `04-fit-model.md`'s ±50% guesses become synthesis
reports. This note is the running log: every entry is a real yosys/nextpnr
number from a probe in `lib/pico_beam/rtl/`, dated, with the design decision
it forces. Newest entries at the bottom; nothing gets rewritten.

Setup: ehdl is now a real dependency (`{:ehdl, path: "../ehdl"}` in
`mix.exs`; rustler pinned `~> 0.36.0` so Elixir 1.14 toolchains still build
the sim NIF). Probes emit Verilog via `scripts/probe_c.exs` and synthesize
via `scripts/probe_c.sh` (yosys `synth_ecp5`).

---

## Probe C, part 1 (2026-08-22) — the register window in flops

The component Q1 + Q4a made central: three frames of 16 × 36-bit registers
(current / staging / spill), only the top frame read-addressable, one-cycle
call exchange, background spill drain. Two port shapes:

| Variant | Ports | LUT4 | PFUMX | L6MUX21 | FF |
|---|---|---|---|---|---|
| `RegWindow` (LIW) | 6R 3W + 3 arg | **10,909** | 4,823 | 1,854 | 1,733 |
| `RegWindowNarrow` (seq-slot) | 2R 1W + 1 arg | **3,523** | 1,279 | 482 | 1,733 |

(yosys 0.x `synth_ecp5` cell counts, no pnr yet; FF = 3 × 16 × 36 + 5 as
expected. fmax needs an IO-shift wrapper — the raw unit has ~600 ports,
more than the 85F has pins — deferred to part 2.)

**The finding is blunt: the flop-array 6R3W register window costs more
than an entire engine's budget.** At the `:balanced` fit (9 engines on 84K
LUT4), one engine gets ~9.3K LUT4 *total*; the wide register file alone is
10.9K. Even the narrow shape is 3.5K — a third of an engine on registers
alone. Hand arithmetic (6 read ports × 36 bits × ~5 LUT4 per 16:1 mux-bit
≈ 6.5K, plus write-path muxing ≈ 2.6K) matches the measurement, so the
estimate method is validated even though the answer is unwelcome.

The LIW premium, isolated: 10,909 − 3,523 = **7,386 LUT4** for +4 read
ports, +2 write ports, +2 arg ports. That is what Q4a's "engine LUT
estimate rises; M2 measures by how much" turns out to mean in flops.

## What this does NOT decide

It does not kill the 3-slot bundle. It kills the *flop-array* register
file, which was always the naive baseline. The avenues, in the order worth
probing:

1. **LUT-RAM frames (probe C part 2).** ECP5 distributed RAM (DPR16X4)
   makes a 16-deep read an address decode instead of a 16:1 LUT mux —
   and the barrel makes this *better*, not worse: T contexts × k frames
   is just RAM depth, nearly free, where the flop design multiplies its
   10.9K by T. Multi-read = replication (one copy per read port);
   multi-write = 3 banks + a live-value table (64 × 2-bit in flops).
   Estimated well under half the flop cost; the probe will say.
2. **Measure real port pressure.** The bundle contract *allows* 6R3W;
   erlc-generated code may rarely pack it. The M1 front end + assembler
   exist, so the corpus in `test/` can be analyzed for actual
   reads/writes per bundle. If the 95th percentile is ≤ 4R2W, a
   restricted encoding (slot 3 single-operand, say) buys most of the LIW
   for a fraction of the multiport.
3. **Accept the narrow shape** (sequential slot issue, three microcycles
   per turn) and re-derive the barrel arithmetic — the fallback that
   changes `12-parallelism-and-terms.md`'s axis-3 story.
4. **Fewer engines.** 4 engines × wide window = 44K LUT4 — the `:deep`
   fit absorbs it, at the cost of Bet 4's headline engine count.

Leaning: (1) + (2) together, because they compound and neither gives up
the bundle. The flop numbers above stay in the table as the measured
ceiling.

## Standing notes

- The emitted Verilog draws `Warning: wire '_case_N' is assigned in a
  block` from yosys — the emitter's hdl_case lowering; benign but worth
  an ehdl issue.
- Frame RAM (the spill drain's far end), heap, mailbox and code BRAMs are
  priced by Probe A already: one DP16KD each per 512 × 36. EBR is not the
  scarce resource at engine counts the LUT budget permits; LUT4 is.

---

## Scaffolding pass (2026-08-22) — the engine component tree exists

Structure, not measurement: `lib/pico_beam/rtl/` now holds the whole
engine as wired components — `Engine` (top) instantiating `Sequencer`
(phase FSM: boot/fetch/exec/call_wait/ret_fill/fault/halted, hand-rolled
`hdl_case`, single-driver by construction), `CodeMem` (512 × 72 sync
read — one fetch per bundle, two EBRs paired), `Decode` (field split),
`RegWindow` × its `FrameRam` frame stack (spill drain and pop-then-fill
wired), `Alu` × 3 (tag-checked, reserved-atom fault reasons; `mul`
stubbed pending a MULT18 probe), `Heap` (port-A bump allocator, both
semispaces in one EBR, port B declared and tied off for M4/M5), and
`LitPool`. The tree elaborates and emits (~1.3 MB flattened Verilog,
`scripts/emit_engine.exs`); everything pends on ONE missing piece, the
**opcode table** — binary op numbering shared with `Asm`, to be generated
from a single source into assembler and decoder both.

Two findings from the pass, both encoding-shaped:

1. **Two-register branches don't fit a 24-bit slot** (8 + 4 + 4 + 12 =
   28). Options in `Decode`'s moduledoc; leaning: assembler lowers
   `beq ra,rb,l` to `cmpeq` + `bift` by default (costs a slot, no ABI),
   with 8-bit-offset short forms as a later optimization once branch
   distances are measured over the erlc corpus.
2. **Frame stack depth:** one EBR = 32 frames, but the reference model
   allows rstack depth 64. Either the model's limit drops to 32 (and
   `:stack_overflow` fires earlier) or the frame RAM takes two EBRs.
   Cheap either way; decide when the opcode table lands.

---

## Opcode-table pass (2026-08-22) — the ABI exists and the engine decodes

`PicoBEAM.Encoding` is now the one source of binary truth: op byte =
`[group:4][sel:4]`, groups 0 ALU / 1 load-stage / 2 heap / 3 control /
4+ system — chosen so hardware classification is a nibble slice and the
ALU group's low nibble IS `Alu`'s micro-op select, no translation table
in gates at all. It encodes `Asm.assemble/1` output into 24-bit slots
and 72-bit bundles, and `image/2` flattens a whole program (entry-first
function layout, branch targets rebased, `call`/`spawn`/`tailcall`
atoms resolved to absolute bundle addresses) into a CodeMem image.
Smoke round-trip: `ldi/ldi/add/halt` encodes to
`1000051F…/1010071F…/0020101F…/5200001F…` — fields land where `Decode`
slices them.

Hardware side, wired live in `Engine` this pass: three `Classify`
instances (mirroring the table — the file says change Encoding first,
then it), per-slot write-back (`wr_alu AND exec_en` into the window's
three ports), the `rs_in_f1` read-address mux for rs+imm12 shapes,
`bift`/`biff` taken-detection against the reserved TRUE/FALSE words,
one-hot control aggregation across slots (sound because the bundle
contract already guarantees ≤1 system op), and the pc-target one-hot
sum. `Alu` grew sels 12/13 (`ldi` sign-extend, `ldn`), with sel 15 as
the never-faulting pass-through so non-ALU slots cannot alias `add`.

Encoding decisions taken (recorded in `Encoding`'s moduledoc):
`tailcall` classifies as a jump (window reuse IS a jump to the
sequencer); `spawn`/`call` arity is not encoded (clean-on-call: the
staging frame already holds the args); tuple indices are 8-bit slot
fields (`tset`/`tget`/`mktup` — v1 tuple arity ceiling 255 stands);
`fail` carries its reserved-atom index in imm12; bytes 0x31..0x34 stay
reserved where the two-register branches would have lived.

Still pending, in order: ret-fill write routing + `arg` staging strobes
(the call/ret data flow), the heap-op datapath (`wr_other` marks
`ldc`/`lda`/`self` waiting with it), and the CodeMem image-loading path
(memory `init:` is baked per-component at elaboration — a program-bearing
demo top needs either a generated component or the loader port).

---

## Call/ret data-flow pass (2026-08-22) — functions work in gates

The window machinery is now a complete calling convention:

- **Link bookkeeping lives with the frames.** FrameRam grew a second
  narrow memory, `rets` (32 × 13 = `pc:9|dest:4`), indexed by the SAME
  frame pointer — the model's rstack entry `{ret_pc, dest}`, kept in
  lockstep with its frame by construction rather than by protocol. One
  extra EBR-equivalent? No — 416 bits infers as distributed RAM.
- **Call:** dest register one-hot-summed from the call slot's f1; link
  = call bundle + 1; both captured on `call_commit`, which still waits
  only on the previous drain (`call_wait`). Call remains 1 committed
  cycle + 16 background drain cycles.
- **Ret:** a new `ret_wait` state (the spare FSM encoding) parks a fast
  returner until the caller's frame finishes draining — the
  fill-reads-what-drain-hasn't-written hazard is structural, and the
  wait is its structural fix. Then `pop`, an 18-cycle fill (indices
  0..15, one trailing cycle for the sync-read delay, one `dest_wr`
  cycle writing the exec-latched `ret_val` into the caller's dest), and
  pc redirect to the popped link. **Ret ≈ 19 cycles vs call's 1** — the
  asymmetry is honest (JOP pays it too; a hot-frame cache would attack
  it later) and belongs in the WCET tables when they get rewritten.
- **arg staging strobes** wired (`is_arg AND exec_en`); **tailcall** got
  its own window strobe (`op_tail`: promote staging, no push, no wait —
  to the sequencer it stays a jump).
- **Window port 0 is triple-duty** (ALU write-back / delayed fill
  stream / dest write) — phase-disjoint by the FSM, so the mux is a
  one-hot sum, not an arbiter.

Contract addition surfaced: `arg` or a register write sharing a bundle
with `tailcall` is suppressed by the window-reuse promote (model says
moot; hardware makes it so). `Asm` should reject `arg` in the same
bundle as `call`/`tailcall` — TODO, harmless today because the front
end never emits that shape.

---

## Heap-op pass (2026-08-22) — the heap speaks cells

The heap datapath is wired, and the design followed `notes/03` rather
than the model: **the RTL heap is CELL-addressed** — two 36-bit banks
(even/odd word of every cell), 256 deep each, two semispaces of 128
cells. That one choice keeps every heap op single-access: `cons` is
allocate + write-both-banks in ONE cycle (the 1-cycle-allocation claim
survives the port), `tset`/`tget` hit one bank via word parity (the
byte-enable trick, no read-modify-write), and a tuple is
`{HDR|arity, e0}, {e1, e2}, …` with element i at word i + 1.

The machinery: heap ops present a micro-command whose code is the op
byte's low 3 bits VERBATIM (the encoding table was arranged so —
another no-translation decode); operands gather one-hot from the heap
slot's ra/rb ports. Because bank reads are sync, results arrive one
cycle late, so the sequencer grew a ninth state, **wb2** (state
register widened to 4 bits): exec latches the routing (`hs_*`), wb2
lands the result through window port 0 — now a FIVE-source one-hot mux
(ALU wb / fill / dest / heap-late / pool-late), still no arbiter
because the FSM keeps every source phase-disjoint. A bundle may carry
a heap op AND a system op, so exec latches the pending control
decision and wb2 re-dispatches it. `ldc` rides the same late path
(pool reads are sync too); `lda` turned out to be pure and joined the
ALU as sel 14. At M2 a heap op costs exec + wb2 = 2 cycles; the M3
barrel overlays other contexts on the wb2 slot.

Faults are comb at exec: `bad_tag` (wrong-tagged pointer into
hd/tl/tget/tset/tarity) and `heap_full` (bump would cross the
semispace), both suppressing writes and the bump. The ehdl
one-write-site-per-memory constraint is honored by funneling all
writers through one one-hot write per bank.

**Recorded divergences and decisions:**

1. **Model vs RTL addressing.** `Machine` addresses the heap in words;
   the RTL addresses cells, as `notes/03` specified. The model is the
   one that moves at co-simulation time — cell addressing is the
   architecture, word addressing was a modeling convenience.
2. **tset's index ceiling is 15 in v1 hardware** (it needs two register
   reads, so the index dropped to the 4-bit f4 field; `tget` keeps 8
   bits). `Encoding` refuses larger; the model's 255 stands until the
   co-sim reconciliation.
3. **One late writer per bundle** (heap op XOR `ldc`) is a new contract
   shape for `Asm` to enforce; the engine guards the port-0 sum anyway.
4. **`self` deferred to M3** — it needs a process identity, which is
   the proc table's job.

---

## Image-loading pass (2026-08-22) — a real program in a real top

`PicoBEAM.RTL.DemoFib` closes the sequential loop: the fib program
(hand-assembled, branches lowered to `cmplt`+`bift` per this log's
first entry) runs through `Asm.assemble` and `Encoding.image` AT ELIXIR
COMPILE TIME into a module attribute, lands in a 32×72 top-level ROM,
and a boot FSM streams it through the Engine's new **loader side-door**
(`ld_code_*`/`ld_pool_*` write ports on CodeMem/LitPool) while the
engine is held in reset — released one cycle after the last delayed
write. This is `notes/11`'s boot design in miniature: at M8 the SD
loader replaces the ROM; the side-door and the hold-in-reset contract
stay. CodeMem itself remains generic — no program is ever baked into a
library component.

`out` became real RTL for the witness: op 0x51 (an `rs_in_f1` shape,
so the value was already on the ra port), one strobe + 36-bit port on
the Engine; the demo latches the low byte onto `led`. fib(10) = 55 =
`0b0011_0111`, `done` on halt, `bad` on fault.

The demo image: 18 bundles, engine top emits at ~1.35 MB Verilog, the
ROM's `initial` block carries the encoded words (`rom[0]` decodes back
to `ldi r0,10 | nop | nop` by hand — the ABI round-trips).

**The verification blocker is now named.** This top is memories all
the way down, and the EHDL simulator cannot execute MemWrite
(`../ehdl/AGENTS.md`, known gap, previously "constrains M2"). It now
BLOCKS M2's co-simulation: the engine cannot be run against the
reference model until either (a) sim MemWrite lands in ehdl, or (b)
the Rust NIF backend (`Hw.Sim.Backend.Nif`) is wired up and handles
it. Synthesis is unaffected. This is the top of the M2 verification
queue and an ehdl-repo work item, not a picobeam one.

---

## THE CALIBRATION RUN (2026-08-22) — the fit model's first real rows

`scripts/calib_m2.sh`: yosys `synth_ecp5` on both tops, nextpnr-ecp5
--85k on the demo. ~143 s wall on the dev machine.

| Design | LUT4 | PFUMX | L6MUX21 | FF | DP16KD | MULT18 | CCU2C |
|---|---|---|---|---|---|---|---|
| `engine` (standalone) | **10,977** | 2,414 | 722 | 2,349 | 7 | 6 | 316 |
| `demo_fib` (full system) | **8,088** | 1,845 | 771 | 1,304 | 4 | 4 | 131 |

nextpnr on `demo_fib`: **9% of the 85F** (8,088/83,640 logic LUTs),
**fmax 27.5–34.4 MHz against the 50 MHz target — FAIL**, routed and
completed otherwise.

### Readings, in order of importance

1. **The whole engine costs ~11K LUT4 — barely more than the Probe C
   flop register file alone (10.9K).** In context, cross-boundary
   optimization shrinks the regfile (the probe's 600 free-running ports
   forced every mux to exist; inside the engine the addresses are
   correlated and dead read paths prune), and everything else —
   sequencer, decode, 3 ALUs, heap unit, classify — rides in the
   optimization slack. The regfile is confirmed as THE cost center:
   the LUT-RAM/LVT rebuild remains the single highest-value change,
   with the whole-engine target of ~4–5K LUT4 that would put 9 engines
   at ~45K and make the `:balanced` fit real. At today's number: 7
   engines ceiling, before any ring/NoC cost.
2. **fmax 27–34 MHz.** Expected shape for an unpipelined first pass:
   the M2 FSM deliberately does bundle→decode→classify→addr-mux→16:1
   regfile read→tag-checked ALU→port-0 one-hot sum in ONE exec cycle
   (~36 ns of logic). The M3 barrel is the designed fix — fetch/decode/
   execute split across pipeline stages with no bypass because of
   rotation — so this number should be read as "the un-barreled
   engine", not the architecture's ceiling. Not chasing timing now.
3. **Six MULT18X18D with `mul` stubbed to zero:** yosys mapped some of
   the `1-bit-condition * 36-bit-value` one-hot-sum idioms onto DSP
   tiles. Functionally fine, but DSPs in mux paths cost timing and
   tiles; the idiom wants an AND-mask lowering (emitter or style fix —
   an ehdl-side item). Likely a contributor to (2).
4. **DP16KD count:** engine = 7 (code×2 @ 72-bit, h0, h1, frames,
   pool, rets) — the `rets` link store block-rams at 32×13, which is
   wasteful; a `sync_read: false` distributed version is a one-line
   improvement to try. demo prunes to 4 (fib uses no pool; unused
   readers dead-code their memories).
5. `04-fit-model.md`'s constants are NOT being rewritten yet — the
   regfile rebuild would churn them immediately. They get rewritten
   once, after it.

---

## Probe C part 2 (2026-08-22) — pointer-renamed LUT-RAM windows: 6.3×

`PicoBEAM.RTL.RegWindowRam` replaces the flop window in the engine
(the flop version stays in-tree as the measured baseline). Two ideas
carry it:

1. **Frames live in LUT-RAM at native DPR16X4 depth** (16 words), so
   the 16:1 read muxes the flop design paid ~6K LUT for become RAM
   addressing. Multi-write is 3 banks (one per unified write port —
   a bundle's ≤3 ops each carry at most ONE write, result-to-current
   or arg-to-staging, so 3 ports replace the flop design's 9) × 7 read
   replicas (6 bundle reads + the drain), LVT as one 128-bit register
   indexed by variable shifts instead of a mux forest.
2. **`call` renames instead of copying.** cur/stg/spl are 2-bit slot
   pointers into a 4-slot pool per context; call rotates them — the
   old current drains IN PLACE, the old staging IS the new window, the
   drained slot becomes fresh staging. Tailcall swaps cur/stg. The
   576-bit exchange muxes are simply gone. Address layout is
   `{ctx, slot, reg}`, so T multiplies RAM DEPTH, not mux width — the
   context-indexed property the flop design could never have.

| Design | part 1 (flops) | part 2 (RAM) |
|---|---|---|
| window standalone | 10,909 LUT4 / 1,733 FF | **1,728 LUT4 / 72 FF** + DPR16X4 |
| engine | 10,977 LUT4 / 2,349 FF | **5,269 LUT4 / 688 FF** (+276 DPR16X4) |
| demo_fib (pnr) | 8,088 = 9% | **3,523 = 4%** + 276 DPR16X4 |
| demo fmax | 27.5–34.4 MHz | 24.4–30.6 MHz |

Readings: the window is no longer the engine's cost center (~6.3×
standalone; engine halved). **At ~5.3K LUT4 + DPR per engine, 9
engines ≈ 50K of 84K — the `:balanced` fit is arithmetically alive
again**, with the ring, mailboxes and collector still to pay for out
of the remainder. fmax dipped slightly (async RAM read + LVT shift +
bank mux now sit in the exec path) — the barrel's pipeline split
remains the designed fix, and the MULT18-in-mux idiom is still
unfixed and on the ehdl list. Engine FF count fell 3.4× (frames left
flops), which also shrinks every future context's cost.

The emitted Verilog dropped 1.35 MB → 178 KB — the mux forests are
gone at the source level, not just after synthesis.

---

## THE MVP BITSTREAM (2026-08-22) — picoBEAM boots from microSD

`_emit/ulx3s/picobeam.bit` exists: the engine + `SdBoot` (SPI-mode SD
init, CMD17 sector reads from LBA 8192, streaming image parser into
the loader side-door) + PLL (25 → 12 MHz exact: CLKOS = 432/36) on
the real ULX3S pinout (`priv/ulx3s_pb.lpf`, picobeam's own minimal
LPF; SPI mode needs no tristates — sd_cmd/sd_d0/sd_d3 as plain pins).

| | |
|---|---|
| Full system | 5,786 LUT4 + 378 DPR16X4 + 1,016 FF + 7 DP16KD + PLL |
| Timing | 23.3–29.4 MHz ≥ 12 MHz target — **PASS, ~2× margin** |
| Bitstream | 425,619 B (`ecppack --compress`) |
| SD image | `scripts/mk_image.exs` → `fib.img`, 1 sector, dd at seek=8192 |

Boot chain in miniature (`notes/11` proven in shape): power-wait →
80 idle clocks → CMD0/CMD8/ACMD41 (SDHC assumed; v1 cards error code
2) → CMD17 loop feeding a sector-agnostic byte parser (magic "pBM1",
counts, 9-byte bundles, 5-byte pool words) → side-door writes → engine
released from reset. LEDs: loader `{busy, err, state}` during boot,
the program's `out` byte after (fib(10) = 55 = 0b0011_0111), frozen
error+state on failure. FIRE1 re-runs boot.

**The bug that almost shipped, and who caught it:** the parser's
per-item byte counter was declared 3 bits against a 9-byte bundle;
`pidx == 8` was unsatisfiable, so yosys proved the code memory
write-dead, deleted it, and X-propagated the ENTIRE engine out of the
netlist — first build was 315 LUTs of SD FSM and nothing else. The
synthesizer acted as a bounded model checker; the counterexample was
the cell count. Lesson for the log: a collapsed LUT total is a proof
about your design, and the sweep chain (const → dead write → deleted
memory → X reads) is worth tracing rather than blaming the tool.
Diagnosed via staged `synth_ecp5 -run` bisection; also of note:
`memory_libmap`'s mapping list is the fastest census of which
memories survived.

Two ehdl elaborator fixes landed en route (both in `../ehdl`,
uncommitted): instance memories' `sync_read` clock names now remap
through the instance clock binding (child `:clk` under a parent's
`clk: :clk_12`), and top-level `on` blocks may clock on PLL-output
wires (synthetic clock entry, mirroring `map_child_clocks`). Without
these, no PLL-clocked design with BRAMs inside instances elaborates.

NOT yet done: running it on the physical board (bitstream + card
image are ready; `fujprog _emit/ulx3s/picobeam.bit`, dd the image,
watch led). No simulation backs this RTL (the MemWrite gap), so
first power-on IS the first execution of SdBoot — set expectations
accordingly; the LED state/error encoding exists precisely for that
debug session.

---

## FIRST SILICON (2026-08-22/23) — fib(10) = 55 on the ULX3S

It runs. `p004 6 b 00 00b 003 f 1 37 ff` on the debug UART: halted at
pc 4, no fault, final ret link 003, **out byte 0x37 = 55**, LEDs
0,1,2,4,5 steady. The road there was four distinct hardware bugs, and
the methodology matters more than any of them.

### The debug UART oracle

LED ping-pong (human reads 8 bits, relays them back) saturated fast.
`DbgUart` (Hw.UART.TX at 115200 on the FTDI pin the board calls
`ftdi_rxd`) streams a ~15 Hz ASCII snapshot line:

    pPPP S F RR AAA LLL C O OO WD

pc · seq state · flags{halt,fault,ready,out_seen} · fault reason ·
first ret target · last ret target · ret count · out count · then
three REBINDABLE fields (OO/W/D). Each iteration of the loop rebinds
those to whatever question is open — the probe moves, the line format
doesn't. Capture on macOS needs the hold-open trick (stty settings
drop when the device closes):

    exec 3<>/dev/cu.usbserial-D01477 && stty -f ... 115200 ... &&
      timeout 3 cat <&3 | head -c 150; exec 3<&-

### Bug 1: registered commit pulses (sequencer)

First call/ret probe: ret jumped to 6, not 3 (`rt1` field). The
call_commit/pop_en pulses were REGISTERED, consumed one cycle after
the state-3 edge where pc_r redirected — FrameRam captured
callee_pc+1 and a garbage dest. Fix: commit pulses are combinational
(`band(state == 3, window_ready)`), sampled the same edge the FSM
commits. probe_c then returned 7.

### Bugs 2+3: the emitter width rules (ehdl, the big ones)

fib(10) ran, halted, links perfect — and returned 0. Value-chain
probes (`lrv` last ret value, `fnz`/`snz` nonzero fill/spill counts,
then `frv` first ret value, `rvnz` nonzero-ret count) narrowed it:
first ret carried 1, every later ret carried 0, spills nonzero. The
kill shot came from **iverilog on the emitted netlist** (`demo_fib`
has no PLL, memories zero-init like LUT-RAM: sim matched silicon
exactly, 0x00 out) — full visibility beats 15 bytes/line:

* **`a * b` emitted at width `max(wa, wb)`** — Verilog's
  self-determined rule, but a product needs `wa + wb`. FrameRam's
  `fp * 16` wrapped mod 64 on the fill side and `spill_slot * 16`
  wrapped mod 32 on the spill side — TWO DIFFERENT truncations, so
  frames drained to one address and filled from another: every
  restored frame past depth 1 was zeros. (The window's own `cur * 16`
  truncated consistently on both sides — self-consistent aliasing,
  which is why probe_c at depth 1 passed.)
* **`a <<< b` emitted at width `max(wa, wb)` = 32** — the register
  window's LVT masks (`3 <<< (wf * 2)` against the 128-bit LVT) were
  zero for word addresses ≥ 16: bank bookkeeping for frame slots 1–3
  never happened, so reads returned the wrong bank's stale words.
  After the mul fix alone, fib returned 178 = 2·fib(11) — every leaf
  saw n from the wrong bank. The rule now: shl width =
  `wa + max_shift` (const shifts exact, variable `2^wb − 1`, capped),
  with const operand widths taken from the VALUE, pre-inflation —
  the first honest version (4096-bit cap) wedged the device's yosys
  in CHECK for 10+ minutes; tight bounds cost nothing and synthesize
  in 33 s.

Both fixes are in ehdl's `expr.ex` beside the earlier single-bit-index
fix — three emitter width/indexing bugs found by this one design, all
of the same species: the emitted Verilog is legal, synthesizable, and
wrong. iverilog's "constant truncated" warnings flagged a fourth
(oversized `32'd...` literals for 33-bit atom constants — truncated
IDENTICALLY by yosys and iverilog on both write and compare sides, so
self-consistent and benign today; logged, not yet fixed).

### The loop, closed

Container: edit → `mix run scripts/emit_engine.exs` → iverilog TB
(wire→reg patch for `_case_*`, zero-init memories) until green →
commit files to the Mac → tmux: `bash scripts/build_ulx3s.sh &&
fujprog` → serial capture → read the line. Sim-to-silicon agreement
was exact at every step, including both failure modes. fib(10)=55
first appeared in iverilog at t=73015000 and on the board the same
hour.

M2 exit criterion — "a real program through the whole machine on real
hardware" — is met.
