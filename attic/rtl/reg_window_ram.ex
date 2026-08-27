defmodule PicoBEAM.RTL.RegWindowRam do
  @moduledoc """
  Probe C part 2 / M3 brick — the register window rebuilt on LUT-RAM,
  context-indexed, with POINTER-RENAMED frames.

  ## Why the flop version lost

  `RegWindow` (kept as the measured baseline) holds three 16x36 frames
  in flops: 10.9K LUT4 standalone, and every frame exchange is a
  576-bit parallel copy. This rebuild changes both facts:

    * **Storage is LUT-RAM.** Each context owns a pool of FOUR 16-word
      frame slots (address = `{ctx, slot:2, reg:4}`); a frame is one
      native DPR16X4 depth, so the 16:1 read muxes become RAM
      addressing.
    * **`call` renames, it does not copy.** cur/stg/spl are 2-bit slot
      pointers; call rotates them (old cur drains IN PLACE as spl, old
      stg IS the new window, the drained slot becomes fresh staging)
      and `tailcall` swaps cur/stg. Zero data movement on the 1-cycle
      call path; the background drain and the ret-fill are unchanged
      contracts with `FrameRam`.

  ## Ports: 3 unified write ports, 6 reads, 1 drain

  A bundle has at most three ops, and each op carries at most ONE
  register-file write — a slot result (→ current) or an `arg`
  (→ staging). So three write ports with a `to_stg` flag cover
  everything the flop design needed nine for; port 0 additionally
  carries the phase-disjoint ret-fill and dest writes (the engine's
  one-hot mux, as before). Multi-write banking: one RAM bank per write
  port, replicated per read port (3 banks x 7 readers = 21 RAMs), with
  a live-value table — `lvt`, 2 bits per word — held in ONE wide
  register and read/written through variable shifts rather than a
  64-way mux forest.

  ## Context indexing (the M3 contract)

  `ctx` selects the pool; at M2 it is tied to 0 and the pool count is
  one. At M3 the barrel presents the rotating context id and the
  pointer trio becomes a per-context array — the storage layout,
  addressing, and port discipline here do not change, only the pointer
  file widens. T multiplies RAM depth (cheap), not mux width: that is
  the property the flop design lacked and the reason this file exists.

  Single-assignment staging semantics are unchanged: a freshly renamed
  staging slot holds stale words; only what `arg` wrote may be read
  (the model enforces this; hardware does not).
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1
  # context select — tie 0 at M2; the barrel drives it at M3
  input :ctx, 1

  input :rd_addr0, 4
  input :rd_addr1, 4
  input :rd_addr2, 4
  input :rd_addr3, 4
  input :rd_addr4, 4
  input :rd_addr5, 4
  output :rd_data0, 36
  output :rd_data1, 36
  output :rd_data2, 36
  output :rd_data3, 36
  output :rd_data4, 36
  output :rd_data5, 36

  # unified write ports: to_stg routes to the staging slot (arg), else
  # the current slot (results, ret-fill, dest write)
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

  input :op_call, 1
  input :op_tail, 1

  output :spill_valid, 1
  output :spill_idx, 4
  output :spill_data, 36
  output :ready, 1

  # 3 banks x 7 readers (6 bundle reads + the drain). depth 64 =
  # {slot:2, reg:4} per context; T contexts multiply depth at M3.
  memory :b0r0, width: 36, depth: 64
  memory :b0r1, width: 36, depth: 64
  memory :b0r2, width: 36, depth: 64
  memory :b0r3, width: 36, depth: 64
  memory :b0r4, width: 36, depth: 64
  memory :b0r5, width: 36, depth: 64
  memory :b0r6, width: 36, depth: 64
  memory :b1r0, width: 36, depth: 64
  memory :b1r1, width: 36, depth: 64
  memory :b1r2, width: 36, depth: 64
  memory :b1r3, width: 36, depth: 64
  memory :b1r4, width: 36, depth: 64
  memory :b1r5, width: 36, depth: 64
  memory :b1r6, width: 36, depth: 64
  memory :b2r0, width: 36, depth: 64
  memory :b2r1, width: 36, depth: 64
  memory :b2r2, width: 36, depth: 64
  memory :b2r3, width: 36, depth: 64
  memory :b2r4, width: 36, depth: 64
  memory :b2r5, width: 36, depth: 64
  memory :b2r6, width: 36, depth: 64

  # role pointers (per-context array at M3)
  wire :cur, 2, init: 0
  wire :stg, 2, init: 1
  wire :spl, 2, init: 2

  wire :drain_cnt, 5, init: 16

  # live-value table: 2 bits per word, one wide register, shift-indexed
  wire :lvt, 128, init: 0

  # full addresses
  wire :ra0, 6
  wire :ra1, 6
  wire :ra2, 6
  wire :ra3, 6
  wire :ra4, 6
  wire :ra5, 6
  wire :ra6, 6
  wire :wf0, 6
  wire :wf1, 6
  wire :wf2, 6
  wire :we0, 1
  wire :we1, 1
  wire :we2, 1

  # per-read-port lvt selects
  wire :ls0, 2
  wire :ls1, 2
  wire :ls2, 2
  wire :ls3, 2
  wire :ls4, 2
  wire :ls5, 2
  wire :ls6, 2

  # staged lvt update
  wire :lvt_a, 128
  wire :lvt_b, 128
  wire :lvt_c, 128

  comb do
    ready = drain_cnt == 16
    spill_valid = drain_cnt < 16
    spill_idx = drain_cnt[3..0]

    ra0 = cur * 16 + rd_addr0
    ra1 = cur * 16 + rd_addr1
    ra2 = cur * 16 + rd_addr2
    ra3 = cur * 16 + rd_addr3
    ra4 = cur * 16 + rd_addr4
    ra5 = cur * 16 + rd_addr5
    ra6 = spl * 16 + drain_cnt[3..0]

    wf0 = (w_stg0 * stg + bnot(w_stg0) * cur) * 16 + w_addr0
    wf1 = (w_stg1 * stg + bnot(w_stg1) * cur) * 16 + w_addr1
    wf2 = (w_stg2 * stg + bnot(w_stg2) * cur) * 16 + w_addr2

    # same-bundle writes with tailcall are moot (window replaced)
    we0 = band(w_en0, bnot(op_tail))
    we1 = band(w_en1, bnot(op_tail))
    we2 = band(w_en2, bnot(op_tail))

    ls0 = band(lvt >>> (ra0 * 2), 3)
    ls1 = band(lvt >>> (ra1 * 2), 3)
    ls2 = band(lvt >>> (ra2 * 2), 3)
    ls3 = band(lvt >>> (ra3 * 2), 3)
    ls4 = band(lvt >>> (ra4 * 2), 3)
    ls5 = band(lvt >>> (ra5 * 2), 3)
    ls6 = band(lvt >>> (ra6 * 2), 3)

    rd_data0 = (ls0 == 0) * b0r0[ra0] + (ls0 == 1) * b1r0[ra0] + (ls0 == 2) * b2r0[ra0]
    rd_data1 = (ls1 == 0) * b0r1[ra1] + (ls1 == 1) * b1r1[ra1] + (ls1 == 2) * b2r1[ra1]
    rd_data2 = (ls2 == 0) * b0r2[ra2] + (ls2 == 1) * b1r2[ra2] + (ls2 == 2) * b2r2[ra2]
    rd_data3 = (ls3 == 0) * b0r3[ra3] + (ls3 == 1) * b1r3[ra3] + (ls3 == 2) * b2r3[ra3]
    rd_data4 = (ls4 == 0) * b0r4[ra4] + (ls4 == 1) * b1r4[ra4] + (ls4 == 2) * b2r4[ra4]
    rd_data5 = (ls5 == 0) * b0r5[ra5] + (ls5 == 1) * b1r5[ra5] + (ls5 == 2) * b2r5[ra5]
    spill_data = (ls6 == 0) * b0r6[ra6] + (ls6 == 1) * b1r6[ra6] + (ls6 == 2) * b2r6[ra6]

    # lvt next-value: clear each written word's code, then set the bank
    lvt_a = we0 * band(lvt, bnot(3 <<< (wf0 * 2))) + bnot(we0) * lvt
    lvt_b = we1 * bor(band(lvt_a, bnot(3 <<< (wf1 * 2))), 1 <<< (wf1 * 2)) + bnot(we1) * lvt_a
    lvt_c = we2 * bor(band(lvt_b, bnot(3 <<< (wf2 * 2))), 2 <<< (wf2 * 2)) + bnot(we2) * lvt_b
  end

  on :clk do
    if rst == 1 do
      cur = 0
      stg = 1
      spl = 2
      drain_cnt = 16
      lvt = 0
    else
      lvt = lvt_c

      if op_call == 1 do
        # the rename: old cur drains in place, old stg is the window,
        # the drained slot is fresh staging
        spl = cur
        cur = stg
        stg = spl
        drain_cnt = 0
      else
        if op_tail == 1 do
          cur = stg
          stg = cur
        end

        if drain_cnt < 16 do
          drain_cnt = drain_cnt + 1
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
