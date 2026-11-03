defmodule PicoBEAM.RTL.FrameRamProc do
  @moduledoc """
  M3 pass 5 — the frame store grows a PER-PROCESS dimension.

  M2's `FrameRam` held one process's frame stack (`fp` counted frames,
  32 deep). The barrel runs T resident processes and the proc table
  rosters 32, so frames are now per-process stack regions:

      word address = {slot:5, depth:4, idx:4}   → 8192 x 36 (16 DP16KD)
      link address = {slot:5, depth:4}          → 512 x 13 (distributed)

  32 slots x 15 frames deep. Call depth past 15 is `:stack_overflow` —
  a reserved-atom fault (`notes/13`), surfaced here as a combinational
  `overflow` for the engine's fault chain. The 8-deep bound is the
  v1 sizing choice recorded in `notes/16`; widening `depth` is a
  memory-count decision, not a structural one.

  ## Seats address the window; SLOTS address the frames

  `RegWindowCtx` is indexed by seat (a barrel position); this store is
  indexed by proc-table slot (a process identity), because a frame
  stack outlives any particular seat — that is the whole point of the
  swap unit that pass 6 adds. The engine carries the seat→slot binding
  (the seat file) and presents slot ids here. Until then the testbench
  presents them directly.

  ## One depth counter file, one write site

  Depths live in ONE 128-bit register (32 x 4 bits, shift-indexed —
  the LVT idiom from the register window) rather than a replicated
  memory. That is affordable because `push_en` and `pop_en` are
  mutually exclusive BY CONSTRUCTION: both are `BarrelSeq` F-slot
  claims, one F owner exists per cycle, and a context parked for call
  is not parked for ret. So one read port serves both (`op_slot`) and
  one write site updates the file — the single-writer discipline holds
  without an arbiter, again.

  ## Push / spill / pop / fill

  * **push** (`call_commit`): claims the frame at the slot's current
    depth, records the link there (`pc:9 | dest:4`, lockstep with the
    frame by construction — there is no separate return stack to
    desynchronize), and increments the depth. `sp_slot`/`sp_depth`
    latch the claimed frame so the drain that follows lands in it;
    `drain_ready` guarantees no second push can steal the latch.
  * **spill** (`RegWindowCtx.spill_*`): 16 words into the claimed frame.
  * **pop** (`pop_en`): decrements the slot's depth. Pop-then-read, as
    M2: after the pop the caller's frame IS the one at the new depth,
    and so is its link.
  * **fill** (`fill_en`/`fill_idx`, paced one word per owner turn by
    `BarrelSeq`): sync read of `{fill_slot, depth, idx}` — the data
    lands the next cycle, which is the owner's X slot, which is when
    the engine writes window port 0. The M2 one-cycle write delay is
    exactly this read latency; the barrel makes it free.

  `ret_pc_out`/`ret_dest_out` read the popped frame's link
  combinationally (distributed `rets`) and hold for the whole fill
  stream, so `BarrelSeq` can consume them at `dest_wr` ~18 turns later.

  ## Two things `notes/31` and `notes/32` added

  **`q_slot`/`q_depth`** is a third, read-only view of the depth file,
  addressed by whatever slot the caller names. The X stage needs it:
  `ret` at depth 0 is a process ENDING, not a return, and `call` at
  depth 15 is `:stack_overflow` — both have to be known before the pop
  or push is claimed. `depth_out` cannot answer either, because it is
  keyed by `fill_slot`, which belongs to the context streaming a fill
  eighteen turns later.

  **`pop_abs`/`pop_to`** makes a pop land on a named depth instead of
  one frame down. A `try` that catches a fault raised several calls
  deep discards all of those frames at once, and the fill that follows
  then reads the window the try-owner spilled when it made the call —
  which is exactly what the handler is entitled to see.

  `overflow` and `underflow` were declared here from pass 5 and read by
  nobody until `notes/31`. `overflow` is now the machine's
  `:stack_overflow`; `underflow` is redundant, because `q_depth`
  catches the same condition a turn earlier and does something about it.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # push side — the call commit's frame claim + link record
  input :push_en, 1
  input :push_slot, 5
  input :push_pc, 12
  input :push_dest, 4

  # spill stream from the register window's drain unit
  input :spill_valid, 1
  input :spill_idx, 4
  input :spill_data, 36

  # pop side — the ret claim
  input :pop_en, 1
  input :pop_slot, 5
  # `pop_abs` makes the pop land on `pop_to` instead of one frame down.
  # A `try` that catches a fault raised several calls deep has to
  # discard all of those frames at once, and one pop that names its
  # destination is the whole of it — the fill that follows then reads
  # the window the try-owner spilled when it made the call, which is
  # what the handler is entitled to see (notes/32).
  input :pop_abs, 1
  input :pop_to, 4

  # ---- the collector's port (notes/40)
  # An ADDRESSED read/write into any slot's any frame's any word, which
  # is what root enumeration needs and what nothing else in the machine
  # has ever wanted: `fill_*` reads at the slot's CURRENT depth, and
  # spill writes wherever the last push claimed. The walker has to reach
  # frames that nobody is standing in.
  #
  # It shares the write site with the spill, which is safe by
  # construction rather than by arbitration: the collector runs with the
  # barrel frozen (`notes/40`), and a frozen barrel has no drain in
  # flight, so `spill_valid` cannot be high while `gc_en` is.
  input :gc_en, 1
  input :gc_slot, 5
  input :gc_depth, 4
  input :gc_idx, 4
  input :gc_wr, 1
  input :gc_data, 36
  output :gc_q, 36

  # fill stream + link read (the returning owner's turns)
  input :fill_en, 1
  input :fill_idx, 4
  input :fill_slot, 5
  output :fill_data, 36

  output :ret_pc_out, 12
  output :ret_dest_out, 4

  output :overflow, 1
  output :underflow, 1
  output :depth_out, 4

  # a third, read-only view of the depth file, for the X stage. `ret`
  # from the OUTERMOST frame is not a return, it is the process ending
  # (`notes/31`), and the engine has to know that at X — before the pop
  # commits — to route the bundle to the death path instead. `depth_out`
  # cannot answer it: that port is keyed by `fill_slot`, which belongs
  # to the context streaming a fill ~18 turns later, not to the one
  # decoding. The file is a register, so a second read is a mux.
  input :q_slot, 5
  output :q_depth, 4

  memory :frames, width: 36, depth: 8192, sync_read: :clk
  # the link store: pc(9) | dest(4). Distributed (async) — 256 x 13 in
  # an EBR was the M2 waste `notes/15` flagged; this is that one-liner.
  memory :rets, width: 16, depth: 512

  # 32 x 4-bit depth counters in one shift-indexed register
  wire :depths, 128, init: 0

  # the frame the in-flight drain is filling
  wire :sp_slot, 5, init: 0
  wire :sp_depth, 4, init: 0

  wire :op_slot, 5
  wire :op_depth, 4
  wire :fill_depth, 4
  wire :push_ok, 1
  wire :pop_ok, 1
  wire :d_new, 4
  wire :ret_q, 16
  wire :gc_addr, 13
  wire :fr_ra, 13
  wire :fr_rq, 36
  wire :fr_we, 1
  wire :fr_wa, 13
  wire :fr_wd, 36

  comb do
    # push and pop are mutually exclusive (both are F-slot claims), so
    # one read port and one write site cover the whole counter file
    op_slot = push_en * push_slot + bnot(push_en) * pop_slot
    op_depth = band(depths >>> (op_slot * 4), 15)
    fill_depth = band(depths >>> (fill_slot * 4), 15)

    overflow = band(push_en, op_depth == 15)
    underflow = band(pop_en, op_depth == 0)
    push_ok = band(push_en, op_depth < 15)
    pop_ok = band(pop_en, op_depth != 0)
    d_new =
      push_ok * (op_depth + 1) + band(pop_ok, bnot(pop_abs)) * (op_depth - 1) +
        band(pop_ok, pop_abs) * pop_to

    # pop-then-read: after the pop, the caller's frame and its link sit
    # at the slot's new depth
    gc_addr = gc_slot * 256 + gc_depth * 16 + gc_idx

    # ONE read port, muxed — not two. A second read on an 8192x36 store
    # is sixteen more EBRs per engine, and the two-engine synthesis went
    # from 114 to 146 of the 85F's 208 the day this was written as a
    # separate port. It does not need to be: the collector runs with the
    # barrel frozen (`notes/41`), so the ret-fill this port normally
    # serves is idle for the whole of it. Same trick, same reason, as
    # `RegWindowCtx.rd_stg0` and `SeatUnit`'s save area.
    fr_ra =
      gc_en * gc_addr +
        band(bnot(gc_en), 1) * (fill_slot * 256 + fill_depth * 16 + fill_idx)

    fr_rq = frames[fr_ra]
    fill_data = fr_rq
    gc_q = fr_rq

    # one write site, two writers, mutually exclusive by the freeze
    fr_we = bor(spill_valid, band(gc_en, gc_wr))
    fr_wa = band(gc_en, gc_wr) * gc_addr +
              band(bnot(band(gc_en, gc_wr)), 1) * (sp_slot * 256 + sp_depth * 16 + spill_idx)
    fr_wd = band(gc_en, gc_wr) * gc_data + band(bnot(band(gc_en, gc_wr)), 1) * spill_data
    ret_q = rets[fill_slot * 16 + fill_depth]
    ret_pc_out = ret_q[15..4]
    ret_dest_out = ret_q[3..0]
    depth_out = fill_depth
    q_depth = band(depths >>> (q_slot * 4), 15)

  end

  on :clk do
    if rst == 1 do
      depths = 0
      sp_slot = 0
      sp_depth = 0
    else
      if push_ok == 1 do
        # link lands in the frame being claimed, lockstep by address
        rets[push_slot * 16 + op_depth] = push_pc * 16 + push_dest
        sp_slot = push_slot
        sp_depth = op_depth
      end

      if bor(push_ok, pop_ok) == 1 do
        depths = bor(band(depths, bnot(15 <<< (op_slot * 4))), d_new <<< (op_slot * 4))
      end

      if fr_we == 1 do
        frames[fr_wa] = fr_wd
      end
    end
  end
end
