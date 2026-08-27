defmodule PicoBEAM.RTL.ImageParser do
  @moduledoc """
  The `.pbi` byte stream, turned into loader side-door writes.

      magic "pBM2" | bundles u16le | pool u16le | entry0 u16le | entry1 u16le
      then bundles, 9 bytes each, big-endian 72-bit
      then pool words, 5 bytes each, big-endian (top nibble 0)

  This used to live inside `SdBoot`, in the middle of a 500-line SPI
  state machine, because there was only ever one thing feeding it. There
  are two now — a microSD card and the debug UART (`notes/37`) — and a
  parser with two callers is a parser that gets tested twice.

  It is deliberately dumb: bytes in, side-door writes out, no idea where
  the bytes came from or how long they took. `byte_en` can be one byte
  every 256 clocks (the card at 375 kHz) or one every 104 (the UART at
  115200) and nothing here notices.

  ## `strict`

  On a card the image is at a known sector and bad magic means the wrong
  image — `SdBoot` raises error 5 and stops. On a wire there is no known
  offset, the line carries whatever the host felt like sending, and the
  magic IS the frame sync: a mismatch just slides the window and waits
  for the next `p`. Same four bytes, two different meanings, one bit to
  say which.
  """

  use Hw.Component

  clock :clk, freq: 12.0

  input :rst, 1
  # 1: bad magic is an error. 0: bad magic is "not the start of an
  # image yet", and the window slides.
  input :strict, 1
  input :byte_en, 1
  input :byte, 8

  output :code_en, 1
  output :code_addr, 9
  output :code_data, 72
  output :pool_en, 1
  output :pool_addr, 8
  output :pool_data, 36

  output :entry0, 9
  output :entry1, 9
  # every bundle and pool word the header promised has been delivered
  output :complete, 1
  output :bad_magic, 1
  # past the magic and into an image. The UART loader holds the engines
  # in reset on this: a program arriving is a program about to replace
  # the one that is running.
  output :receiving, 1
  # the raw byte stream, indexed from the magic. The side door gets the
  # PARSED image; a card wants the bytes back exactly as they arrived,
  # so `notes/38`'s write-through taps them here rather than
  # re-serialising what the parser already took apart.
  output :store_en, 1
  output :store_idx, 13
  # how long the image turned out to be, valid with `complete`
  output :img_len, 13

  # 0 magic · 1 header · 2 bundles · 3 pool · 4 done
  wire :pstate, 3, init: 0
  # counts bytes within an item — bundles are NINE bytes, so 4 bits.
  # (3 bits shipped once: yosys proved `pidx == 8` unsatisfiable, deleted
  # the never-written code memory, and X-propagated the entire engine
  # away — the synthesizer as accidental bounded model checker. notes/15.)
  wire :pidx, 4, init: 0
  wire :shreg, 72, init: 0
  wire :bc, 10, init: 0
  wire :pc, 9, init: 0
  wire :e0, 16, init: 0
  wire :e1, 16, init: 0
  wire :iidx, 10, init: 0

  wire :ce_r, 1, init: 0
  wire :ca_r, 9, init: 0
  wire :cd_r, 72, init: 0
  wire :pe_r, 1, init: 0
  wire :pa_r, 8, init: 0
  wire :pd_r, 36, init: 0
  wire :bad_r, 1, init: 0

  wire :want, 8
  # index of the next byte within the image, 0 while hunting
  wire :bpos, 13, init: 0
  wire :store_r, 1, init: 0
  wire :idx_r, 13, init: 0

  comb do
    code_en = ce_r
    code_addr = ca_r
    code_data = cd_r
    pool_en = pe_r
    pool_addr = pa_r
    pool_data = pd_r
    entry0 = e0[8..0]
    entry1 = e1[8..0]
    complete = pstate == 4
    receiving = pstate != 0
    store_en = store_r
    store_idx = idx_r
    img_len = bpos
    bad_magic = bad_r

    # "pBM2", one byte at a time
    want =
      (pidx == 0) * 0x70 + (pidx == 1) * 0x42 + (pidx == 2) * 0x4D + (pidx == 3) * 0x32
  end

  on :clk do
    ce_r = 0
    pe_r = 0
    store_r = 0

    if rst == 1 do
      pstate = 0
      pidx = 0
      iidx = 0
      shreg = 0
      bad_r = 0
      bpos = 0
    else
      if byte_en == 1 do
        # every byte that is part of a candidate image is offered to the
        # card writer, magic included, at the index it arrived at
        if bor(pstate != 0, bor(byte == want, byte == 0x70)) == 1 do
          store_r = 1
          idx_r = bpos
        end

        if pstate != 0 do
          bpos = bpos + 1
        end

        if pstate == 0 do
          if byte == want do
            bpos = bpos + 1

            if pidx == 3 do
              pidx = 0
              pstate = 1
            else
              pidx = pidx + 1
            end
          else
            # strict: this is the wrong image. loose: this is not the
            # start of one yet, and a `p` is where the next guess begins.
            bad_r = strict
            pidx = band(byte == 0x70, 1)
            bpos = band(byte == 0x70, 1)
            idx_r = 0
          end
        else
          if pstate == 1 do
            if pidx == 0, do: bc = byte
            if pidx == 1, do: bc = bor(bc, byte <<< 8)
            if pidx == 2, do: pc = byte
            if pidx == 3, do: pc = bor(pc, byte <<< 8)
            if pidx == 4, do: e0 = byte
            if pidx == 5, do: e0 = bor(e0, byte <<< 8)
            if pidx == 6, do: e1 = byte
            if pidx == 7, do: e1 = bor(e1, byte <<< 8)

            if pidx == 7 do
              pidx = 0
              iidx = 0
              shreg = 0
              pstate = 2
            else
              pidx = pidx + 1
            end
          else
            if pstate == 2 do
              if pidx == 8 do
                ce_r = 1
                ca_r = iidx[8..0]
                cd_r = bor(shreg <<< 8, byte)
                shreg = 0
                pidx = 0

                if iidx + 1 == bc do
                  iidx = 0

                  if pc == 0 do
                    pstate = 4
                  else
                    pstate = 3
                  end
                else
                  iidx = iidx + 1
                end
              else
                shreg = bor(shreg <<< 8, byte)
                pidx = pidx + 1
              end
            else
              if pstate == 3 do
                if pidx == 4 do
                  pe_r = 1
                  pa_r = iidx[7..0]
                  pd_r = band(bor(shreg <<< 8, byte), 0xFFFFFFFFF)
                  shreg = 0
                  pidx = 0

                  if iidx + 1 == pc do
                    pstate = 4
                  else
                    iidx = iidx + 1
                  end
                else
                  shreg = bor(shreg <<< 8, byte)
                  pidx = pidx + 1
                end
              end
            end
          end
        end
      end
    end
  end
end
