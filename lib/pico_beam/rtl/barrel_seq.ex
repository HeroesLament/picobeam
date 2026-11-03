defmodule PicoBEAM.RTL.BarrelSeq do
  @moduledoc """
  M3 pass 3 — the barrel sequencer: M2's phase FSM redistributed across
  T = 4 rotating contexts (`notes/16`).

  ## The rotation and the pipeline

      cycle:   t      t+1    t+2    t+3    t+4
      F stage: ctx0   ctx1   ctx2   ctx3   ctx0
      D stage:  —     ctx0   ctx1   ctx2   ctx3
      X stage:  —      —     ctx0   ctx1   ctx2
      W stage:  —      —      —     ctx0   ctx1

  W writes the X decision (status, pc, target, pended wb2 op) from the X
  bundle's classification, registered at the end of X. T = 4 covers four
  stages (`notes/08` Q2): ctx0's W at t+3 lands before its F at t+4, and
  no F, D or X slot reads ctx0 at t+3. Everything else that reads the
  status in the W cycle (`dbg_st*`, which the engine's wake, timer and
  kill logic use, and the collector's resume) reads `cs_e*`, the status
  with the pending W write applied, so the per-cycle status the rest of
  the machine sees is unchanged. An event that hit the X seat in the X
  cycle (kill, arity, vacate, reseat) beat the X decision before and
  still does: `w_nocs`/`w_nopc` drop the W write it overrode.

  `seat` is a free-running 2-bit counter (Q9: fixed rotation, always;
  1/T is a promise about SLOTS, not progress). A context's bundle
  spans F..X in 3 cycles and its next F is 4 cycles after its last —
  at most ONE bundle of any context is ever in flight, so a control
  decision at X (branch, call, halt, fault) needs no flush: the next
  fetch simply uses the updated pc. No bypass, no interlock, no
  wrong-path anything, by rotation arithmetic.

  M2's FSM states survive as PER-CONTEXT status (`cstate0..3`):

      0 idle · 1 run · 2 call_park · 3 ret_park · 4 fill ·
      5 wb2 · 6 halted · 7 faulted · 9 spawn_park ·
      10 recv_park · 11 scanning · 12 blocked ·
      13 take_park · 14 rtake_long · 15 send_long · 16 sending ·
      17 gc_park · 18 sup_park · 19 peek_wb · 20 catch_wb

  The status field is FIVE bits. It was FOUR until the catch landing
  arrived as state 20 (`notes/32`) — and four had already been one bit
  short since `notes/22`, because the send park is state 16, which in
  four bits is ZERO, which is *idle*. Nothing consulted the field for a
  decision a sending context could lose, so it never bit; it was one
  read away from doing so. It was three until spawn_park arrived
  as state 9 and truncated to 1 (run): the context re-fetched its spawn
  bundle forever, having silently become runnable again. Same species as
  the M2 `pidx` collapse and the emitter width bugs in `notes/15` — a
  new encoding value outgrew its field. Check the width whenever a state
  is added.

  A context whose status is not `run` bubbles its F slot (`f_en` low);
  the rotation never skips.

  ## Claims without an arbiter

  Shared machinery (the drain unit via `drain_ready`, the fill stream
  below) is claimed by a parked context ONLY at its own F slot. One
  context owns any cycle's F slot, so at most one claimant exists per
  cycle — a fixed schedule, not an arbiter, and a park is bounded by
  T × (holder's remaining turns).

  * **call**: at X the target latches (`tgtK`) and the context parks
    (`call_park`); at its F slot with `drain_ready` it commits —
    `call_commit`/`commit_seat`/`link_pc` (call-bundle pc + 1) pulse
    for the engine (pointer rotation, link push, drain start), pc
    becomes the target, and the NEXT turn fetches the callee (the
    commit turn's fetch is skipped: one turn of latency, bounded and
    cheap). `drain_pending[k]` sets at commit and clears on
    `drain_done` — a ret cannot pop a frame whose drain is in flight.
  * **ret**: at X the context parks (`ret_park`); at its F slot with
    the fill stream free AND its own drain retired it strobes `pop_en`
    (pop-then-fill, as M2) and takes the stream.

  ## The fill stream rides the owner's own slots

  Port 0 of the register window belongs to the X-stage context every
  cycle, so a background fill (M2's 18-cycle burst) would collide with
  other contexts' write-backs. Instead the fill advances ONE WORD PER
  OWNER TURN: `fill_en`/`fill_idx` present at the owner's D slot (the
  engine's existing one-cycle write delay lands the word exactly on
  the owner's X slot — the M2 engine datapath is reused unchanged),
  indices 0..15 over 16 turns, one gap turn for the last delayed
  write, then `dest_wr` at the owner's X slot with the pc redirect to
  `ret_pc_in`. A ret therefore costs ~18 turns (~72 cycles at T = 4).
  Documented as the v1 price; the alternative (a fourth window bank —
  the LVT's 2 bits have a spare code) is the measured-later upgrade.

  ## wb2 is now just a turn

  A bundle carrying a heap op / `ldc` sets `wb2`: the next turn
  fetches nothing and its X slot strobes `wb2_en` — the engine lands
  the late result through port 0 (which this context owns that
  cycle), having captured the sync-read data into a per-context
  register at X+1 (engine-side, integration pass). The latched
  control decision (`pend_*`) dispatches at the wb2 X slot, exactly
  M2's shape: a heap op costs 2 turns, and the slot M2 wasted is
  other contexts' X time now — the promise 15 recorded, kept.

  ## Seat control

  `seat_wr`/`seat_idx`/`seat_pc` activates a context (state run) —
  driven by the testbench now, by the seat unit (pass 6) later. Death
  (halt or fault at X, or a pended halt at wb2) is an EVENT:
  `died`/`died_seat`/`died_fault` pulse once and the context goes
  terminal until re-seated; the engine turns that event into a
  ProcTable free and a seat vacate in the integration pass.

  Commit pulses stay combinational — the link-capture lesson from
  first silicon (`notes/15`) is baked in, not relearned.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # seat control (testbench now; seat unit at pass 6)
  input :seat_wr, 1
  input :seat_idx, 2
  input :seat_pc, 12
  # vacate a seat: the context goes idle and stops fetching, its
  # in-flight D/X bundles retire normally (the seat unit waits one
  # owner turn before trusting f_pc as the saved resume address)
  input :seat_clr, 1

  # X-stage classification of the in-flight bundle (engine/TB)
  input :is_jump, 1
  input :pc_target, 12
  input :is_call, 1
  input :is_cfun, 1
  input :is_ret, 1
  input :is_halt, 1
  # `try`/`catch` (notes/32). `try_begin` and `try_end` themselves are
  # ordinary one-bundle ops to the sequencer — the engine keeps the
  # catch state — but a FAULT inside a protected expression is not a
  # death: `catch_go` says a handler is waiting, `catch_deep` says the
  # fault happened below the frame the `try` was in and the frames have
  # to be unwound first, and `catch_pc` is where the context resumes.
  input :catch_go, 1
  input :catch_deep, 1
  input :catch_pc, 12
  # the VM has halted (`notes/33`). Every context stops FETCHING; none of
  # them is reset, because the population, the windows and the counters
  # are the only record of what the machine was doing when it stopped.
  input :frozen, 1
  # 1 when the fill that just finished was a catch unwind rather than a
  # ret, so the context lands on the handler instead of the link
  input :dest_mode, 1
  input :is_spawn, 1
  # M4 receive: peek parks and scans, wait blocks. The other receive
  # ops (start/hash/skip/take) are one turn and need nothing here.
  input :is_rpeek, 1
  # a `recv_wait` that must actually block (the engine has already
  # checked the mailbox for unseen messages)
  input :is_rwait_blk, 1
  input :fault_in, 1
  input :has_wb2, 1

  # shared drain unit handshake (engine's drain FSM / TB)
  input :drain_ready, 1
  input :drain_done, 1
  input :drain_done_seat, 2

  # popped link's resume address (FrameRam)
  input :ret_pc_in, 12

  # spawn handshake (SeatUnit): ready = a free slot AND the drain is
  # idle AND the seat unit's FSM is free; full = the proc table is out
  # of slots, which is :system_limit on the SPAWNER
  input :spawn_ready, 1
  input :spawn_full, 1

  # the mailbox's match unit: free to claim, and its completion pulse
  input :scan_free, 1
  input :scan_done, 1
  input :scan_done_seat, 2
  input :scan_hit, 1
  # the hit is a COMPOUND message: it parks for a rebuild instead of
  # resuming, so the clause that follows can look inside it
  input :scan_long, 1

  # a `send` whose message is a pointer: it parks while `SerUnit` walks
  # the term and streams it into the target's mailbox as flits. An
  # immediate message needs none of that and retires at X as it always
  # did, which is why this is a separate strobe and not just `is_send`.
  input :is_send_long, 1
  input :ser_free, 1
  input :ser_done, 1
  input :ser_done_seat, 2
  # A `recv_take` of a COMPOUND message has to rebuild it on the heap
  # before it has anything to write, so it parks exactly the way a peek
  # does: state 14 waits for the deserialiser, state 13 holds while it
  # runs, and the resume is unconditional — a take that got this far
  # already matched, so there is no miss arm.
  input :is_rtake_long, 1

  # a sup op (`link`/`unlink`/`monitor`/`exit2`) whose target pid is
  # on ANOTHER engine: it becomes a ring packet, and the context parks
  # (state 18) until the engine's egress latch takes it — the same
  # backpressure discipline a remote send rides (notes/53 Phase 4).
  input :is_sup_rem, 1
  # "this seat is parked on a remote sup op, right now, at its own F
  # slot" — the engine claims it there, exactly like `spawn_park`
  output :sup_park, 1
  input :sup_done, 1
  input :sup_done_seat, 2
  input :deser_free, 1
  input :deser_done, 1
  input :deser_done_seat, 2
  # a SHORT peek hit: the engine holds the seat (state 19) until the
  # peeked word's deferred writeback lands at the owner's X slot
  # (entry 38 — the compound path always had this via deser_done)
  input :pkw_done, 1
  input :pkw_done_seat, 2
  # a message arrived for a BLOCKED resident
  input :unblock_en, 1
  input :unblock_seat, 2
  # a receive TIMEOUT resumes somewhere else: `recv_waitt` names a pc
  # to land on when nothing arrived, so the unblock cannot always be
  # "one past the wait"
  input :unblock_jump, 1
  input :unblock_pc, 12
  # kill a resident from OUTSIDE the pipeline: a process whose mailbox
  # overflowed dies wherever it is, and it may be sitting on a seat
  # with no bundle in X to fault
  # `notes/40` — the collector's two signals. `gc_park` says the bundle at
  # X asked the heap for room it does not have; `gc_resume` says the
  # collection is over and every parked bundle should run again.
  input :gc_park, 1
  # `notes/46` — one bit per context, not one bit. A collection used to
  # be able to park exactly one bundle, so "resume anything in state 17"
  # named it unambiguously. A per-process collection parks a context
  # that tries to allocate before its turn has come, and more than one
  # can be waiting at once, each for a different process's collection.
  input :gc_res4, 4

  # `notes/42` — `callfun`. Its target is not in the bundle: the engine
  # reads it out of the closure and writes it into the seat's target
  # latch a cycle after X, well before the F slot that commits the call.
  # `bad_en` is the arity error that comes back with it, and it is the
  # first death in this machine raised for a seat that is NOT at X —
  # which is why it carries its own seat rather than riding `fault_in`.
  input :ftgt_en, 1
  input :ftgt_seat, 2
  input :ftgt_pc, 12
  input :bad_en, 1
  input :bad_seat, 2
  input :kill_en, 1
  input :kill_seat, 2

  # pipeline
  output :f_seat, 2
  output :f_en, 1
  output :f_pc, 12
  output :d_seat, 2
  output :d_en, 1
  output :x_seat, 2
  output :x_en, 1
  output :x_pc, 12

  # call/ret/fill strobes
  output :call_commit, 1
  output :commit_seat, 2
  output :link_pc, 12
  output :pop_en, 1
  # the shallow landing: a fault caught in the frame the `try` itself
  # was in, so there is nothing to unwind. The engine writes the
  # handler's reason register at this turn.
  output :cwb_en, 1
  output :cwb_seat, 2
  output :fill_en, 1
  output :fill_idx, 4
  output :fill_seat, 2
  output :dest_wr, 1
  output :wb2_en, 1
  output :spawn_commit, 1
  output :spawn_seat, 2
  # "this seat is parked on a spawn, right now, at its own F slot" —
  # the same cycle `spawn_commit` would fire on if the answer were
  # ready. A REMOTE spawn's answer is a ring round trip away, so the
  # engine needs the question separately from the answer (`notes/49`).
  output :spawn_park, 1
  output :peek_go, 1
  output :send_go, 1
  output :send_seat, 2
  output :peek_seat, 2
  output :take_go, 1
  output :take_seat, 2
  # a context that WANTS to rebuild, before the engine's space check
  # gates it. The engine needs the difference: `take_go` low because the
  # deserialiser is busy means wait, and low because the heap has no room
  # for the message means collect.
  output :take_want, 1
  # the F seat's context is BLOCKED on a receive — the seat unit's
  # signal to evict it in favour of runnable work
  output :f_blocked, 1
  # the parked target of whichever context owns this F slot (the
  # newborn's entry pc at spawn commit)
  output :f_tgt, 12

  # death events + per-context status
  output :died, 1
  output :died_seat, 2
  output :died_fault, 1
  output :dbg_st0, 5
  output :dbg_st1, 5
  output :dbg_st2, 5
  output :dbg_st3, 5

  # rotation + pipeline enables
  wire :seat, 2, init: 0
  wire :d_seat_r, 2, init: 0
  wire :d_en_r, 1, init: 0
  wire :x_seat_r, 2, init: 0
  wire :x_en_r, 1, init: 0

  # per-context state
  wire :cstate0, 5, init: 0
  wire :cstate1, 5, init: 0
  wire :cstate2, 5, init: 0
  wire :cstate3, 5, init: 0
  wire :pc0, 12, init: 0
  wire :pc1, 12, init: 0
  wire :pc2, 12, init: 0
  wire :pc3, 12, init: 0
  wire :tgt0, 12, init: 0
  wire :tgt1, 12, init: 0
  wire :tgt2, 12, init: 0
  wire :tgt3, 12, init: 0
  wire :pc_c0, 1, init: 0
  wire :pc_r0, 1, init: 0
  wire :pc_h0, 1, init: 0
  wire :pc_c1, 1, init: 0
  wire :pc_r1, 1, init: 0
  wire :pc_h1, 1, init: 0
  wire :pc_c2, 1, init: 0
  wire :pc_r2, 1, init: 0
  wire :pc_h2, 1, init: 0
  wire :pc_c3, 1, init: 0
  wire :pc_r3, 1, init: 0
  wire :pc_h3, 1, init: 0
  wire :dp0, 1, init: 0
  wire :dp1, 1, init: 0
  wire :dp2, 1, init: 0
  wire :dp3, 1, init: 0

  # spawn-fail death pulse (the fault resolves at an F slot, not X)
  wire :sfl, 1, init: 0
  wire :sfl_seat, 2, init: 0

  # the shared fill stream
  wire :fill_busy, 1, init: 0
  wire :fill_owner, 2, init: 0
  wire :fill_i, 5, init: 0

  # comb helpers
  wire :cur_state, 5
  wire :cur_pc, 12
  wire :cur_dp, 1
  wire :cstate_x, 5
  wire :pend_h_x, 1
  wire :commit, 1
  wire :claim_ret, 1
  wire :x_fault, 1
  wire :fill_adv, 1
  wire :spawn_go, 1
  wire :spawn_die, 1
  wire :peek_claim, 1
  wire :take_claim, 1
  wire :send_claim, 1

  # W stage: the X bundle's classification, one cycle late
  wire :w_v, 1, init: 0
  wire :w_k, 2, init: 0
  wire :w_pc, 12, init: 0
  wire :w_tgt, 12, init: 0
  wire :w_cpc, 12, init: 0
  wire :w_gc, 1, init: 0
  wire :w_flt, 1, init: 0
  wire :w_cgo, 1, init: 0
  wire :w_cdeep, 1, init: 0
  wire :w_wb2, 1, init: 0
  wire :w_call, 1, init: 0
  wire :w_cfun, 1, init: 0
  wire :w_ret, 1, init: 0
  wire :w_halt, 1, init: 0
  wire :w_jump, 1, init: 0
  wire :w_rpeek, 1, init: 0
  wire :w_rtl, 1, init: 0
  wire :w_sl, 1, init: 0
  wire :w_sup, 1, init: 0
  wire :w_rwb, 1, init: 0
  wire :w_spawn, 1, init: 0
  wire :w_nocs, 1, init: 0
  wire :w_nopc, 1, init: 0

  # the W decision (comb) and the forwarded status
  wire :wf, 1
  wire :wfc, 1
  wire :wfn, 1
  wire :wn, 1
  wire :ww, 1
  wire :wo, 1
  wire :o_halt, 1
  wire :r1, 1
  wire :o_ret, 1
  wire :r2, 1
  wire :o_rpeek, 1
  wire :r3, 1
  wire :w_long, 1
  wire :o_long, 1
  wire :r4, 1
  wire :o_rwait, 1
  wire :r5, 1
  wire :o_spawn, 1
  wire :r6, 1
  wire :o_cfun, 1
  wire :r7, 1
  wire :o_call, 1
  wire :o_step, 1
  wire :ww_step, 1
  wire :w_cs, 5
  wire :w_cs_wr, 1
  wire :w_pc_wr, 1
  wire :w_pc_val, 12
  wire :w_tgt_wr, 1
  wire :w_pend_wr, 1
  wire :w_cs_hit, 1
  wire :cs_e0, 5
  wire :cs_e1, 5
  wire :cs_e2, 5
  wire :cs_e3, 5

  comb do
    f_seat = seat
    d_seat = d_seat_r
    d_en = d_en_r
    x_seat = x_seat_r
    x_en = x_en_r

    cur_state =
      (seat == 0) * cstate0 + (seat == 1) * cstate1 + (seat == 2) * cstate2 +
        (seat == 3) * cstate3

    cur_pc = (seat == 0) * pc0 + (seat == 1) * pc1 + (seat == 2) * pc2 + (seat == 3) * pc3
    cur_dp = (seat == 0) * dp0 + (seat == 1) * dp1 + (seat == 2) * dp2 + (seat == 3) * dp3

    cstate_x =
      (x_seat_r == 0) * cstate0 + (x_seat_r == 1) * cstate1 + (x_seat_r == 2) * cstate2 +
        (x_seat_r == 3) * cstate3

    pend_h_x =
      (x_seat_r == 0) * pc_h0 + (x_seat_r == 1) * pc_h1 + (x_seat_r == 2) * pc_h2 +
        (x_seat_r == 3) * pc_h3

    x_pc =
      (x_seat_r == 0) * pc0 + (x_seat_r == 1) * pc1 + (x_seat_r == 2) * pc2 +
        (x_seat_r == 3) * pc3

    f_en = band(cur_state == 1, bnot(frozen))
    f_pc = cur_pc
    f_tgt = (seat == 0) * tgt0 + (seat == 1) * tgt1 + (seat == 2) * tgt2 + (seat == 3) * tgt3

    # F-slot claims: at most one claimant per cycle by rotation
    commit = band(cur_state == 2, drain_ready)
    claim_ret = band(cur_state == 3, band(bnot(fill_busy), bnot(cur_dp)))

    call_commit = commit
    commit_seat = seat
    link_pc = cur_pc + 1
    pop_en = claim_ret

    # state 20 is a context that has caught a fault in its own frame:
    # no frames to unwind, one register still to write. It takes its own
    # X turn, which is free because no bundle is in flight for it.
    cwb_en = band(cstate_x == 20, bnot(x_en_r))
    cwb_seat = x_seat_r

    # spawn parks like a call and commits at its own F slot; a full
    # proc table kills the spawner instead (notes/13's :system_limit)
    spawn_go = band(cur_state == 9, spawn_ready)
    spawn_die = band(cur_state == 9, spawn_full)
    spawn_commit = spawn_go
    spawn_seat = seat
    spawn_park = cur_state == 9
    sup_park = cur_state == 18

    # the scan is claimed at the scanning context's own F slot, like
    # every other shared unit in this machine
    peek_claim = band(cur_state == 10, scan_free)
    peek_go = peek_claim
    peek_seat = seat

    take_claim = band(cur_state == 14, deser_free)
    take_go = take_claim
    take_seat = seat
    take_want = cur_state == 14

    # the serialiser is claimed at the sending context's own F slot, the
    # way every shared unit in this machine is
    # ---- the W decision, made once for the context in W ----
    # Same priority as the per-seat tree it replaces: gc park, then a
    # fault (caught or not), then a wb2 bundle, then the bundle's own op
    # in the order halt, ret, rpeek, long park, rwait, spawn, cfun, call,
    # and otherwise a step (jump or pc + 1). Each selector is that
    # priority made explicit, so at most one is high and the ORs are
    # muxes. A compound take, a compound send and a remote sup op park in
    # different states; rule 3 says a bundle holds at most one system op,
    # so `w_long` is a one-hot mux, not a priority.
    wf = band(bnot(w_gc), w_flt)
    wfc = band(wf, w_cgo)
    wfn = band(wf, bnot(w_cgo))
    wn = band(bnot(w_gc), bnot(w_flt))
    ww = band(wn, w_wb2)
    wo = band(wn, bnot(w_wb2))
    o_halt = band(wo, w_halt)
    r1 = band(wo, bnot(w_halt))
    o_ret = band(r1, w_ret)
    r2 = band(r1, bnot(w_ret))
    o_rpeek = band(r2, w_rpeek)
    r3 = band(r2, bnot(w_rpeek))
    w_long = bor(w_rtl, bor(w_sl, w_sup))
    o_long = band(r3, w_long)
    r4 = band(r3, bnot(w_long))
    o_rwait = band(r4, w_rwb)
    r5 = band(r4, bnot(w_rwb))
    o_spawn = band(r5, w_spawn)
    r6 = band(r5, bnot(w_spawn))
    o_cfun = band(r6, w_cfun)
    r7 = band(r6, bnot(w_cfun))
    o_call = band(r7, w_call)
    o_step = band(r7, bnot(w_call))
    ww_step = band(ww, band(bnot(w_call), band(bnot(w_ret), bnot(w_halt))))

    w_cs_wr = bnot(o_step)

    w_cs =
      bor(bor(bor(w_gc * 17, wfc * bor(w_cdeep * 3, bnot(w_cdeep) * 20)), bor(wfn * 7, ww * 5)),
        bor(bor(bor(o_halt * 6, o_ret * 3), bor(o_rpeek * 10, o_long * bor(w_rtl * 14, bor(w_sl * 15, w_sup * 18)))),
          bor(bor(o_rwait * 12, o_spawn * 9), bor(o_cfun * 2, o_call * 2))))

    w_pc_wr = bor(wfc, bor(ww_step, o_step))
    w_pc_val = bor(wfc * w_cpc, bnot(wfc) * bor(w_jump * w_tgt, bnot(w_jump) * (w_pc + 1)))
    w_tgt_wr = bor(band(ww, w_call), bor(o_rpeek, bor(o_spawn, o_call)))
    w_pend_wr = ww

    # the status as the rest of the machine sees it this cycle
    w_cs_hit = band(w_v, band(w_cs_wr, bnot(w_nocs)))
    cs_e0 = band(w_cs_hit, w_k == 0) * w_cs + bnot(band(w_cs_hit, w_k == 0)) * cstate0
    cs_e1 = band(w_cs_hit, w_k == 1) * w_cs + bnot(band(w_cs_hit, w_k == 1)) * cstate1
    cs_e2 = band(w_cs_hit, w_k == 2) * w_cs + bnot(band(w_cs_hit, w_k == 2)) * cstate2
    cs_e3 = band(w_cs_hit, w_k == 3) * w_cs + bnot(band(w_cs_hit, w_k == 3)) * cstate3

    send_claim = band(cur_state == 15, ser_free)
    send_go = send_claim
    send_seat = seat
    # a seat being woken this cycle is not blocked: the wake channel is a
    # cycle behind the delivery, and an eviction started in that cycle
    # would park a process whose message has already landed
    f_blocked = band(cur_state == 12, bnot(band(unblock_en, unblock_seat == seat)))

    # fill stream pacing: advance at the owner's D slot, present 0..15,
    # one gap index (16) for the last delayed write, dest at 17
    fill_adv = band(fill_busy, band(d_seat_r == fill_owner, fill_i < 17))
    fill_en = band(fill_adv, fill_i < 16)
    fill_idx = fill_i[3..0]
    fill_seat = fill_owner
    dest_wr = band(fill_busy, band(x_seat_r == fill_owner, fill_i == 17))

    # the wb2 turn's X slot (no bundle in flight: x_en is low there)
    wb2_en = band(cstate_x == 5, bnot(x_en_r))

    # death events resolve at X: a live bundle halting/faulting, or a
    # pended halt dispatching at the wb2 turn
    # a fault that a `try` will catch is not a death: the context goes
    # to the unwind instead, and nothing downstream should hear about it
    x_fault = band(fault_in, bnot(catch_go))

    died =
      bor(sfl,
        bor(band(x_en_r, bor(x_fault, is_halt)),
          band(band(cstate_x == 5, bnot(x_en_r)), pend_h_x)))

    died_seat = sfl * sfl_seat + bnot(sfl) * x_seat_r
    died_fault = bor(sfl, band(x_en_r, x_fault))

    dbg_st0 = cs_e0
    dbg_st1 = cs_e1
    dbg_st2 = cs_e2
    dbg_st3 = cs_e3
  end

  on :clk do
    if rst == 1 do
      seat = 0
      d_seat_r = 0
      d_en_r = 0
      x_seat_r = 0
      x_en_r = 0
      cstate0 = 0
      cstate1 = 0
      cstate2 = 0
      cstate3 = 0
      pc0 = 0
      pc1 = 0
      pc2 = 0
      pc3 = 0
      dp0 = 0
      dp1 = 0
      dp2 = 0
      dp3 = 0
      fill_busy = 0
      fill_owner = 0
      fill_i = 0
      sfl = 0
      w_v = 0
    else
      sfl = 0

      # rotation + pipeline registers
      seat = seat + 1
      d_seat_r = seat
      d_en_r = f_en
      x_seat_r = d_seat_r
      x_en_r = d_en_r

      # X -> W: the classification, and whether an event that wins over
      # the X decision hit this seat in the X cycle
      w_v = x_en_r
      w_k = x_seat_r
      w_pc = x_pc
      w_tgt = pc_target
      w_cpc = catch_pc
      w_gc = gc_park
      w_flt = fault_in
      w_cgo = catch_go
      w_cdeep = catch_deep
      w_wb2 = has_wb2
      w_call = is_call
      w_cfun = is_cfun
      w_ret = is_ret
      w_halt = is_halt
      w_jump = is_jump
      w_rpeek = is_rpeek
      w_rtl = is_rtake_long
      w_sl = is_send_long
      w_sup = is_sup_rem
      w_rwb = is_rwait_blk
      w_spawn = is_spawn

      w_nocs =
        bor(bor(band(kill_en, kill_seat == x_seat_r), band(bad_en, bad_seat == x_seat_r)),
          bor(band(seat_clr, seat_idx == x_seat_r), band(seat_wr, seat_idx == x_seat_r)))

      w_nopc = band(seat_wr, seat_idx == x_seat_r)

      # shared fill stream (single write site; claim wins over advance)
      if claim_ret == 1 do
        fill_busy = 1
        fill_owner = seat
        fill_i = 0
      else
        if fill_adv == 1 do
          fill_i = fill_i + 1
        end

        if dest_wr == 1 do
          fill_busy = 0
        end
      end

      # ---- per-context blocks: one copy per seat (`generate`) ----
      generate k <- 0..3 do
        # ---- ctx k ----
        # the W stage lands ctx k's X decision (one cycle after X; `notes/40`
        # gc park leaves the pc untouched, a caught fault lands on the
        # handler, a wb2 bundle pends its control op for the wb2 turn)
        if band(w_v, w_k == k) == 1 do
          if band(w_cs_wr, bnot(w_nocs)) == 1 do
            cstate[[k]] = w_cs
          end

          if band(w_pc_wr, bnot(w_nopc)) == 1 do
            pc[[k]] = w_pc_val
          end

          if w_tgt_wr == 1 do
            tgt[[k]] = w_tgt
          end

          if w_pend_wr == 1 do
            pc_c[[k]] = w_call
            pc_r[[k]] = w_ret
            pc_h[[k]] = w_halt
          end
        end

        # wb2 dispatch at ctx k's X slot (reads see pre-edge pend values)
        if band(cstate[[k]] == 5, band(x_seat_r == k, bnot(x_en_r))) == 1 do
          pc_c[[k]] = 0
          pc_r[[k]] = 0
          pc_h[[k]] = 0

          if pc_h[[k]] == 1 do
            cstate[[k]] = 6
          else
            if pc_r[[k]] == 1 do
              cstate[[k]] = 3
            else
              if pc_c[[k]] == 1 do
                cstate[[k]] = 2
              else
                cstate[[k]] = 1
              end
            end
          end
        end

        # drain retire BEFORE commit: a same-cycle new commit must win dp[[k]]
        if band(drain_done, drain_done_seat == k) == 1 do
          dp[[k]] = 0
        end

        # F-slot claims for ctx k
        if band(commit, seat == k) == 1 do
          pc[[k]] = tgt[[k]]
          cstate[[k]] = 1
          dp[[k]] = 1
        end

        if band(claim_ret, seat == k) == 1 do
          cstate[[k]] = 4
        end

        if band(cwb_en, cwb_seat == k) == 1 do
          cstate[[k]] = 1
        end

        if band(peek_claim, seat == k) == 1 do
          cstate[[k]] = 11
        end

        if band(take_claim, seat == k) == 1 do
          cstate[[k]] = 13
        end

        if band(send_claim, seat == k) == 1 do
          cstate[[k]] = 16
        end

        # the flit stream retired: the sender resumes at the next bundle
        if band(ser_done, ser_done_seat == k) == 1 do
          pc[[k]] = pc[[k]] + 1
          cstate[[k]] = 1
        end

        # the remote sup packet was accepted: the op is fire-and-forget
        # (the model's `wire/4` returns immediately), so the context
        # resumes at the next bundle
        if band(sup_done, sup_done_seat == k) == 1 do
          pc[[k]] = pc[[k]] + 1
          cstate[[k]] = 1
        end

        # the rebuild retires: the take always resumes at the next bundle
        if band(deser_done, deser_done_seat == k) == 1 do
          pc[[k]] = pc[[k]] + 1
          cstate[[k]] = 1
        end

        # the scan retires: hit resumes at the next bundle, miss takes the
        # none-label the peek latched
        if band(scan_done, scan_done_seat == k) == 1 do
          if scan_hit == 1 do
            if scan_long == 1 do
              # park for the rebuild; `deser_done` is what advances the pc
              cstate[[k]] = 14
            else
              # hold for the peeked word's writeback (entry 38)
              cstate[[k]] = 19
            end
          else
            pc[[k]] = tgt[[k]]
            cstate[[k]] = 1
          end
        end

        if band(pkw_done, pkw_done_seat == k) == 1 do
          pc[[k]] = pc[[k]] + 1
          cstate[[k]] = 1
        end

        # a message arrived: the blocked context resumes past its wait
        if band(unblock_en, unblock_seat == k) == 1 do
          pc[[k]] = unblock_jump * unblock_pc + bnot(unblock_jump) * (pc[[k]] + 1)
          cstate[[k]] = 1
        end

        # the collection retired: the parked bundle runs AGAIN. The pc
        # was never advanced, so this is a resume that repeats rather
        # than one that continues — the only park in the machine that
        # does.
        if band(band(gc_res4 >>> k, 1), cs_e[[k]] == 17) == 1 do
          cstate[[k]] = 1
        end

        if band(ftgt_en, ftgt_seat == k) == 1 do
          tgt[[k]] = ftgt_pc
        end

        if band(bad_en, bad_seat == k) == 1 do
          cstate[[k]] = 7
          sfl = 1
          sfl_seat = k
        end

        if band(kill_en, kill_seat == k) == 1 do
          cstate[[k]] = 7
          sfl = 1
          sfl_seat = k
        end

        if band(spawn_go, seat == k) == 1 do
          pc[[k]] = pc[[k]] + 1
          cstate[[k]] = 1
        end

        if band(spawn_die, seat == k) == 1 do
          cstate[[k]] = 7
          sfl = 1
          sfl_seat = k
        end

        # fill completion: dest turn redirects to the popped link
        if band(dest_wr, fill_owner == k) == 1 do
          if dest_mode == 1 do
            cstate[[k]] = 1
          else
            pc[[k]] = ret_pc_in
            cstate[[k]] = 1
          end
        end

        if band(seat_clr, seat_idx == k) == 1 do
          cstate[[k]] = 0
        end

        if band(seat_wr, seat_idx == k) == 1 do
          cstate[[k]] = 1
          pc[[k]] = seat_pc
          dp[[k]] = 0
        end
      end
    end
  end
end
