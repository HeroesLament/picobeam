defmodule PicoBEAM.RTL.RegWindowCtx do
  @moduledoc """
  M3 pass 4 — `RegWindowRam` with its documented M3 contract cashed in:
  the `ctx` input goes live, the pointer trio becomes a per-context
  file, and the drain unit moves inside and speaks `BarrelSeq`'s
  handshake. Storage layout, port discipline, and the LVT idiom are
  unchanged — exactly what the M2 moduledoc promised would and would
  not move.

  ## Addressing

  Address = `{ctx:2, slot:2, reg:4}` → depth 256 per RAM. Storage is
  21 sync-read EBRs (DP16KD, Probe A), NOT distributed RAM: the async
  variant was built first and measured 26.8K LUT4 + 3,024 DPR16X4 —
  the 256-deep DPR cascade resurrects the mux forests the M2 rebuild
  killed, at 5× the whole M2 engine. The barrel makes the sync read
  free: addresses present in D, the EBR output register IS the D→X
  operand register, and the LVT bank selects (computed combinationally
  in D from the pointer/LVT registers) pipeline alongside (`lsr*`) to
  steer the registered bank outputs in X. 21 of the 85F's 208 EBRs.

  * **Reads (D stage)**: `rd_ctx` (the D seat) + 6 addresses; data is
    async and registers into X at the engine's D→X boundary.
  * **Writes (X stage)**: `w_ctx` (the X seat) + the 3 unified ports,
    `w_stg` routing to the staging slot as before. The ret-fill and
    dest writes arrive through port 0 on the owner's X turns
    (`BarrelSeq`'s pacing), so w_ctx covers them too — no extra port.

  ## The LVT splits per context

  One 512-bit LVT would put 9-bit variable shifts on every port.
  Instead: FOUR 128-bit LVTs (one per context), indexed by the LOCAL
  `{slot:2, reg:4}` — the M2 shift widths survive verbatim — plus a
  4:1 context mux per port. Reads use `rd_ctx`'s LVT (drain uses the
  draining context's), the RMW update lands on `w_ctx`'s. Only one
  context's LVT is written per cycle (there is one X seat), so the
  single-writer discipline holds per register.

  ## The drain unit lives here now

  `op_call`/`call_ctx` (BarrelSeq's `call_commit`/`commit_seat`)
  rotates that context's pointers — old cur drains IN PLACE as spl,
  old stg is the new window, the drained slot becomes fresh staging —
  and starts the 16-cycle background drain of `spl[call_ctx]` through
  the dedicated 7th read replica. `drain_ready` gates the next commit,
  `drain_done`/`drain_done_seat` pulse on the last word (the same
  cycle its FrameRam write commits), and `spill_*` feed FrameRam as
  in M2, now with `spill_seat` for the per-process region addressing
  that pass 5 adds. One drain at a time, claimed at F slots — no
  arbiter, per the barrel's rule.

  `op_tail`/`tail_ctx` swaps cur/stg (same-bundle writes stay moot,
  as M2). Reset returns every context to cur=0, stg=1, spl=2.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # D-stage reads
  input :rd_ctx, 2
  input :rd_addr0, 4
  input :rd_addr1, 4
  input :rd_addr2, 4
  input :rd_addr3, 4
  input :rd_addr4, 4
  input :rd_addr5, 4
  # read port 0 reads the STAGING bank instead of the current one.
  # `w_stg0` has always existed on the write side; the read side never
  # needed it until the collector had to enumerate `out_args` as roots
  # (`notes/40`). One mux on one address, not an eighth replica.
  input :rd_stg0, 1
  output :rd_data0, 36
  output :rd_data1, 36
  output :rd_data2, 36
  output :rd_data3, 36
  output :rd_data4, 36
  output :rd_data5, 36

  # X-stage writes
  input :w_ctx, 2
  input :w_en0, 1
  input :w_stg0, 1
  input :w_addr0, 4
  input :w_data0, 36
  input :w_en1, 1
  input :w_stg1, 1
  input :w_addr1, 4
  input :w_data1, 36
  input :w_en2, 1
  input :w_stg2, 1
  input :w_addr2, 4
  input :w_data2, 36

  # pointer ops
  input :op_call, 1
  input :call_ctx, 2
  input :op_tail, 1
  input :tail_ctx, 2
  # swap-out: drain a seat's CURRENT window (not the spill slot) with no
  # rename — the seat unit's save path, reusing the drain replica rather
  # than paying for an eighth
  input :op_swap, 1
  input :swap_ctx, 2
  # spawn-stage: drain a seat's STAGING slot (the newborn's args), also
  # with no rename. Third source on the one drain replica; the three are
  # mutually exclusive because each is claimed at an F slot.
  input :op_spawn, 1
  input :spawn_ctx, 2

  # drain handshake + spill stream
  output :drain_ready, 1
  output :drain_done, 1
  output :drain_done_seat, 2
  output :spill_valid, 1
  output :spill_idx, 4
  output :spill_data, 36
  output :spill_seat, 2

  # 3 banks x 7 readers, depth 256 = {ctx:2, slot:2, reg:4}
  memory :b0r0, width: 36, depth: 256, sync_read: :clk
  memory :b0r1, width: 36, depth: 256, sync_read: :clk
  memory :b0r2, width: 36, depth: 256, sync_read: :clk
  memory :b0r3, width: 36, depth: 256, sync_read: :clk
  memory :b0r4, width: 36, depth: 256, sync_read: :clk
  memory :b0r5, width: 36, depth: 256, sync_read: :clk
  memory :b0r6, width: 36, depth: 256, sync_read: :clk
  memory :b1r0, width: 36, depth: 256, sync_read: :clk
  memory :b1r1, width: 36, depth: 256, sync_read: :clk
  memory :b1r2, width: 36, depth: 256, sync_read: :clk
  memory :b1r3, width: 36, depth: 256, sync_read: :clk
  memory :b1r4, width: 36, depth: 256, sync_read: :clk
  memory :b1r5, width: 36, depth: 256, sync_read: :clk
  memory :b1r6, width: 36, depth: 256, sync_read: :clk
  memory :b2r0, width: 36, depth: 256, sync_read: :clk
  memory :b2r1, width: 36, depth: 256, sync_read: :clk
  memory :b2r2, width: 36, depth: 256, sync_read: :clk
  memory :b2r3, width: 36, depth: 256, sync_read: :clk
  memory :b2r4, width: 36, depth: 256, sync_read: :clk
  memory :b2r5, width: 36, depth: 256, sync_read: :clk
  memory :b2r6, width: 36, depth: 256, sync_read: :clk

  # per-context pointer file
  wire :cur0, 2, init: 0
  wire :stg0, 2, init: 1
  wire :spl0, 2, init: 2
  wire :cur1, 2, init: 0
  wire :stg1, 2, init: 1
  wire :spl1, 2, init: 2
  wire :cur2, 2, init: 0
  wire :stg2, 2, init: 1
  wire :spl2, 2, init: 2
  wire :cur3, 2, init: 0
  wire :stg3, 2, init: 1
  wire :spl3, 2, init: 2

  # per-context LVTs
  wire :lvt0, 128, init: 0
  wire :lvt1, 128, init: 0
  wire :lvt2, 128, init: 0
  wire :lvt3, 128, init: 0

  # drain unit
  wire :drain_ctx, 2, init: 0
  wire :drain_cnt, 5, init: 16
  # which pointer this drain reads: 0 = spl (call spill), 1 = cur
  # (swap-out save), 2 = stg (spawn arg staging)
  wire :drain_src, 2, init: 0

  # comb: selected pointers
  wire :rcur, 2
  wire :wcur, 2
  wire :wstg, 2
  wire :dspl, 2
  wire :dcur, 2
  wire :dstg, 2
  wire :dspl_r, 2
  wire :lvt_r, 128
  wire :lvt_w, 128
  wire :lvt_d, 128

  # full and local addresses
  wire :ra0, 8
  wire :ra1, 8
  wire :ra2, 8
  wire :ra3, 8
  wire :ra4, 8
  wire :ra5, 8
  wire :ra6, 8
  wire :la0, 6
  wire :rstg, 2
  wire :la1, 6
  wire :la2, 6
  wire :la3, 6
  wire :la4, 6
  wire :la5, 6
  wire :la6, 6
  wire :wf0, 8
  wire :wf1, 8
  wire :wf2, 8
  wire :wl0, 6
  wire :wl1, 6
  wire :wl2, 6
  wire :we0, 1
  wire :we1, 1
  wire :we2, 1

  wire :ls0, 2
  wire :ls1, 2
  wire :ls2, 2
  wire :ls3, 2
  wire :ls4, 2
  wire :ls5, 2
  wire :ls6, 2

  # D→X pipeline: bank selects ride beside the EBR output registers
  wire :lsr0, 2, init: 0
  wire :lsr1, 2, init: 0
  wire :lsr2, 2, init: 0
  wire :lsr3, 2, init: 0
  wire :lsr4, 2, init: 0
  wire :lsr5, 2, init: 0
  wire :lsr6, 2, init: 0
  # spill stream alignment (data lags the counter by the sync read)
  wire :sv_d, 1, init: 0
  wire :si_d, 4, init: 0
  wire :ss_d, 2, init: 0

  wire :lvt_a, 128
  wire :lvt_b, 128
  wire :lvt_c, 128

  comb do
    drain_ready = drain_cnt == 16
    # done pulses as the LAST data word arrives (one cycle behind the
    # address counter — the sync read); its FrameRam write commits on
    # that same edge, so a dp-cleared ret can never outrun the frame
    drain_done = band(sv_d, si_d == 15)
    drain_done_seat = ss_d
    spill_valid = sv_d
    spill_idx = si_d
    spill_seat = ss_d

    rcur = (rd_ctx == 0) * cur0 + (rd_ctx == 1) * cur1 + (rd_ctx == 2) * cur2 + (rd_ctx == 3) * cur3
    rstg = (rd_ctx == 0) * stg0 + (rd_ctx == 1) * stg1 + (rd_ctx == 2) * stg2 + (rd_ctx == 3) * stg3
    wcur = (w_ctx == 0) * cur0 + (w_ctx == 1) * cur1 + (w_ctx == 2) * cur2 + (w_ctx == 3) * cur3
    wstg = (w_ctx == 0) * stg0 + (w_ctx == 1) * stg1 + (w_ctx == 2) * stg2 + (w_ctx == 3) * stg3

    dcur =
      (drain_ctx == 0) * cur0 + (drain_ctx == 1) * cur1 + (drain_ctx == 2) * cur2 +
        (drain_ctx == 3) * cur3

    dspl_r =
      (drain_ctx == 0) * spl0 + (drain_ctx == 1) * spl1 + (drain_ctx == 2) * spl2 +
        (drain_ctx == 3) * spl3

    dstg =
      (drain_ctx == 0) * stg0 + (drain_ctx == 1) * stg1 + (drain_ctx == 2) * stg2 +
        (drain_ctx == 3) * stg3

    dspl = (drain_src == 0) * dspl_r + (drain_src == 1) * dcur + (drain_src == 2) * dstg

    lvt_r = (rd_ctx == 0) * lvt0 + (rd_ctx == 1) * lvt1 + (rd_ctx == 2) * lvt2 + (rd_ctx == 3) * lvt3
    lvt_w = (w_ctx == 0) * lvt0 + (w_ctx == 1) * lvt1 + (w_ctx == 2) * lvt2 + (w_ctx == 3) * lvt3

    lvt_d =
      (drain_ctx == 0) * lvt0 + (drain_ctx == 1) * lvt1 + (drain_ctx == 2) * lvt2 +
        (drain_ctx == 3) * lvt3

    # local {slot, reg} addresses (LVT index) and full RAM addresses
    la0 = (rd_stg0 * rstg + band(bnot(rd_stg0), 1) * rcur) * 16 + rd_addr0
    la1 = rcur * 16 + rd_addr1
    la2 = rcur * 16 + rd_addr2
    la3 = rcur * 16 + rd_addr3
    la4 = rcur * 16 + rd_addr4
    la5 = rcur * 16 + rd_addr5
    la6 = dspl * 16 + drain_cnt[3..0]
    ra0 = rd_ctx * 64 + la0
    ra1 = rd_ctx * 64 + la1
    ra2 = rd_ctx * 64 + la2
    ra3 = rd_ctx * 64 + la3
    ra4 = rd_ctx * 64 + la4
    ra5 = rd_ctx * 64 + la5
    ra6 = drain_ctx * 64 + la6

    wl0 = (w_stg0 * wstg + bnot(w_stg0) * wcur) * 16 + w_addr0
    wl1 = (w_stg1 * wstg + bnot(w_stg1) * wcur) * 16 + w_addr1
    wl2 = (w_stg2 * wstg + bnot(w_stg2) * wcur) * 16 + w_addr2
    wf0 = w_ctx * 64 + wl0
    wf1 = w_ctx * 64 + wl1
    wf2 = w_ctx * 64 + wl2

    we0 = band(w_en0, bnot(op_tail))
    we1 = band(w_en1, bnot(op_tail))
    we2 = band(w_en2, bnot(op_tail))

    ls0 = band(lvt_r >>> (la0 * 2), 3)
    ls1 = band(lvt_r >>> (la1 * 2), 3)
    ls2 = band(lvt_r >>> (la2 * 2), 3)
    ls3 = band(lvt_r >>> (la3 * 2), 3)
    ls4 = band(lvt_r >>> (la4 * 2), 3)
    ls5 = band(lvt_r >>> (la5 * 2), 3)
    ls6 = band(lvt_d >>> (la6 * 2), 3)

    rd_data0 = (lsr0 == 0) * b0r0[ra0] + (lsr0 == 1) * b1r0[ra0] + (lsr0 == 2) * b2r0[ra0]
    rd_data1 = (lsr1 == 0) * b0r1[ra1] + (lsr1 == 1) * b1r1[ra1] + (lsr1 == 2) * b2r1[ra1]
    rd_data2 = (lsr2 == 0) * b0r2[ra2] + (lsr2 == 1) * b1r2[ra2] + (lsr2 == 2) * b2r2[ra2]
    rd_data3 = (lsr3 == 0) * b0r3[ra3] + (lsr3 == 1) * b1r3[ra3] + (lsr3 == 2) * b2r3[ra3]
    rd_data4 = (lsr4 == 0) * b0r4[ra4] + (lsr4 == 1) * b1r4[ra4] + (lsr4 == 2) * b2r4[ra4]
    rd_data5 = (lsr5 == 0) * b0r5[ra5] + (lsr5 == 1) * b1r5[ra5] + (lsr5 == 2) * b2r5[ra5]
    spill_data = (lsr6 == 0) * b0r6[ra6] + (lsr6 == 1) * b1r6[ra6] + (lsr6 == 2) * b2r6[ra6]

    # staged LVT next-value for the writing context (local indices)
    lvt_a = we0 * band(lvt_w, bnot(3 <<< (wl0 * 2))) + bnot(we0) * lvt_w
    lvt_b = we1 * bor(band(lvt_a, bnot(3 <<< (wl1 * 2))), 1 <<< (wl1 * 2)) + bnot(we1) * lvt_a
    lvt_c = we2 * bor(band(lvt_b, bnot(3 <<< (wl2 * 2))), 2 <<< (wl2 * 2)) + bnot(we2) * lvt_b
  end

  on :clk do
    if rst == 1 do
      cur0 = 0
      stg0 = 1
      spl0 = 2
      cur1 = 0
      stg1 = 1
      spl1 = 2
      cur2 = 0
      stg2 = 1
      spl2 = 2
      cur3 = 0
      stg3 = 1
      spl3 = 2
      lvt0 = 0
      lvt1 = 0
      lvt2 = 0
      lvt3 = 0
      drain_ctx = 0
      drain_cnt = 16
      drain_src = 0
      sv_d = 0
      si_d = 0
      ss_d = 0
    else
      # D→X pipeline registers: bank selects + spill alignment
      lsr0 = ls0
      lsr1 = ls1
      lsr2 = ls2
      lsr3 = ls3
      lsr4 = ls4
      lsr5 = ls5
      lsr6 = ls6
      sv_d = drain_cnt < 16
      si_d = drain_cnt[3..0]
      ss_d = drain_ctx

      # the writing context's LVT takes the staged update
      if w_ctx == 0 do
        lvt0 = lvt_c
      end

      if w_ctx == 1 do
        lvt1 = lvt_c
      end

      if w_ctx == 2 do
        lvt2 = lvt_c
      end

      if w_ctx == 3 do
        lvt3 = lvt_c
      end

      # swap-out: claim the drain against cur[swap_ctx], no rename
      if op_swap == 1 do
        drain_ctx = swap_ctx
        drain_cnt = 0
        drain_src = 1
      end

      # spawn: claim the drain against stg[spawn_ctx], no rename
      if op_spawn == 1 do
        drain_ctx = spawn_ctx
        drain_cnt = 0
        drain_src = 2
      end

      # pointer rename on commit; drain claims spl[call_ctx]
      if op_call == 1 do
        drain_ctx = call_ctx
        drain_cnt = 0
        drain_src = 0

        if call_ctx == 0 do
          spl0 = cur0
          cur0 = stg0
          stg0 = spl0
        end

        if call_ctx == 1 do
          spl1 = cur1
          cur1 = stg1
          stg1 = spl1
        end

        if call_ctx == 2 do
          spl2 = cur2
          cur2 = stg2
          stg2 = spl2
        end

        if call_ctx == 3 do
          spl3 = cur3
          cur3 = stg3
          stg3 = spl3
        end
      else
        if bnot(bor(op_swap, op_spawn)) == 1 do
          if drain_cnt < 16 do
            drain_cnt = drain_cnt + 1
          end
        end
      end

      if op_tail == 1 do
        if tail_ctx == 0 do
          cur0 = stg0
          stg0 = cur0
        end

        if tail_ctx == 1 do
          cur1 = stg1
          stg1 = cur1
        end

        if tail_ctx == 2 do
          cur2 = stg2
          stg2 = cur2
        end

        if tail_ctx == 3 do
          cur3 = stg3
          stg3 = cur3
        end
      end

      if we0 == 1 do
        b0r0[wf0] = w_data0
        b0r1[wf0] = w_data0
        b0r2[wf0] = w_data0
        b0r3[wf0] = w_data0
        b0r4[wf0] = w_data0
        b0r5[wf0] = w_data0
        b0r6[wf0] = w_data0
      end

      if we1 == 1 do
        b1r0[wf1] = w_data1
        b1r1[wf1] = w_data1
        b1r2[wf1] = w_data1
        b1r3[wf1] = w_data1
        b1r4[wf1] = w_data1
        b1r5[wf1] = w_data1
        b1r6[wf1] = w_data1
      end

      if we2 == 1 do
        b2r0[wf2] = w_data2
        b2r1[wf2] = w_data2
        b2r2[wf2] = w_data2
        b2r3[wf2] = w_data2
        b2r4[wf2] = w_data2
        b2r5[wf2] = w_data2
        b2r6[wf2] = w_data2
      end
    end
  end
end
