defmodule PicoBEAM.RTL.Decode do
  @moduledoc """
  M2 scaffold — bundle field extraction.

  Splits a 72-bit bundle into three 24-bit slots and each slot into the
  field shapes the ISA doc fixes (`isa.ex`): `op:8 | rd:4 | ra:4 | rb:4`
  for three-register ops, `op:8 | rd:4 | imm:12` for `ldi`-shaped ops.
  Purely combinational; the pipeline register lives in the sequencer.

  ## The opcode numbering is NOT assigned here yet

  `isa.ex` names the ops; their binary values are an ABI decision the
  assembler and this decoder must take together (one table, generated
  into both). Until that lands, `op0/1/2` are raw bytes passed through
  and classification is the sequencer's lookup. Recording rather than
  inventing.

  ## A real encoding finding (2026-08-22, scaffolding pass)

  Two-register branches do not fit the slot: `beq ra, rb, label` needs
  8 + 4 + 4 + 12 = 28 bits against 24. The options, for the encoding
  table to settle: (a) shrink two-reg branch offsets to 8 bits (±128
  bundles — measure real branch distances over the erlc corpus first);
  (b) split into `cmpeq` + `bift`, costing a slot but no encoding
  (the front end already emits compare + branch for most cases);
  (c) spend 2 of the bundle's 72 - 3x24 = 0 spare bits — there are none.
  Leaning (b) as default with (a) as the optimization, since the model's
  ISA keeps both forms legal and the assembler can lower transparently.
  Logged for `notes/15-m2-calibration.md`'s next entry.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :bundle, 72

  output :op0, 8
  output :rd0, 4
  output :ra0, 4
  output :rb0, 4
  output :imm0, 12
  output :i8_0, 8

  output :op1, 8
  output :rd1, 4
  output :ra1, 4
  output :rb1, 4
  output :imm1, 12
  output :i8_1, 8

  output :op2, 8
  output :rd2, 4
  output :ra2, 4
  output :rb2, 4
  output :imm2, 12
  output :i8_2, 8

  comb do
    op0 = bundle[71..64]
    rd0 = bundle[63..60]
    ra0 = bundle[59..56]
    rb0 = bundle[55..52]
    imm0 = bundle[59..48]
    i8_0 = bundle[55..48]

    op1 = bundle[47..40]
    rd1 = bundle[39..36]
    ra1 = bundle[35..32]
    rb1 = bundle[31..28]
    imm1 = bundle[35..24]
    i8_1 = bundle[31..24]

    op2 = bundle[23..16]
    rd2 = bundle[15..12]
    ra2 = bundle[11..8]
    rb2 = bundle[7..4]
    imm2 = bundle[11..0]
    i8_2 = bundle[7..0]
  end
end
