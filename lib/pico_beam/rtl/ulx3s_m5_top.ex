defmodule PicoBEAM.RTL.Ulx3sM5Top do
  @moduledoc """
  The two-engine board: pins, PLL, and `M5Core`.

      25 MHz osc ─▶ PLL (CLKOS = 432/36 = 12 MHz exact) ─▶ M5Core

  Everything interesting is in `M5Core`; this is the part that cannot be
  simulated — the board's oscillator, its buttons, its microSD pins, and
  the ESP32 that has to be held in reset because it shares them.

  `wifi_en` LOW is load-bearing, not cosmetic: the microSD lines are
  wired to the ESP32's GPIO 12–15, and stock firmware mounts the card at
  boot. `Ulx3sTop` met that on first silicon as loader error 1 — CMD0
  answered by nothing but 0xFF.

  Read the debug UART on the Mac:

      screen /dev/tty.usbserial-*  115200

  (close `screen` before running `fujprog` — same FTDI.)
  """

  use Hw.Component

  clock :clk_25mhz, freq: 25.0

  input :btn1, 1
  input :btn2, 1
  input :sd_d0, 1
  input :ftdi_txd, 1

  output :sd_clk, 1
  output :sd_cmd, 1
  output :sd_d1, 1
  output :sd_d2, 1
  output :sd_d3, 1
  output :wifi_en, 1
  output :wifi_gpio0, 1
  output :led, 8
  output :ftdi_rxd, 1

  wire :clk_48, 1
  wire :clk_12, 1
  wire :pll_locked, 1
  wire :core_rst, 1

  comb do
    wifi_gpio0 = 1
    # the ESP32 shares the microSD pins; hold it in reset
    wifi_en = 0
    core_rst = bor(btn1, bnot(pll_locked))
  end

  instance :pll, ULX3S.PLL,
    CLKOP_DIV: 9,
    CLKOS_DIV: 36,
    CLKOP_CPHASE: 8,
    CLKOS_CPHASE: 35,
    clk_in: :clk_25mhz,
    clk_out0: :clk_48,
    clk_out1: :clk_12,
    locked: :pll_locked,
    phase_dir: 0,
    phase_step: 0

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
    clk_12: :clk_12,
    rst: :core_rst,
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
