defmodule PicoBEAM.RTL.Alu do
  @moduledoc """
  One bundle slot's pure datapath. Instantiated three times by the engine.

  Term-aware: operands are 36-bit words, `[tag:4][payload:32]`.

      sel  0 add   1 sub   2 mul   3 band  4 bor   5 bxor
           6 cmpeq 7 cmpne 8 cmplt 9 cmple 10 istag 11 mov
           12 ldi (imm12 sign-extended)  13 ldn (NIL)  14 lda (ATOM)
           15 pass  16 mulsr

  Sels 0..11 are `PicoBEAM.Encoding`'s ALU-group low nibble verbatim;
  12/13/14 are `Classify`'s extensions for the loads the ALU serves.
  The op-select input is a local micro-op, NOT the ISA opcode.

  ## The fixnum contract (`term.ex`, `notes/09` consequence 4)

  > Fixnums are signed 32-bit two's complement in the payload.
  > Arithmetic that leaves that range TRAPS — it never wraps.

  Until the fixed-point pass this component implemented none of that.
  It added and subtracted the WHOLE 36-bit word, tag included, so
  `5 - 7` produced `0xFFFFFFFFE` — payload right, tag 0xF, a term that
  is not an integer. It compared whole words unsigned, so `-2 < 3` was
  false. `INT_MAX + 1` wrapped silently to `INT_MIN`, which `notes/09`
  names as a safety hazard in a motion controller in as many words. And
  `mul` returned zero.

  None of it showed, because `fib` is positive, small, and multiply-free
  — the shape of every program the machine had run. `scripts/tb_alu_signed.v`
  is the testbench that asks the question directly, one case per line of
  the contract above.

  So: arithmetic happens on the 32-bit PAYLOAD and the tag is rebuilt,
  never carried through the adder.

  * **add/sub** use the classic two's-complement rule — a sum overflows
    iff the operands agree in sign and the result disagrees with them;
    a difference overflows iff they disagree and the result disagrees
    with the minuend. 32-bit datapath, one XOR-AND per op, no widening.

  * **mul** is one signed 32x32. The payloads are read through
    `signed:` wires, so `*` is a signed multiply and yosys maps it to
    MULT18X18D tiles in signed mode. The full 64-bit product exists
    only to be range-checked — the result is its low half — and it
    NEVER becomes a term, so the overflow test applies to the number
    the program meant rather than to an intermediate.

    This used to be sign-magnitude around an UNSIGNED multiply — negate
    the negatives, multiply, negate the result if the signs differed —
    on the belief that only an unsigned `*` would reach the DSP tiles.
    It was wrong twice over. The tiles do signed natively, and the
    scaffolding was expensive: two 32-bit negates and two 32-bit muxes
    ahead of the multiplier, a 64-bit negate and a 64-bit mux behind
    it. `nextpnr`'s critical-path report named one of those negates
    (`alu0_mb`'s carry chain) as a sink. Deleting the lot costs one
    signed declaration and, per ALU instance, saves **128 of 234 carry
    chains and 254 of 1,155 LUT4** at identical DSP count — measured
    with `synth_ecp5`, with `tb_alu_signed`'s 120,045 checks unchanged
    and still passing.

    The lesson is the one `notes/21` already recorded from the other
    direction: this datapath's costs come from what surrounds the
    arithmetic, not from the arithmetic.

  * **cmplt/cmple** bias both payloads by flipping bit 31 (one XOR),
    after which an unsigned compare IS a signed compare.

  * **cmpeq/cmpne** stay whole-word, any term — that is the model's
    semantics (`machine.ex` compares words, `int!` is only reached by
    cmplt/cmple), and it is why `needs_int` is not simply `sel < 10`.

  ## `mulsr` — multiply then arithmetic-shift-right, as ONE op

  Fixed point needs `(a * b) >> k`, and picoBEAM could express neither
  half: `mul` returned zero and the front end exposes no shift at all.
  Adding a plain `bsr` would have fixed it badly — `a * b` would produce
  a 32-bit fixnum that overflows before the shift ever runs, so every Q12
  product would raise a spurious `overflow` and the only workaround is
  pre-scaling away the precision you wanted.

  Fusing them means the 64-bit intermediate NEVER becomes a term: it
  lives between the DSP tiles and the shifter, and the overflow test
  applies to the shifted result — the number the program actually meant.
  Fixed point becomes safe by construction rather than by convention.

  `k` rides the slot's f4 nibble, which is `imm[3..0]`, biased by one:
  the encoded 0..15 means a shift of **1..16**. A shift of zero is just
  `mul`, so spending the code point on it would waste the only value
  that buys Q16 — the format a 32-bit fixed-point machine most wants
  after Q12.

  Both multiplying ops share one datapath. `sel` selects the shift
  distance (0 for `mul`, `f4 + 1` for `mulsr`) and everything after the
  DSP tiles — the shifter, the range check, the result slice — is
  common. One multiplier per slot, not two. Since the product is signed
  the shift is a plain `shra` on it, with no sign to reapply.

  Faults: `badarith` (reason 3) when an op that needs integers got
  something else, `overflow` (reason 5) when the result left the signed
  32-bit range. badarith wins — a bad operand makes the overflow
  question meaningless.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :sel, 5
  input :a, 36
  input :b, 36
  # istag's immediate tag operand
  input :tag_imm, 4
  # the slot's imm12, for the ldi/lda micro-ops
  input :imm, 12

  output :y, 36
  output :fault, 1
  # reserved-atom index for the exit reason (Term.reserved_atoms order)
  output :fault_reason, 8

  wire :tag_a, 4
  wire :tag_b, 4
  wire :ints, 1
  wire :needs_int, 1
  wire :bad, 1

  # payloads and their sign bits — the only things arithmetic touches
  wire :pa, 32
  wire :pb, 32
  wire :sa, 1
  wire :sb, 1

  wire :r_add, 32
  wire :r_sub, 32
  wire :ovf_add, 1
  wire :ovf_sub, 1

  # signed multiply, shared by mul and mulsr. `spa`/`spb` exist only to
  # give the payloads a SIGNED type: the bits are `pa`/`pb` unchanged,
  # and the declaration is what makes `*` a signed multiply in the
  # emitted Verilog rather than an unsigned one.
  wire :spa, 32, signed: true
  wire :spb, 32, signed: true
  wire :sp, 64, signed: true
  wire :is_msr, 1
  wire :shf, 5
  wire :shk, 6
  wire :sw, 64
  wire :r_mul, 32
  wire :hi33, 33
  wire :ovf_mul, 1

  # bias-flipped payloads: unsigned compare == signed compare
  wire :ka, 32
  wire :kb, 32

  wire :ovf, 1

  comb do
    tag_a = a[35..32]
    tag_b = b[35..32]
    ints = band(tag_a == 0, tag_b == 0)

    pa = a[31..0]
    pb = b[31..0]
    sa = a[31]
    sb = b[31]

    # ---- add / sub: 32-bit wrap plus the two's-complement overflow rule
    r_add = pa + pb
    ovf_add = band(sa == sb, r_add[31] != sa)

    r_sub = pa - pb
    ovf_sub = band(sa != sb, r_sub[31] != sa)

    # ---- mul / mulsr: one signed multiply on the DSP tiles, then ONE
    # arithmetic shift and ONE range check serving both ops.
    #
    # The exact 64-bit signed product. It is a wire, never a term — the
    # whole point of fusing the shift into the op.
    spa = pa
    spb = pb
    sp = spa * spb

    # shift distance: 0 for `mul`, f4 + 1 (so 1..16) for `mulsr`
    is_msr = sel == 16
    # f4 widened to 5 bits BEFORE the bias is added: `x + 1` takes x's
    # own width (Verilog's self-determined rule, which ehdl reproduces
    # faithfully), so `imm[3..0] + 1` is a 4-bit add and a shift of 16
    # would wrap to 0 — silently, and only for the largest k.
    shf = imm[3..0]
    shk = is_msr * (shf + 1)
    sw = shra(sp, shk)

    r_mul = sw[31..0]

    # the shifted product fits a signed 32-bit fixnum iff everything
    # above bit 30 is sign extension — all zeros or all ones. One test,
    # both ops, no special case for k = 0.
    hi33 = sw[63..31]
    ovf_mul = band(hi33 != 0, hi33 != 0x1FFFFFFFF)

    # ---- signed compare by bias
    ka = bxor(pa, 0x80000000)
    kb = bxor(pb, 0x80000000)

    # default: mov shape
    y = a

    hdl_case <<sel::5>> do
      # arithmetic results are payloads: assigning 32 bits into a 36-bit
      # output zero-extends, which IS the INT tag. The tag is rebuilt,
      # never carried through the adder.
      <<0::5>> -> y = r_add
      <<1::5>> -> y = r_sub
      <<2::5>> -> y = r_mul
      <<3::5>> -> y = band(pa, pb)
      <<4::5>> -> y = bor(pa, pb)
      <<5::5>> -> y = bxor(pa, pb)
      # comparisons: result is the atom true/false. ATOM tag is 0x1;
      # reserved indices true = 14, false = 15 (Term.reserved_atoms
      # order — regenerate, do not hand-edit), so `14 + (not p)` is the
      # whole encoder.
      <<6::5>> -> y = 0x100000000 + 14 + (a != b)
      <<7::5>> -> y = 0x100000000 + 14 + (a == b)
      <<8::5>> -> y = 0x100000000 + 14 + (ka >= kb)
      <<9::5>> -> y = 0x100000000 + 14 + (ka > kb)
      <<10::5>> -> y = 0x100000000 + 14 + (tag_a != tag_imm)
      <<11::5>> -> y = a
      # ldi: sign-extend imm12 into a 32-bit INT payload (tag 0)
      <<12::5>> -> y = imm[11] * 0xFFFFF000 + imm
      # ldn: the NIL word (tag 0x2)
      <<13::5>> -> y = 0x200000000
      # lda: ATOM word, zero-extended imm12 index
      <<14::5>> -> y = 0x100000000 + imm
      <<15::5>> -> y = a
      # mulsr: same datapath as mul, non-zero shift
      <<16::5>> -> y = r_mul
    end

    # cmpeq/cmpne (6/7) compare whole words and accept any term; cmplt/
    # cmple (8/9) go through `int!` in the model and must trap on a
    # non-integer, so they join the tag-checked group.
    needs_int = bor(sel < 6, bor(sel == 8, bor(sel == 9, is_msr)))
    bad = band(needs_int, bnot(ints))

    # only the three widening ops can leave the range; band/bor/bxor of
    # two 32-bit payloads is 32 bits by construction
    ovf =
      band(ints,
        bor(band(sel == 0, ovf_add),
          bor(band(sel == 1, ovf_sub),
            band(bor(sel == 2, is_msr), ovf_mul))))

    fault = bor(bad, ovf)
    fault_reason = bad * 3 + band(bnot(bad), ovf) * 5
  end
end
