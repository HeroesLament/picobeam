defmodule PicoBEAM.RTL.DbgUart do
  @moduledoc """
  Bring-up debug streamer — engine state as ASCII hex over the FTDI
  UART, ~15 lines/s at 115200 8N1:

      pPPP S FL CC AAA LLL Q E OO WD XX NN\\r\\n

  PPP = pc (3 hex digits) · S = sequencer state · FL = flags nibble
  {idle, abnormal-death-seen, x_en, out_seen} · CC = occupancy ·
  AAA = sends · LLL = recvs · Q = run-queue count · E = evicts ·
  OO = last out value (low byte) · W = deaths low nibble ·
  D = seat-3 state · XX = the LAST ABNORMAL DEATH's reason ·
  NN = how many abnormal deaths there have been.

  `XX`/`NN` are the pair that matter, and they are why this format
  changed. The `FL` fault bit is sticky and machine-wide: in a language
  where supervised children are SUPPOSED to die it goes high during
  normal operation and never comes down, so on its own it cannot tell a
  supervisor doing its job from a crash loop. `NN` climbing steadily is
  the second of those; `NN` frozen at 1 is the first. `XX` says what
  they died OF — the reason the process actually died of, not the
  X-stage fault reason, which reads `normal` for anything killed by a
  signal.

  The `CC` field was labelled `RR = fault reason` here and was in fact
  wired to occupancy at the top: until now the reason had no path
  off-chip at all. The two 3-digit fields (`rt1`, `rtl`) are FULL
  12-bit counters — they started as 9-bit pc taps and were widened when
  the thousand-spawn demo needed to display a four-digit count. A snapshot is latched at line start so every
  line is a consistent view.

  Read it on the Mac:  screen /dev/tty.usbserial-*01 115200
  (close screen before running fujprog — same FTDI).
  """

  use Hw.Component

  clock :clk, freq: 12.0

  input :rst, 1
  input :pc, 9
  # five bits since `notes/32` added the catch landing as state 20; the
  # line still prints one nibble, because a 20-state field in one hex
  # character was always a lossy display and widening the FORMAT is a
  # different decision from widening the SIGNAL
  input :sstate, 5
  input :flags, 4
  input :fr, 8
  input :outv, 16
  input :fp, 6
  input :sdst, 5
  input :rt1, 12
  input :rt2, 9
  input :rcnt, 4
  input :rtl, 12
  input :ocnt, 4
  # the last abnormal death's reason, and how many there have been
  input :frr, 8
  input :fcnt, 8

  output :txd, 1

  wire :tx_data, 8
  wire :tx_valid, 1, init: 0
  wire :tx_ready, 1

  # snapshot latches
  wire :l_pc, 9, init: 0
  wire :l_st, 5, init: 0
  wire :l_fl, 4, init: 0
  wire :l_fr, 8, init: 0
  wire :l_out, 16, init: 0
  wire :l_fp, 6, init: 0
  wire :l_sd, 5, init: 0
  wire :l_r1, 12, init: 0
  wire :l_r2, 9, init: 0
  wire :l_rc, 4, init: 0
  wire :l_rl, 12, init: 0
  wire :l_oc, 4, init: 0
  wire :l_xr, 8, init: 0
  wire :l_fn, 8, init: 0

  wire :pace, 20, init: 0
  wire :ci, 6, init: 63
  wire :nib, 4
  wire :hexch, 8
  wire :ch, 8
  wire :is_sp, 1
  wire :is_lit, 1

  comb do
    # line: pPPP S F RR AAA LLL C O OO WD\r\n
    # (A = first ret target, L = LAST ret target, C = ret count,
    #  O = out-pulse count)
    nib =
      (ci == 1) * l_pc[8..8] + (ci == 2) * l_pc[7..4] + (ci == 3) * l_pc[3..0] +
        (ci == 5) * l_st[3..0] +
        (ci == 7) * l_fl +
        (ci == 9) * l_fr[7..4] + (ci == 10) * l_fr[3..0] +
        (ci == 12) * l_r1[11..8] + (ci == 13) * l_r1[7..4] + (ci == 14) * l_r1[3..0] +
        (ci == 16) * l_rl[11..8] + (ci == 17) * l_rl[7..4] + (ci == 18) * l_rl[3..0] +
        (ci == 20) * l_rc +
        (ci == 22) * l_oc +
        (ci == 24) * l_out[7..4] + (ci == 25) * l_out[3..0] +
        (ci == 27) * l_fp[3..0] +
        (ci == 28) * l_sd[3..0] +
        (ci == 30) * l_xr[7..4] + (ci == 31) * l_xr[3..0] +
        (ci == 33) * l_fn[7..4] + (ci == 34) * l_fn[3..0]

    hexch = (nib < 10) * (48 + nib) + bnot(nib < 10) * (87 + nib)

    # spaces at 4,6,8,11,15,19,21,23,26,29,32; 'p' at 0; CR/LF at 35/36
    is_sp =
      bor(ci == 4,
        bor(ci == 6,
          bor(ci == 8,
            bor(ci == 11,
              bor(ci == 15,
                bor(ci == 19,
                  bor(ci == 21,
                    bor(ci == 23, bor(ci == 26, bor(ci == 29, ci == 32))))))))))

    is_lit = bor(ci == 0, bor(is_sp, bor(ci == 35, ci == 36)))

    ch =
      (ci == 0) * 112 + is_sp * 32 +
        (ci == 35) * 13 + (ci == 36) * 10 +
        bnot(is_lit) * hexch

    tx_data = ch
  end

  on :clk do
    tx_valid = 0

    if rst == 1 do
      ci = 63
      pace = 0
    else
      pace = pace + 1

      if ci == 63 do
        # idle: wait the pace interval, then latch a snapshot
        if pace == 0 do
          l_pc = pc
          l_st = sstate
          l_fl = flags
          l_fr = fr
          l_out = outv
          l_fp = fp
          l_sd = sdst
          l_r1 = rt1
          l_r2 = rt2
          l_rc = rcnt
          l_rl = rtl
          l_oc = ocnt
          l_xr = frr
          l_fn = fcnt
          ci = 0
        end
      else
        # offer character ci; ci advances only AFTER the offer cycle, so
        # tx_data (comb over ci) is stable when the transmitter latches
        if tx_valid == 1 do
          if ci == 36 do
            ci = 63
          else
            ci = ci + 1
          end
        else
          if tx_ready == 1 do
            tx_valid = 1
          end
        end
      end
    end
  end

  instance :tx, Hw.UART.TX,
    CLK_FREQ: 12_000_000,
    BAUD_RATE: 115_200,
    clk: :clk,
    rst: :rst,
    data: :tx_data,
    valid: :tx_valid,
    ready: :tx_ready,
    txd: :txd
end
