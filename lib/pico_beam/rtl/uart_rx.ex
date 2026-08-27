defmodule PicoBEAM.RTL.UartRx do
  @moduledoc """
  8N1 receiver, the other half of `DbgUart`.

  The board has streamed status out of `ftdi_rxd` since M2 and never
  listened. `ftdi_txd` is the same FTDI, the same cable, and the same
  115200 — one wire that was already there (`notes/37`).

  Idle high; a falling edge starts a frame. Sample at the middle of each
  bit: half a period to the centre of the start bit, then a full period
  per data bit, LSB first. A start bit that is not still low at its
  centre is a glitch and the frame is abandoned — the line spends its
  life idle next to a transmitter that is never quiet, so noise
  rejection is not theoretical.

  `DIV` is clocks per bit: 104 is 115200 at 12 MHz (12e6/115200 = 104.17,
  0.16% fast, and 8N1 resynchronises every frame).
  """

  use Hw.Component

  param :DIV, default: 104

  clock :clk, freq: 12.0

  input :rst, 1
  input :rx, 1

  output :data, 8
  # one cycle, when `data` is a byte the line just finished
  output :valid, 1

  # 0 idle · 1 start · 2 data · 3 stop
  wire :st, 2, init: 0
  wire :cnt, 8, init: 0
  wire :bit_i, 3, init: 0
  wire :sh, 8, init: 0
  # two flops before anything looks at it: the line is asynchronous
  wire :rx_d, 1, init: 1
  wire :rx_q, 1, init: 1
  wire :data_r, 8, init: 0
  wire :valid_r, 1, init: 0

  comb do
    data = data_r
    valid = valid_r
  end

  on :clk do
    valid_r = 0
    rx_d = rx
    rx_q = rx_d

    if rst == 1 do
      st = 0
      cnt = 0
      bit_i = 0
    else
      if st == 0 do
        if rx_q == 0 do
          st = 1
          cnt = 0
        end
      end

      if st == 1 do
        cnt = cnt + 1

        if cnt == DIV / 2 - 1 do
          cnt = 0

          if rx_q == 0 do
            st = 2
            bit_i = 0
          else
            # not a start bit after all
            st = 0
          end
        end
      end

      if st == 2 do
        cnt = cnt + 1

        if cnt == DIV - 1 do
          cnt = 0
          sh = bor(sh >>> 1, rx_q <<< 7)

          if bit_i == 7 do
            st = 3
          else
            bit_i = bit_i + 1
          end
        end
      end

      if st == 3 do
        cnt = cnt + 1

        if cnt == DIV - 1 do
          cnt = 0
          st = 0
          data_r = sh
          valid_r = 1
        end
      end
    end
  end
end
