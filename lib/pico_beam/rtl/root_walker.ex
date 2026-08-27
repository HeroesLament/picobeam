defmodule PicoBEAM.RTL.RootWalker do
  @moduledoc """
  M5 — root enumeration for the collector (`notes/40`).

  `Collector` deliberately does not know where roots live. This unit is
  the other half of that decision: it knows, and it knows nothing about
  Cheney. It walks the machine's live state, hands every POINTER to the
  collector one at a time, and writes the answer back where it came
  from.

  ## The root set, and the one the model has that this one does not

  `Machine.collect/2` is the definition:

      p.windows head   current register window
      p.windows tail   spilled frames
      p.out_args       the staging bank
      p.mailbox        message words

  Three of those four are here. The fourth is not, and the reason is a
  real difference between the model and the machine rather than an
  omission.

  **The model copies a message on DELIVERY**; `deliver_to/3` calls
  `import_term`, which allocates on the receiver's heap, so a queued
  message is a heap pointer sitting in the mailbox and therefore a root.
  **This machine copies on RECEIVE.** `SerUnit` turns the sender's term
  into a flit stream, the mailbox stores the flits, and `DeserUnit`
  rebuilds the term on the receiver's heap when `recv` takes it. Flits
  are immediates and structural markers — `WCONS`, `HDR|n` — and the
  exit/DOWN signal emitter says so out loud: *"flits, every one an
  immediate. notes/13's allocation-free rule made physical."*

  So a mailbox in this machine holds no heap pointer, and a walk over it
  would present zero roots. The port to do it was built before this was
  noticed and then removed, because a root walk over something with no
  roots in it is exactly the sort of correct-looking dead code that
  `notes/40` was written about.

  It follows that model and machine hold DIFFERENT amounts of heap for
  the same program — the model charges a queued message, this does not —
  so the two can reach `heap_full` on different allocations. That is a
  divergence in when memory runs out, not in what a program computes,
  and it is recorded on the scoreboard rather than hidden here.

  The day a flit can carry a heap address — a refc binary shipped by
  reference is the obvious one — the mailbox becomes a root and this
  moduledoc is the thing that has to change first.

  ## Resident or swapped out, never both

  A process's CURRENT window is in one of two places. If it holds a
  seat, it is a bank of `RegWindowCtx`. If it has been swapped out, it
  is sixteen words of `SeatUnit`'s save area. The other copy is STALE.

  Walking both would be worse than wasteful: a stale save area still
  points at whatever the process was holding when it was evicted, and
  evacuating those pointers resurrects objects that are dead. So the
  walk asks `seat_val` and the four seat slots which of the two a slot
  is in, and walks exactly one.

  The staging bank is only walked for RESIDENT seats, and for the same
  reason: eviction drains `cur`, not `stg`, so a swapped-out process has
  no live staging anywhere to walk.

  ## Why it is affordable

  The worst case is 32 slots x 15 frames x 16 words. The real case is
  not, because of two rules this unit exists to apply:

  1. **Walk what is live.** Occupied seats, live slots, frames
     `0..depth-1`. A two-process program three frames deep is about a
     hundred words rather than eight thousand.
  2. **Filter immediates here.** A word that is not `cons` or `tuple`
     cannot move, so it never crosses to the collector and never costs
     a round trip. Integers, atoms, pids and return addresses — most of
     every window — cost two cycles each and stop.

  ## Timing

  Every source is a sync-read memory, so an address presented in one
  cycle answers in the next. A non-pointer therefore costs two cycles
  (`ADDR`, `DATA`); a pointer costs those plus the collector's round
  trip and one write-back cycle. Skipping a dead seat or slot costs one
  cycle in `SEEK`.

  The barrel is frozen throughout (`notes/33`'s freeze, driven by the
  engine), which is what makes all of this safe: read port 0 of the
  register file, the save area's restore port and the frame store's
  spill port are all idle, so this unit borrows them through a mux
  rather than replicating twenty-one memories.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # the engine says the pipeline has drained and the world is stopped
  input :start, 1
  output :busy, 1
  # one pulse when the last root has been presented
  output :done, 1

  # ---- the collector's root stream
  output :root_en, 1
  output :root_word, 36
  input :root_ack, 1
  input :root_new, 36
  output :roots_done, 1

  # ---- who is alive: one bit per process slot, from `ProcTable`
  input :live_vec, 32

  # `notes/46` — ONE process, not all of them. A collection is now a
  # sequence of per-process collections, and this walk is one of them:
  # `one_slot`'s registers, its save area if it is swapped out, and its
  # frames. Nothing else is touched and nothing else is stopped.
  #
  # The full sweep is still here, and `one_en` low still means it. It is
  # what `tb_rootwalk` exercises, and it is the shape the answer has to
  # keep agreeing with.
  input :one_en, 1
  input :one_slot, 5

  # ---- who is resident: `SeatUnit`'s seat file
  input :seat_val, 4
  input :seat_slot0, 5
  input :seat_slot1, 5
  input :seat_slot2, 5
  input :seat_slot3, 5

  # ---- register windows, through read/write port 0
  output :rw_ctx, 2
  output :rw_stg, 1
  output :rw_addr, 4
  input :rw_q, 36
  output :rw_we, 1
  output :rw_data, 36

  # ---- the save area, through `SeatUnit`'s GC port
  output :sv_en, 1
  output :sv_slot, 5
  output :sv_idx, 4
  output :sv_wr, 1
  output :sv_data, 36
  input :sv_q, 36

  # ---- spilled frames, through `FrameRamProc`'s GC port
  output :frm_en, 1
  output :frm_slot, 5
  output :frm_depth, 4
  output :frm_idx, 4
  output :frm_wr, 1
  output :frm_data, 36
  input :frm_q, 36
  # how many frames that slot actually has — async, so it is valid in
  # the same cycle as the cursor that asks
  output :frm_qslot, 5
  input :frm_qdepth, 4

  # Tags from `PicoBEAM.Term`. Same reasoning as `Collector`: a tag
  # number written here by hand is a copy that drifts (`notes/40`).
  param :T_CONS, default: PicoBEAM.Term.tag_value(:cons)
  param :T_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)
  param :T_FUN, default: PicoBEAM.Term.tag_value(:fun)
  param :T_MAP, default: PicoBEAM.Term.tag_value(:map)
  param :T_BIN, default: PicoBEAM.Term.tag_value(:bin)

  # 0 idle, 1 addr, 2 data, 3 present, 4 wait, 5 write-back,
  # 6 seek (position the cursor), 7 finish
  wire :st, 3, init: 0
  # 0 register windows (cur then stg), 1 save area, 2 frames
  wire :ph, 2, init: 0
  wire :seat, 3, init: 0
  wire :stg, 1, init: 0
  wire :rgi, 5, init: 0
  wire :slot, 6, init: 0
  wire :dep, 5, init: 0
  wire :idx, 5, init: 0
  # advance before the next validity test — set by whatever consumed a
  # word, so the cursor cascade is written once instead of twice
  wire :adv, 1, init: 0

  wire :held, 36, init: 0
  wire :neww, 36, init: 0
  wire :r_en, 1, init: 0
  wire :r_done, 1, init: 0
  wire :w_pulse, 1, init: 0

  wire :src_word, 36
  wire :w_tag, 4
  wire :is_ptr, 1
  wire :live_now, 1
  wire :resident, 1
  wire :seat_ok, 1
  wire :ph1_ok, 1
  wire :ph2_ok, 1
  wire :one_res, 1
  wire :one_seat, 3

  comb do
    busy = st != 0
    done = r_done
    roots_done = r_done
    root_en = r_en
    root_word = held

    # addresses come straight off the cursor: `SEEK` leaves it valid and
    # `ADDR` is the settle cycle the sync reads need
    rw_ctx = seat[1..0]
    rw_stg = stg
    rw_addr = rgi[3..0]

    sv_en = busy
    sv_slot = slot[4..0]
    sv_idx = idx[3..0]

    frm_en = busy
    frm_slot = slot[4..0]
    frm_depth = dep[3..0]
    frm_idx = idx[3..0]
    frm_qslot = slot[4..0]

    src_word = (ph == 0) * rw_q + (ph == 1) * sv_q + (ph == 2) * frm_q

    w_tag = held[35..32]
    is_ptr =
      bor(w_tag == T_CONS,
        bor(w_tag == T_TUPLE, bor(w_tag == T_FUN, bor(w_tag == T_MAP, w_tag == T_BIN))))

    # the write-back goes back exactly where the word came from
    rw_we = band(w_pulse, ph == 0)
    sv_wr = band(w_pulse, ph == 1)
    frm_wr = band(w_pulse, ph == 2)
    rw_data = neww
    sv_data = neww
    frm_data = neww

    live_now = band(live_vec >>> slot, 1)

    resident =
      bor(band(band(seat_val, 1), seat_slot0 == slot),
        bor(band(band(seat_val >>> 1, 1), seat_slot1 == slot),
          bor(band(band(seat_val >>> 2, 1), seat_slot2 == slot),
            band(band(seat_val >>> 3, 1), seat_slot3 == slot))))

    seat_ok = band(seat_val >>> seat, 1)

    # the seat `one_slot` is sitting in, if it is sitting in one. Four
    # comparisons and a priority encode: a slot is in at most one seat,
    # so the priority never arbitrates anything.
    one_res =
      bor(band(band(seat_val, 1), seat_slot0 == one_slot),
        bor(band(band(seat_val >>> 1, 1), seat_slot1 == one_slot),
          bor(band(band(seat_val >>> 2, 1), seat_slot2 == one_slot),
            band(band(seat_val >>> 3, 1), seat_slot3 == one_slot))))

    one_seat =
      band(band(seat_val >>> 1, 1), seat_slot1 == one_slot) * 1 +
        band(band(seat_val >>> 2, 1), seat_slot2 == one_slot) * 2 +
        band(band(seat_val >>> 3, 1), seat_slot3 == one_slot) * 3
    # a swapped-out live process: its current window is in the save area
    ph1_ok = band(live_now, bnot(resident))
    # a live process with at least this many frames
    ph2_ok = band(live_now, dep < frm_qdepth)
  end

  on :clk do
    r_en = 0
    r_done = 0
    w_pulse = 0

    if rst == 1 do
      st = 0
      ph = 0
      seat = 0
      stg = 0
      rgi = 0
      slot = 0
      dep = 0
      idx = 0
      adv = 0
    else
      hdl_case <<st::3>> do
        # ---- 0: idle
        <<0::3>> ->
          if start == 1 do
            stg = 0
            rgi = 0
            dep = 0
            idx = 0
            adv = 0
            st = 6

            if one_en == 1 do
              # straight to the target: no stepping through thirty-one
              # slots that are not it, which is where the 490 cycles
              # `notes/41` measured actually went.
              slot = one_slot
              seat = one_seat
              ph = bnot(one_res) * 1
            else
              ph = 0
              seat = 0
              slot = 0
            end
          end

        # ---- 6: position the cursor.
        #
        # One cycle per step, and a step is either "consume the advance
        # somebody else asked for" or "this position is dead, skip it".
        # Skipping is structural: a dead seat skips a seat, a dead slot
        # skips a slot, and a slot that has run out of frames skips a
        # slot rather than counting to fifteen through frames that do
        # not exist.
        <<6::3>> ->
          if adv == 1 do
            adv = 0

            if ph == 0 do
              if rgi == 15 do
                rgi = 0

                if stg == 0 do
                  stg = 1
                else
                  stg = 0

                  if one_en == 1 do
                    # a resident process's current window IS its
                    # registers; its save area is stale by definition,
                    # so phase 1 has nothing for it
                    ph = 2
                    dep = 0
                    idx = 0
                  else
                    if seat == 3 do
                      ph = 1
                      slot = 0
                      idx = 0
                    else
                      seat = seat + 1
                    end
                  end
                end
              else
                rgi = rgi + 1
              end
            else
              if ph == 1 do
                if idx == 15 do
                  idx = 0

                  if one_en == 1 do
                    ph = 2
                    dep = 0
                  else
                    if slot == 31 do
                      ph = 2
                      slot = 0
                      dep = 0
                    else
                      slot = slot + 1
                    end
                  end
                else
                  idx = idx + 1
                end
              else
                if idx == 15 do
                  idx = 0
                  dep = dep + 1
                else
                  idx = idx + 1
                end
              end
            end
          else
            if ph == 0 do
              if seat_ok == 1 do
                st = 1
              else
                stg = 0
                rgi = 0

                if one_en == 1 do
                  ph = 2
                  dep = 0
                  idx = 0
                else
                  if seat == 3 do
                    ph = 1
                    slot = 0
                    idx = 0
                  else
                    seat = seat + 1
                  end
                end
              end
            else
              if ph == 1 do
                if ph1_ok == 1 do
                  st = 1
                else
                  idx = 0

                  if one_en == 1 do
                    ph = 2
                    dep = 0
                  else
                    if slot == 31 do
                      ph = 2
                      slot = 0
                      dep = 0
                    else
                      slot = slot + 1
                    end
                  end
                end
              else
                if ph2_ok == 1 do
                  st = 1
                else
                  idx = 0
                  dep = 0

                  if one_en == 1 do
                    st = 7
                  else
                    if slot == 31 do
                      st = 7
                    else
                      slot = slot + 1
                    end
                  end
                end
              end
            end
          end

        # ---- 1: the address is on the memory; the data lands next
        <<1::3>> ->
          st = 2

        # ---- 2: the word is in hand. Immediates stop here — that is
        # the filter the whole walk is affordable because of.
        <<2::3>> ->
          held = src_word
          st = 3

        # ---- 3: present it, or skip it. `is_ptr` reads `held`, which
        # only became valid at the end of state 2, so the decision is
        # taken here rather than there.
        <<3::3>> ->
          if is_ptr == 1 do
            r_en = 1
            st = 4
          else
            adv = 1
            st = 6
          end

        # ---- 4: the collector has it. `root_en` was a single cycle, so
        # it cannot be re-consumed while the evacuation runs.
        <<4::3>> ->
          if root_ack == 1 do
            neww = root_new
            st = 5
          end

        # ---- 5: put the answer back where the word came from
        <<5::3>> ->
          w_pulse = 1
          adv = 1
          st = 6

        # ---- 7: every root has been presented
        <<7::3>> ->
          r_done = 1
          st = 0
      end
    end
  end
end
