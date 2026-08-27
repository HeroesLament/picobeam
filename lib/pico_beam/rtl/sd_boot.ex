defmodule PicoBEAM.RTL.SdBoot do
  @moduledoc """
  MVP microSD boot loader — `notes/11`'s stage-0, in gates.

  Speaks SPI mode to the card, reads a raw `.pbi`-precursor image from
  a fixed LBA, and streams it into the Engine's loader side-door. No
  filesystem, no partitions: the image sits at `LBA` (default 8192 =
  4 MiB in), written with `dd` (see `scripts/mk_image.exs`).

  ## Protocol (SPI mode, ~375 kHz at clk=12 MHz; `HALF` sets the speed)

      power-wait (~20 ms) → 80 idle clocks CS-high → CMD0 (idle) →
      CMD8 (0x1AA, v2 check) → [CMD55+ACMD41(HCS)]* until ready →
      CMD17 per sector from LBA … until the parser is fed → done

  **SDHC assumed** (block addressing; any modern card ≥ 4 GB). A v1
  card fails CMD8 and lands in the error state with code 2 — accepted
  MVP scope, recorded here.

  ## Image format (little header, big-endian words)

      bytes 0..3   magic "pBM2" (0x70 0x42 0x4D 0x32)
      bytes 4..5   bundle count, little-endian
      bytes 6..7   pool-word count, little-endian
      bytes 8..9   entry 0, little-endian — where engine 0 boots
      bytes 10..11 entry 1, little-endian — engine 1, or 0x1FF for none
      then         bundles, 9 bytes each, big-endian 72-bit
      then         pool words, 5 bytes each, big-endian (top 4 bits 0)

  The entry points are v2 (`notes/36`). v1 had none: the board top
  hard-coded `boot_pc`, which is fine with one engine and one program
  and stops being fine the moment a second engine needs a second entry
  and the image is the thing that changed. 0x1FF means "do not boot this
  engine" — it is not a valid bundle address in a 512-bundle code
  memory, so the sentinel costs no encoding space.

  The byte-stream parser is sector-agnostic: the sector loop keeps
  issuing CMD17s until the parser reports done, so images cross sector
  boundaries freely. Bad magic → error 5. Data CRC is not checked
  (MVP; the SPI-mode CRC is off after CMD0 anyway except the data CRC
  which we discard).

  ## Error codes (on `err`, latched, CS released)

      1 CMD0 no-idle   2 CMD8 rejected (v1/no card)
      3 ACMD41 timeout 4 CMD17/token failure   5 bad magic (or a v1 image)

  Status: `busy` while loading (hold the engine in reset on it),
  `done` on success, `state_dbg` for LEDs.

  ## Writing (notes/38)

  The same card, the other direction: CMD24, one sector at a time, from
  an 8 KB buffer this module owns. `wr_en`/`wr_byte`/`wr_idx` fill the
  buffer — the UART loader taps its raw byte stream straight into it —
  and `wr_go`/`wr_len` say "that is a whole image, put it on the card".

  The write happens AFTER the machine has already rebooted into the
  pushed image, because the side door got there first. So this is not on
  anybody's critical path: it is the difference between an image that
  survives a power cycle and one that does not, and it takes as long as
  it takes.

  A card is BUSY after a block write — MISO held low while the flash
  settles, for a few byte times or a few hundred milliseconds depending
  on the card and its mood. State 12 waits for that. A writer that does
  not is a writer that works in simulation and corrupts cards.

      10 data token + 512 bytes + CRC   11 data response   12 busy poll

  Errors land in `wr_err` and not in `err`: a failed write leaves a
  running machine running, and the image it is running came off the
  wire, not off the card.
  """

  use Hw.Component

  param :LBA, default: 8192
  # SPI half-period in clocks. 16 is ~375 kHz at 12 MHz, which is inside
  # the 400 kHz identification-mode ceiling every card must accept. It
  # is a parameter because simulating a card at 375 kHz means 256 clocks
  # per byte and 400,000 clocks per sector, and the testbench does not
  # need the card to be slow — it needs the PROTOCOL to be right
  # (`notes/34`).
  param :HALF, default: 16
  # power-on wait in clocks (~100 ms at 12 MHz); short in simulation
  param :PWRWAIT, default: 1_200_000

  clock :clk, freq: 12.0

  input :rst, 1
  input :miso, 1

  output :sck, 1
  output :mosi, 1
  output :cs_n, 1

  # ---- write side (notes/38): raw image bytes in, card out
  input :wr_en, 1
  input :wr_byte, 8
  input :wr_idx, 13
  input :wr_go, 1
  input :wr_len, 13

  output :wr_busy, 1
  output :wr_done, 1
  output :wr_err, 1

  # engine side-door
  output :code_en, 1
  output :code_addr, 9
  output :code_data, 72
  output :pool_en, 1
  output :pool_addr, 8
  output :pool_data, 36

  # the image's entry points, valid once `done` is up
  output :entry0, 9
  output :entry1, 9

  output :busy, 1
  output :done, 1
  output :err, 3
  output :state_dbg, 4
  # the last byte the card sent before the FSM froze — 0xFF means the
  # card never drove MISO (wiring); anything else means protocol
  output :last_rx, 8

  # ---- SPI byte engine -----------------------------------------------------
  wire :div, 5, init: 0
  wire :bit_cnt, 3, init: 0
  wire :sh_tx, 8, init: 0xFF
  wire :sh_rx, 8, init: 0
  wire :byte_busy, 1, init: 0
  wire :byte_go, 1, init: 0
  wire :byte_done, 1, init: 0
  wire :sck_r, 1, init: 0
  wire :cs_r, 1, init: 1

  # ---- protocol FSM --------------------------------------------------------
  # 0 pwr, 1 gap80, 2 cmd, 3 r1, 4 r7, 5 tok, 6 data, 7 crc, 8 done, 9 err
  wire :bstate, 4, init: 0
  wire :pwr_cnt, 21, init: 0
  wire :gap_cnt, 4, init: 0
  wire :lrx, 8, init: 0
  # CMD0 sometimes misses on the first try after power-up — retry with
  # a CS-high gap before declaring error 1
  wire :c0try, 2, init: 0
  wire :cmd_i, 3, init: 0
  # 0 cmd0, 1 cmd8, 2 cmd55, 3 acmd41, 4 cmd17
  wire :phase, 3, init: 0
  wire :tries, 4, init: 0
  wire :aloop, 12, init: 0
  wire :r7cnt, 3, init: 0
  wire :tok_cnt, 13, init: 0
  wire :dcnt, 9, init: 0
  wire :crc_i, 1, init: 0
  wire :sector, 32, init: 0
  wire :err_r, 3, init: 0

  # ---- image parser --------------------------------------------------------
  # `ImageParser` now, shared with the UART loader (`notes/37`). What is
  # left here is the CARD's half: feed it a byte per data cycle and ask
  # it whether the image is finished, so the sector loop knows when to
  # stop issuing CMD17s.
  wire :pf_en, 1
  wire :pf_done, 1
  wire :pf_bad, 1

  # ---- the write buffer and its sequencer
  # 8192 bytes is the biggest image this machine can hold: 512 bundles
  # at nine bytes, 256 pool words at five, and a twelve-byte header.
  memory :wbuf, width: 8, depth: 8192, sync_read: :clk
  wire :wra, 13, init: 0
  wire :wbuf_q, 8
  wire :wsec, 5, init: 0
  wire :wsecs, 5, init: 0
  # 0 token · 1 data · 2 crc
  wire :wsub, 2, init: 0
  wire :wr_tx, 8
  wire :wr_busy_r, 1, init: 0
  wire :wr_done_r, 1, init: 0
  wire :wr_err_r, 1, init: 0
  wire :rdone, 1, init: 0
  # `wr_go` is a one-cycle strobe and the card may be mid-sentence when
  # it arrives, so it is remembered rather than raced
  wire :wr_req, 1, init: 0
  wire :cmd_byte, 8
  wire :tx_sel, 8

  comb do
    sck = sck_r
    mosi = sh_tx[7]
    cs_n = cs_r
    # `done` is sticky: the read is over the moment it is over, and the
    # write states that follow are not the engine's business
    busy = bnot(bor(rdone, bstate == 9))
    done = rdone
    wr_busy = wr_busy_r
    wr_done = wr_done_r
    wr_err = wr_err_r
    wbuf_q = wbuf[wra]
    wr_tx = (wsub == 0) * 0xFE + (wsub == 1) * wbuf_q + (wsub == 2) * 0xFF
    err = err_r
    state_dbg = bstate
    last_rx = lrx
    # one byte per data cycle, straight into the parser
    pf_en = band(bstate == 6, byte_done)

    # command bytes by (phase, index); CRC bytes only matter pre-init
    cmd_byte = 0xFF

    hdl_case <<cmd_i::3>> do
      <<0::3>> ->
        cmd_byte =
          (phase == 0) * 0x40 + (phase == 1) * 0x48 + (phase == 2) * 0x77 +
            (phase == 3) * 0x69 + (phase == 4) * 0x51 + (phase == 5) * 0x58

      <<1::3>> -> cmd_byte = (phase == 3) * 0x40 + band(phase > 3, 1) * sector[31..24]
      <<2::3>> -> cmd_byte = band(phase > 3, 1) * sector[23..16]
      <<3::3>> -> cmd_byte = (phase == 1) * 0x01 + band(phase > 3, 1) * sector[15..8]
      <<4::3>> -> cmd_byte = (phase == 1) * 0xAA + band(phase > 3, 1) * sector[7..0]

      <<5::3>> ->
        cmd_byte =
          (phase == 0) * 0x95 + (phase == 1) * 0x87 +
            bnot(bor(phase == 0, phase == 1)) * 0x01

      <<6::3>> -> cmd_byte = 0xFF
      <<7::3>> -> cmd_byte = 0xFF
    end

    tx_sel =
      (bstate == 2) * cmd_byte + (bstate == 10) * wr_tx +
        band(bnot(bstate == 2), bnot(bstate == 10)) * 0xFF
  end

  on :clk do
    byte_done = 0
    wr_done_r = 0

    # the buffer fills whenever bytes arrive, whatever the card is doing
    if wr_en == 1 do
      wbuf[wr_idx] = wr_byte
    end

    if wr_go == 1 do
      wr_req = 1
      wsecs = (wr_len + 511) >>> 9
    end

    if rst == 1 do
      bstate = 0
      pwr_cnt = 0
      byte_busy = 0
      byte_go = 0
      sck_r = 0
      cs_r = 1
      sh_tx = 0xFF
      err_r = 0
      sector = 0
      rdone = 0
      wr_req = 0
      wr_busy_r = 0
      wr_err_r = 0
      wsec = 0
      wsub = 0
    else
      # ---- byte engine: mode 0, sample on rising, shift on falling
      if byte_go == 1 do
        byte_go = 0
        byte_busy = 1
        sh_tx = tx_sel
        bit_cnt = 0
        div = 0
      else
        if byte_busy == 1 do
          div = div + 1

          if div == HALF - 1 do
            sck_r = 1
            sh_rx = bor(sh_rx <<< 1, miso)
          end

          if div == 2 * HALF - 1 do
            sck_r = 0
            div = 0

            if bit_cnt == 7 do
              byte_busy = 0
              byte_done = 1
              lrx = sh_rx
            else
              sh_tx = sh_tx <<< 1
              bit_cnt = bit_cnt + 1
            end
          end
        end
      end

      # ---- protocol
      hdl_case <<bstate::4>> do
        # power wait (~20 ms), then 80 idle clocks with CS high
        <<0::4>> ->
          pwr_cnt = pwr_cnt + 1

          if pwr_cnt == PWRWAIT do
            gap_cnt = 0
            byte_go = 1
            bstate = 1
          end

        <<1::4>> ->
          if byte_done == 1 do
            if gap_cnt == 9 do
              cs_r = 0
              phase = 0
              cmd_i = 0
              byte_go = 1
              bstate = 2
            else
              gap_cnt = gap_cnt + 1
              byte_go = 1
            end
          end

        # send the 6 command bytes
        <<2::4>> ->
          if byte_done == 1 do
            if cmd_i == 5 do
              tries = 0
              byte_go = 1
              bstate = 3
            else
              cmd_i = cmd_i + 1
              byte_go = 1
            end
          end

        # R1 poll
        <<3::4>> ->
          if byte_done == 1 do
            if sh_rx[7] == 0 do
              # dispatch on phase
              if phase == 0 do
                if sh_rx == 0x01 do
                  phase = 1
                  cmd_i = 0
                  byte_go = 1
                  bstate = 2
                else
                  if c0try == 3 do
                    err_r = 1
                    cs_r = 1
                    bstate = 9
                  else
                    # retry CMD0: CS high, a fresh idle gap, resend
                    c0try = c0try + 1
                    cs_r = 1
                    gap_cnt = 4
                    byte_go = 1
                    bstate = 1
                  end
                end
              end

              if phase == 1 do
                if sh_rx == 0x01 do
                  r7cnt = 0
                  byte_go = 1
                  bstate = 4
                else
                  err_r = 2
                  cs_r = 1
                  bstate = 9
                end
              end

              if phase == 2 do
                phase = 3
                cmd_i = 0
                byte_go = 1
                bstate = 2
              end

              if phase == 3 do
                if sh_rx == 0 do
                  phase = 4
                  sector = LBA
                  cmd_i = 0
                  byte_go = 1
                  bstate = 2
                else
                  aloop = aloop + 1

                  if aloop == 4095 do
                    err_r = 3
                    cs_r = 1
                    bstate = 9
                  else
                    phase = 2
                    cmd_i = 0
                    byte_go = 1
                    bstate = 2
                  end
                end
              end

              if phase == 4 do
                if sh_rx == 0 do
                  tok_cnt = 0
                  byte_go = 1
                  bstate = 5
                else
                  err_r = 4
                  cs_r = 1
                  bstate = 9
                end
              end

              # CMD24 accepted: send the data token, then the sector
              if phase == 5 do
                if sh_rx == 0 do
                  wsub = 0
                  dcnt = 0
                  crc_i = 0
                  wra = wsec * 512
                  byte_go = 1
                  bstate = 10
                else
                  wr_err_r = 1
                  wr_busy_r = 0
                  cs_r = 1
                  bstate = 8
                end
              end
            else
              if tries == 15 do
                if phase == 0 and c0try != 3 do
                  c0try = c0try + 1
                  cs_r = 1
                  gap_cnt = 4
                  byte_go = 1
                  bstate = 1
                else
                  # a CMD24 that never answers fails the WRITE, not the
                  # machine: the image it would have persisted is
                  # already running
                  if phase == 5 do
                    wr_err_r = 1
                    wr_busy_r = 0
                    cs_r = 1
                    bstate = 8
                  else
                    err_r = (phase == 0) * 1 + (phase == 1) * 2 + (phase == 2) * 3 +
                              (phase == 3) * 3 + (phase == 4) * 4
                    cs_r = 1
                    bstate = 9
                  end
                end
              else
                tries = tries + 1
                byte_go = 1
              end
            end
          end

        # CMD8's four extra response bytes (discarded)
        <<4::4>> ->
          if byte_done == 1 do
            if r7cnt == 3 do
              phase = 2
              cmd_i = 0
              byte_go = 1
              bstate = 2
            else
              r7cnt = r7cnt + 1
              byte_go = 1
            end
          end

        # data-token wait (0xFE)
        <<5::4>> ->
          if byte_done == 1 do
            if sh_rx == 0xFE do
              dcnt = 0
              byte_go = 1
              bstate = 6
            else
              tok_cnt = tok_cnt + 1

              if tok_cnt == 8000 do
                err_r = 4
                cs_r = 1
                bstate = 9
              else
                byte_go = 1
              end
            end
          end

        # 512 data bytes — each one feeds the parser
        <<6::4>> ->
          if byte_done == 1 do
            # bad magic aborts. The parser raises it on the fourth byte
            # of a sector-zero read, which is where it can only mean the
            # card holds something that is not a `.pbi` v2 image.
            if pf_bad == 1 do
              err_r = 5
              cs_r = 1
              bstate = 9
            else
              if dcnt == 511 do
                crc_i = 0
                byte_go = 1
                bstate = 7
              else
                dcnt = dcnt + 1
                byte_go = 1
              end
            end
          end

        # two CRC bytes (discarded), then next sector or done
        <<7::4>> ->
          if byte_done == 1 do
            if crc_i == 1 do
              if pf_done == 1 do
                cs_r = 1
                bstate = 8
              else
                sector = sector + 1
                phase = 4
                cmd_i = 0
                byte_go = 1
                bstate = 2
              end
            else
              crc_i = 1
              byte_go = 1
            end
          end

        <<8::4>> ->
          rdone = 1
          bstate = 8

          # an image has landed on the wire and wants to survive a power
          # cycle. The card is already initialised — CMD0/CMD8/ACMD41
          # happened at boot and SPI mode is sticky — so this is just
          # CMD24, once per sector.
          if band(wr_req, bnot(wr_busy_r)) == 1 do
            wr_req = 0
            wsec = 0
            wr_busy_r = 1
            wr_err_r = 0
            sector = LBA
            phase = 5
            cmd_i = 0
            tries = 0
            cs_r = 0
            byte_go = 1
            bstate = 2
          end

        <<9::4>> ->
          bstate = 9

        # data token, then 512 bytes out of the buffer, then two CRC
        # bytes the card ignores (SPI-mode CRC is off unless CMD59 turns
        # it on, and nothing here turns it on)
        <<10::4>> ->
          if byte_done == 1 do
            if wsub == 0 do
              wsub = 1
              # one AHEAD. The byte engine latches `tx_sel` the cycle
              # after `byte_go`, and a sync read delivers the cycle after
              # its address — so the address for byte n+1 has to be
              # standing while byte n is being sent.
              wra = wsec * 512 + 1
              dcnt = 0
              byte_go = 1
            else
              if wsub == 1 do
                if dcnt == 511 do
                  wsub = 2
                  crc_i = 0
                else
                  dcnt = dcnt + 1
                  # read ahead: the engine latches `tx_sel` the cycle
                  # after `byte_go`, and this memory is a sync read
                  wra = wra + 1
                end

                byte_go = 1
              else
                if crc_i == 1 do
                  byte_go = 1
                  bstate = 11
                else
                  crc_i = 1
                  byte_go = 1
                end
              end
            end
          end

        # the data response: xxx0_0101 is "accepted"
        <<11::4>> ->
          if byte_done == 1 do
            if band(sh_rx, 0x1F) == 5 do
              tok_cnt = 0
              byte_go = 1
              bstate = 12
            else
              wr_err_r = 1
              wr_busy_r = 0
              cs_r = 1
              bstate = 8
            end
          end

        # the card holds MISO low while it writes. Wait it out.
        <<12::4>> ->
          if byte_done == 1 do
            if sh_rx == 0 do
              tok_cnt = tok_cnt + 1

              if tok_cnt == 8000 do
                wr_err_r = 1
                wr_busy_r = 0
                cs_r = 1
                bstate = 8
              else
                byte_go = 1
              end
            else
              if wsec + 1 == wsecs do
                wr_busy_r = 0
                wr_done_r = 1
                cs_r = 1
                bstate = 8
              else
                # `wsec` is still the OLD sector on this line: reads in
                # an `on` block see pre-edge values, so the next sector
                # is spelled out rather than derived from the update
                # happening beside it
                wsec = wsec + 1
                sector = LBA + wsec + 1
                phase = 5
                cmd_i = 0
                tries = 0
                byte_go = 1
                bstate = 2
              end
            end
          end
        <<13::4>> -> bstate = 9
        <<14::4>> -> bstate = 9
        <<15::4>> -> bstate = 9
      end
    end
  end

  instance :parse, PicoBEAM.RTL.ImageParser,
    clk: :clk,
    rst: :rst,
    strict: 1,
    byte_en: :pf_en,
    byte: :sh_rx,
    code_en: :code_en,
    code_addr: :code_addr,
    code_data: :code_data,
    pool_en: :pool_en,
    pool_addr: :pool_addr,
    pool_data: :pool_data,
    entry0: :entry0,
    entry1: :entry1,
    complete: :pf_done,
    bad_magic: :pf_bad
end
