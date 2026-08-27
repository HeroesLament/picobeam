defmodule PicoBEAM.RTL.LitPool do
  @moduledoc """
  M2 scaffold — literal pool for `ldc`.

  Any 36-bit term word the 12-bit `ldi` immediate cannot express (wide
  fixnums, interned atoms beyond the reserved range, pids/refs in test
  images) lives here; `ldc rd, const` is a sync read by pool index. 256
  entries to start — half an EBR at 36 wide; the assembler interns and
  dedups, so real programs stay small.

  Like the code store, the pool is baked at elaboration (`init:`) and the
  write port waits for the loader.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rd_addr, 8
  output :rd_data, 36

  # A second read port, for `mkfun` (`notes/42`). `ldc`'s address is
  # driven from the X stage because its answer lands on the wb2 turn a
  # cycle later; `mkfun` is a HEAP command and needs its `pa` at X, so
  # its pool read has to be addressed a stage earlier. Moving `ldc` to
  # match would be re-timing a working path for a convenience; a second
  # read on a 256x36 memory is one more EBR per engine.
  input :rd2_addr, 8
  output :rd2_data, 36

  input :wr_en, 1
  input :wr_addr, 8
  input :wr_data, 36

  memory :pool, width: 36, depth: 256, sync_read: :clk

  comb do
    rd_data = pool[rd_addr]
    rd2_data = pool[rd2_addr]
  end

  on :clk do
    if wr_en == 1 do
      pool[wr_addr] = wr_data
    end
  end
end
