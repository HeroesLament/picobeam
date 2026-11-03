defmodule PicoBEAM.RTL.SdTb do
  @moduledoc """
  Simulation testbench wrapper for `SdBoot` — short power-wait, all
  status brought out. SdBoot has no `memory` blocks, so the EHDL
  simulator's MemWrite gap does not apply: the loader is fully
  simulable, and `scripts/sim_sdboot.exs` drives it against a software
  SD-card model.
  """

  use Hw.Component

  clock :clk, freq: 12.0

  input :rst, 1
  input :miso, 1

  output :sck, 1
  output :mosi, 1
  output :cs_n, 1
  output :state_dbg, 4
  output :err, 3
  output :done, 1
  output :last_rx, 8
  output :code_en, 1
  output :code_addr, 12
  output :code_data, 72

  wire :w_pe, 1
  wire :w_pa, 8
  wire :w_pd, 36
  wire :w_busy, 1

  instance :sd, PicoBEAM.RTL.SdBoot,
    PWRWAIT: 64,
    LBA: 8192,
    clk: :clk,
    rst: :rst,
    miso: :miso,
    sck: :sck,
    mosi: :mosi,
    cs_n: :cs_n,
    code_en: :code_en,
    code_addr: :code_addr,
    code_data: :code_data,
    pool_en: :w_pe,
    pool_addr: :w_pa,
    pool_data: :w_pd,
    busy: :w_busy,
    done: :done,
    err: :err,
    state_dbg: :state_dbg,
    last_rx: :last_rx
end
