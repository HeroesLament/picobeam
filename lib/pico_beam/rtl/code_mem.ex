defmodule PicoBEAM.RTL.CodeMem do
  @moduledoc """
  M2 scaffold — bundle store.

  One 72-bit-wide sync-read memory, 512 bundles deep: yosys pairs two
  deep-configured EBRs side by side (Probe A's inference, twice). A fetch
  is therefore ONE registered read — `rd_bundle` is valid the cycle after
  `rd_addr` is presented, which is the timing the sequencer's fetch phase
  assumes.

  512 bundles is the per-function ceiling the assembler already enforces
  (`Asm`: 2048 bundles is the *encoding* range; the store is sized down
  until Q5's method cache decides the hierarchy). Writing the store is the
  loader's job (M8/boot path); for M2 the image is baked in at elaboration
  via `init:` — the write port exists but nothing drives it yet.

  Q5 note: if the whole-method cache is built (leaning yes, twice argued
  in `notes/08`), this component becomes the cache data array and gains a
  fill port from SDRAM; the read side keeps exactly this shape.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rd_addr, 9
  output :rd_bundle, 72

  # loader-side (unused in M2; the image arrives via init at elaboration)
  input :wr_en, 1
  input :wr_addr, 9
  input :wr_data, 72

  memory :code, width: 72, depth: 512, sync_read: :clk

  comb do
    rd_bundle = code[rd_addr]
  end

  on :clk do
    if wr_en == 1 do
      code[wr_addr] = wr_data
    end
  end
end
