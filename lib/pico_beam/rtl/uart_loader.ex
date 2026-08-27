defmodule PicoBEAM.RTL.UartLoader do
  @moduledoc """
  Push a `.pbi` image at the board over the debug cable (`notes/37`).

      host $ mix run scripts/pbpush.exs _emit/sd/elixir.img
             └─ 115200 8N1 ──▶ ftdi_txd ──▶ UartRx ──▶ ImageParser
                                                          └─ loader side door

  `UartRx` for the wire, `ImageParser` for the format — the same parser
  the microSD loader uses, which is the whole reason it was lifted out of
  `SdBoot` in the first place.

  ## The magic is the frame sync

  There is no length prefix, no handshake and no command byte. The
  parser runs in loose mode: bytes that are not `"pBM2"` slide the
  window, and the four that are start an image. That means the line can
  carry anything at all when it is not carrying a program, and it means
  pushing a new image is `cat image.img > /dev/cu.usbserial-*`.

  It also means the board cannot be told to do anything else this way,
  which is the correct amount of attack surface for a debug cable.

  ## Entry points survive the reset

  The parser is reset one cycle after it completes, so it is ready for
  the next image without anything having to ask. Its entry points would
  go with it, so they are latched here — the board still needs them a
  few cycles later, when it boots.
  """

  use Hw.Component

  param :DIV, default: 104

  clock :clk, freq: 12.0

  input :rst, 1
  input :rx, 1

  output :code_en, 1
  output :code_addr, 9
  output :code_data, 72
  output :pool_en, 1
  output :pool_addr, 8
  output :pool_data, 36

  output :entry0, 9
  output :entry1, 9
  # a whole image has landed: reset the engines and boot it
  output :img_done, 1
  # an image is arriving; hold the engines in reset
  output :receiving, 1
  # the raw byte stream, for whoever wants to keep a copy — the card
  # writer does (`notes/38`)
  output :store_en, 1
  output :store_idx, 13
  output :store_byte, 8
  output :img_len, 13

  wire :rx_data, 8
  wire :rx_valid, 1
  wire :p_rst, 1
  wire :p_e0, 9
  wire :p_e1, 9
  wire :p_complete, 1
  wire :p_bad, 1
  wire :cp_d, 1, init: 0
  wire :e0_r, 9, init: 0
  wire :e1_r, 9, init: 0
  wire :done_r, 1, init: 0
  wire :len_r, 13, init: 0
  wire :p_len, 13

  comb do
    # one cycle after the image completes, the parser goes back to
    # hunting for a magic
    p_rst = bor(rst, cp_d)
    entry0 = e0_r
    entry1 = e1_r
    img_done = done_r
    store_byte = rx_data
    img_len = len_r
  end

  on :clk do
    done_r = 0

    if rst == 1 do
      cp_d = 0
    else
      cp_d = p_complete

      # the rising edge, so a held `complete` cannot boot twice
      if band(p_complete, bnot(cp_d)) == 1 do
        e0_r = p_e0
        e1_r = p_e1
        # the parser is about to be reset and take its byte count with
        # it; the card writer needs to know how much to write
        len_r = p_len
        done_r = 1
      end
    end
  end

  instance :urx, PicoBEAM.RTL.UartRx,
    DIV: DIV,
    clk: :clk,
    rst: :rst,
    rx: :rx,
    data: :rx_data,
    valid: :rx_valid

  instance :parse, PicoBEAM.RTL.ImageParser,
    clk: :clk,
    rst: :p_rst,
    strict: 0,
    byte_en: :rx_valid,
    byte: :rx_data,
    code_en: :code_en,
    code_addr: :code_addr,
    code_data: :code_data,
    pool_en: :pool_en,
    pool_addr: :pool_addr,
    pool_data: :pool_data,
    entry0: :p_e0,
    entry1: :p_e1,
    complete: :p_complete,
    receiving: :receiving,
    store_en: :store_en,
    store_idx: :store_idx,
    img_len: :p_len,
    bad_magic: :p_bad
end
