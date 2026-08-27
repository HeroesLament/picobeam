defmodule PicoBEAM.RTL.SdBootSim do
  @moduledoc """
  `SdBoot` elaborated for simulation — same source, two parameters
  changed, all ports passed straight through.

  It exists because EHDL constant-folds `param` at elaboration: by the
  time the Verilog emitter runs, `PWRWAIT` is the literal 1,200,000 in
  every comparison and the module-level declaration is decorative. A
  Verilog `#(.PWRWAIT(64))` override elaborates without complaint and
  changes nothing — which is how `tb_sdboot` came to spend its entire
  budget inside a 100 ms power-up wait it thought it had shortened.
  (EHDL now emits those as `localparam`, so the same mistake is a
  compile error rather than a silent one.)

  Overriding a param means overriding it on the `instance`, before
  elaboration, which is what this wrapper is:

  * `PWRWAIT: 64` — the power-up wait is a real card's 100 ms, and
    simulating 100 ms of nothing is 1.2 million clocks of nothing.
  * `HALF: 2` — the SPI half-period. 16 is ~375 kHz at 12 MHz, inside
    the 400 kHz identification-mode ceiling every card must accept, and
    256 clocks a byte. The card model does not care how fast it is
    clocked; the testbench needs the PROTOCOL to be right, not slow.

  `LBA` stays at the real 8192, so the CMD17 addresses the testbench
  sees are the ones the board will send.
  """

  use Hw.Component

  clock :clk, freq: 12.0

  input :rst, 1
  input :miso, 1

  input :wr_en, 1
  input :wr_byte, 8
  input :wr_idx, 13
  input :wr_go, 1
  input :wr_len, 13

  output :wr_busy, 1
  output :wr_done, 1
  output :wr_err, 1

  output :sck, 1
  output :mosi, 1
  output :cs_n, 1

  output :code_en, 1
  output :code_addr, 9
  output :code_data, 72
  output :pool_en, 1
  output :pool_addr, 8
  output :pool_data, 36

  output :entry0, 9
  output :entry1, 9

  output :busy, 1
  output :done, 1
  output :err, 3
  output :state_dbg, 4
  output :last_rx, 8

  instance :sd, PicoBEAM.RTL.SdBoot,
    PWRWAIT: 64,
    HALF: 2,
    LBA: 8192,
    clk: :clk,
    rst: :rst,
    miso: :miso,
    wr_en: :wr_en,
    wr_byte: :wr_byte,
    wr_idx: :wr_idx,
    wr_go: :wr_go,
    wr_len: :wr_len,
    wr_busy: :wr_busy,
    wr_done: :wr_done,
    wr_err: :wr_err,
    sck: :sck,
    mosi: :mosi,
    cs_n: :cs_n,
    code_en: :code_en,
    code_addr: :code_addr,
    code_data: :code_data,
    pool_en: :pool_en,
    pool_addr: :pool_addr,
    pool_data: :pool_data,
    entry0: :entry0,
    entry1: :entry1,
    busy: :busy,
    done: :done,
    err: :err,
    state_dbg: :state_dbg,
    last_rx: :last_rx
end
