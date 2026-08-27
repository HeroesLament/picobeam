defmodule PicoBEAM.RTL.FrameRam do
  @moduledoc """
  M2 scaffold — the register-window frame stack's backing store.

  Where `PicoBEAM.RTL.RegWindow`'s spill drain lands and where `ret`'s
  fill streams from. 512 x 36 (one DP16KD) = 32 frames of 16 words — the
  return-stack depth the reference model enforces at 64 will need two
  EBRs or a smaller bound; recorded, not yet decided.

  The frame pointer counts FRAMES: a spill occupies `fp`'s slot and
  increments it; a fill decrements first and streams back. The word
  address is `frame << 4 | idx`, so frame boundaries are free bit
  concatenation. Spill side wires straight to the RegWindow drain
  (`spill_valid/idx/data`); the fill side is driven by the sequencer's
  `ret_fill` phase, one word per cycle into the window's write port 0.

  ## Return-address/dest bookkeeping (call/ret pass, 2026-08-22)

  A second narrow memory, `rets` (32 x 13 = `pc:9 | dest:4`), indexed by
  the SAME frame pointer: `push_en` records the link (`ret_pc_in`,
  `ret_dest_in`) in the slot the spilled frame occupies, so frames and
  links stay in lockstep by construction — there is no separate return
  stack to desynchronize. After `pop_en` the outputs present the popped
  frame's link (`fill_data`'s pop-then-read discipline applies to both
  memories): `ret_pc_out` is where the sequencer resumes, `ret_dest_out`
  is the caller register the latched return value lands in. This is the
  model's rstack entry `{ret_pc, dest}` — and the RETADDR term tag stays
  reserved for the day frames hibernate to SDRAM and the link must
  travel as a word (M9).

  Overflow (`fp` at max) is the hardware home of `:stack_overflow`.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # spill side — connect RegWindow's drain directly
  input :spill_valid, 1
  input :spill_idx, 4
  input :spill_data, 36

  # a spill BEGINS (fp claims a slot) on call_commit; the 16 drained words
  # then land in that slot as they arrive. The link is captured with it.
  input :push_en, 1
  input :ret_pc_in, 9
  input :ret_dest_in, 4

  # fill side — sequencer strobes fill_en with idx 0..15 during ret_fill,
  # pop_en once when the stream completes
  input :fill_en, 1
  input :fill_idx, 4
  output :fill_data, 36
  input :pop_en, 1

  # the popped frame's link (valid from the cycle after pop_en)
  output :ret_pc_out, 9
  output :ret_dest_out, 4

  output :fp_out, 6
  output :overflow, 1

  memory :frames, width: 36, depth: 512, sync_read: :clk
  # the link store: pc(9) | dest(4), one entry per frame slot
  memory :rets, width: 13, depth: 32, sync_read: :clk

  # frame pointer: index of the next free frame slot (0..31)
  wire :fp, 6, init: 0
  # the slot currently receiving the in-flight drain
  wire :spill_slot, 5, init: 0
  wire :ret_q, 13

  comb do
    # pop-then-fill order (the sequencer strobes pop_en on ret, THEN runs
    # the fill stream): after the pop the caller's frame sits at slot fp,
    # and so does its link.
    fill_data = frames[fp * 16 + fill_idx]
    ret_q = rets[fp[4..0]]
    ret_pc_out = ret_q[12..4]
    ret_dest_out = ret_q[3..0]
    fp_out = fp
    overflow = band(push_en, fp == 32)
  end

  on :clk do
    if rst == 1 do
      fp = 0
      spill_slot = 0
    else
      if push_en == 1 and fp < 32 do
        spill_slot = fp[4..0]
        rets[fp[4..0]] = ret_pc_in * 16 + ret_dest_in
        fp = fp + 1
      end

      if spill_valid == 1 do
        frames[spill_slot * 16 + spill_idx] = spill_data
      end

      if pop_en == 1 and fp > 0 do
        fp = fp - 1
      end
    end
  end
end
