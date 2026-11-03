defmodule PicoBEAM.RTL.M5CoreSim do
  @moduledoc """
  `M5Core` with a card that answers quickly.

  EHDL folds `param` at elaboration, so the only place an override
  works is on an `instance` (`notes/34`). Ten ports pass straight
  through; the two that change are the loader's:

  * `PWRWAIT: 64` — the real one is a card's 100 ms power-up, which is
    1.2 million clocks of a two-engine design doing nothing.
  * `HALF: 2` — the SPI half-period. 16 is ~375 kHz at 12 MHz and 256
    clocks a byte; the card model does not care how fast it is clocked.
  * `UDIV: 8` — clocks per UART bit. 104 is 115200 at 12 MHz and 2 KB of
    image is two million clocks; the receiver is a divider and a shift
    register and does not care either.

  Everything else is the bitstream: the same boot FSM, the same shared
  side door into two engines, the same ring, the same entry points out
  of the image header. The glue is the point — `tb_sdboot` proves the
  loader and `tb_fixed:elixir` proves an engine, and what neither can
  see is the forty lines of core that join them.
  """

  use Hw.Component

  clock :clk_12, freq: 12.0

  input :rst, 1
  input :btn2, 1
  input :sd_d0, 1
  input :ftdi_txd, 1

  output :sd_clk, 1
  output :sd_cmd, 1
  output :sd_d1, 1
  output :sd_d2, 1
  output :sd_d3, 1
  output :led, 8
  output :ftdi_rxd, 1

  instance :core, PicoBEAM.RTL.M5Core,
    # no host port on this top (`RingHost`'s host-in / host-out)
    hin_en: 0,
    hin_head: 0,
    hin_kind: 0,
    hin_deng: 0,
    hin_word: 0,
    hin_len: 0,
    hout_pop: 0,
    # no hot-load port either
    hot_ce: 0,
    hot_pe: 0,
    hot_addr: 0,
    hot_data: 0,
    PWRWAIT: 64,
    HALF: 2,
    UDIV: 8,
    clk_12: :clk_12,
    rst: :rst,
    btn2: :btn2,
    sd_d0: :sd_d0,
    ftdi_txd: :ftdi_txd,
    sd_clk: :sd_clk,
    sd_cmd: :sd_cmd,
    sd_d1: :sd_d1,
    sd_d2: :sd_d2,
    sd_d3: :sd_d3,
    led: :led,
    ftdi_rxd: :ftdi_rxd
end
