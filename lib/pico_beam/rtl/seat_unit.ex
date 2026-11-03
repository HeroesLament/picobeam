defmodule PicoBEAM.RTL.SeatUnit do
  @moduledoc """
  M3 pass 6 — the seat file, the reduction counters, the deschedule
  rule, and the swap unit. This is where the machine finally makes a
  scheduling DECISION, and the decision is four lines long.

  ## The seat file: the only seat↔slot mapping in the engine

  `RegWindowCtx` is indexed by SEAT, `FrameRamProc` and `ProcTable` by
  proc-table SLOT. This unit holds the binding — `sslotK`/`sserK`/
  `svalidK` per seat — and publishes `slot0..3` so the engine can
  address frames for whichever seat is committing, popping or filling.
  `x_slot`/`x_serial` present the X seat's identity, which is what
  `self` reads (pass 7) and what a death frees.

  ## The deschedule rule, verbatim from the model

  Budgets (`budK`, reload `budget`) decrement once per bundle retired
  at X. At the seat's own F slot:

    * budget exhausted AND the run queue has waiters → SWAP: unseat to
      the queue tail, seat the head.
    * budget exhausted AND the queue is empty → reload, keep the seat.
      Q9's 1/T promise is to RESIDENTS; there is nobody to be fair to.
    * seat empty AND waiters → seat the head in (lazy fill at rotation,
      exactly the model's `seat_in`).
    * `yield` forces the budget to 0 at X, so the same path fires.
    * a BLOCKED resident with waiters → evict, but park it `blocked`
      rather than queueing it: only an arriving message may make a
      waiting process runnable again (M4).

  Every one of those tests happens at the owning seat's F slot, so the
  usual barrel property holds: one candidate per cycle, no arbiter.

  ## The swap, and why it needs no new window port

  Save reuses the register window's DRAIN replica with its read
  pointer muxed from `spl` to `cur` (`op_swap`) — 16 words out through
  the same `spill_*` stream a call uses, landing in this unit's save
  RAM (512 x 36 = one EBR, `{slot:5, reg:4}`). Restore streams back
  one word per owner turn through window port 0, paced exactly like
  `BarrelSeq`'s ret fill and muxed with it by phase (a seat is never
  ret-filling and swap-filling at once). Total ≈ 16 + 17 owner turns,
  which is the model's `swap_cost` of 32 made of gates.

  Save RAM zeroes at reset, so a NEVER-SWAPPED process restores a
  clean window — and that is the hook pass 7's `spawn` uses: staging a
  newborn's args means writing them into its save area, after which
  the ordinary seat-in path brings it to life. One mechanism, two
  callers.

  ## The one-turn pipeline drain before saving pc

  A seat cleared at its F slot still has bundles in D and X that will
  retire and move its pc. So the FSM clears the seat, waits for that
  seat's NEXT F slot (4 cycles — by then the pipeline is empty), and
  only then trusts `f_pc` as the resume address. Skipping this saves
  the wrong pc, which is the same species of bug as the M2 link
  capture (`notes/15`) and is worth naming twice.

  ## Death

  `died` frees the slot and invalidates the seat. The ProcTable command
  port takes one command per cycle, so a death arriving while the FSM
  is commanding latches (`dpend`) and issues as soon as the port is
  free — bounded by a few cycles, never dropped.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  # The scheduler quantum, as a PORT and not a `param`. EHDL folds
  # params at elaboration, so `seat_unit #(.BUDGET(8))` in a Verilog
  # testbench was accepted and ignored — `tb_m3_pass6` has said
  # "BUDGET = 8" in its header since M3 and has been running at 32.
  # A wire costs a mux on the reload and cannot lie (`notes/34`).
  input :budget, 6

  input :rst, 1

  # ---- BarrelSeq observation
  input :f_seat, 2
  input :f_pc, 9
  # BarrelSeq's f_en: this seat's context is RUNNING (not parked for a
  # call/ret/spawn, not mid ret-fill, not dead). Only a running context
  # may be descheduled — swapping one out mid-fill would abandon the
  # stream and wedge the shared fill unit. Integration-pass finding.
  input :f_run, 1
  # the F seat's context is blocked on a receive: unseat it for runnable
  # work, but park it BLOCKED rather than queueing it
  input :f_blocked, 1
  input :d_seat, 2
  input :x_en, 1
  input :x_seat, 2
  input :is_yield_x, 1
  input :died, 1
  input :died_seat, 2
  input :death_reason, 8

  # ---- spawn (BarrelSeq's F-slot commit; see the spawn section below)
  # ---- a spawn that arrived over the RING (`notes/47`). Same three
  # things a local spawn does — allocate a table slot, name it, queue it
  # — minus the two that need a requesting context on THIS engine: there
  # is no staging bank to drain and no `rd` to write a pid back into.
  #
  # The newborn's save area is zeroed instead of drained. A save area
  # holding a dead process's registers is a set of GC roots, and
  # `RootWalker` walks the save area of every live slot.
  input :rsp_req, 1
  input :rsp_pc, 9
  # the newborn's initial register file, one word per fill cycle: the
  # engine answers `rsp_idx` with the argument at that index, or zero
  # above the arity. A save area left holding a dead process's
  # registers is a set of GC roots that would resurrect its garbage,
  # so every one of the sixteen is written.
  output :rsp_idx, 5
  input :rsp_arg_d, 36
  output :rsp_ok, 1
  output :rsp_slot, 5
  output :rsp_serial, 22
  output :rsp_done, 1

  input :spawn_commit, 1
  input :spawn_seat, 2
  input :spawn_pc, 9
  input :spawn_rd, 4
  output :spawn_ready, 1
  output :spawn_full, 1
  output :op_spawn, 1
  output :sp_ctx, 2
  output :pid_wr, 1
  output :pid_seat, 2
  output :pid_reg, 4
  output :pid_data, 36

  # ---- BarrelSeq control
  output :seat_wr, 1
  output :seat_clr, 1
  output :seat_idx, 2
  output :seat_pc, 9

  # ---- ProcTable
  output :pt_cmd, 4
  output :pt_slot, 5
  output :pt_pc, 9
  output :pt_rd_slot, 5
  input :pt_rd_pc, 9
  input :pt_rd_serial, 22
  input :pt_alloc_slot, 5
  input :pt_alloc_serial, 22
  input :pt_occ, 6

  # ---- RunQueue
  output :rq_push, 1
  output :rq_push_data, 5
  output :rq_pop, 1
  input :rq_head, 5
  input :rq_empty, 1

  # ---- register window: swap-out claim + the spill stream it produces
  output :op_swap, 1
  output :swap_ctx, 2
  input :drain_ready, 1
  input :spill_valid, 1
  input :spill_idx, 4
  input :spill_data, 36

  # ---- swap-in stream (engine muxes onto window port 0, like ret fill)
  output :sfill_en, 1
  output :sfill_idx, 4
  output :sfill_seat, 2
  output :sfill_data, 36

  # ---- seat file readout
  # which seats actually hold a process. The root walker needs it to
  # tell a resident process (window in `RegWindowCtx`) from a swapped
  # out one (window here in `save`), and walking the wrong one of the
  # two resurrects whatever the stale copy still points at.
  output :seat_val, 4

  output :slot0, 5
  output :slot1, 5
  output :slot2, 5
  output :slot3, 5
  output :x_slot, 5
  output :x_serial, 22
  # the F seat's identity, for a remote spawn's return address: the
  # requester's PID rides the request so the reply can find its way
  # back and be incarnation-checked on arrival like any other packet.
  output :f_slot_o, 5
  output :f_serial, 22
  # the running process's own pid, ready-made for `self` — this unit
  # owns the PID layout so nothing else has to know it
  # which engine this is: the high nibble of every pid minted here
  input :eng_id, 4

  output :self_pid, 36

  # the dying process's identity, for the link fan-out. It cannot be
  # taken from the X seat: a DOOMED process dies wherever it is, and
  # `kill_seat` need not be the seat in X that cycle.
  output :died_slot, 5
  output :died_pid, 36
  output :dbg_st, 3
  output :dbg_swaps, 8

  # `notes/40` — the collector's addressed port into the save area.
  # Swapped-out windows are roots: the walker must read them and write
  # back the forwarded pointers. It costs no extra BRAM read port: the
  # barrel is frozen while the collector runs (`notes/33`'s freeze), so
  # the restore path's read is idle and its address is simply muxed.
  input :gc_en, 1
  input :gc_slot, 5
  input :gc_idx, 4
  input :gc_wr, 1
  input :gc_data, 36
  output :gc_q, 36
  # an eviction in progress: from the cycle `start_save` clears the seat
  # through the cycle the `park` goes to ProcTable, the process is
  # neither seated-and-blocked (its context is 0) nor parked (its
  # ProcTable state is still resident), so a wake for it matches
  # neither of the engine's two paths. The engine treats a wake for
  # `ev_slot` in this window as one for a parked process, and holds the
  # ProcTable wake until the park has gone out.
  output :ev_on, 1
  output :ev_slot, 5

  # the save area: one EBR, {slot:5, reg:4}
  memory :save, width: 36, depth: 512, sync_read: :clk

  # seat file
  wire :sslot0, 5, init: 0
  wire :sslot1, 5, init: 0
  wire :sslot2, 5, init: 0
  wire :sslot3, 5, init: 0
  wire :sser0, 22, init: 0
  wire :sser1, 22, init: 0
  wire :sser2, 22, init: 0
  wire :sser3, 22, init: 0
  wire :sval0, 1, init: 0
  wire :sval1, 1, init: 0
  wire :sval2, 1, init: 0
  wire :sval3, 1, init: 0

  # save-RAM shared read/write address
  wire :sv_ra, 9
  wire :sv_rq, 36
  wire :sv_gcw, 1
  wire :sv_wa, 9
  wire :sv_wd, 36
  wire :sv_wany, 1

  # reduction budgets
  wire :bud0, 6, init: 0
  wire :bud1, 6, init: 0
  wire :bud2, 6, init: 0
  wire :bud3, 6, init: 0

  # FSM: 0 idle, 1 pend (pipeline drain), 2 save, 3 restore, 4 activate,
  #      5 spawn-stage drain (the pid goes back inside this state)
  wire :st, 3, init: 0
  wire :tgt, 2, init: 0
  wire :out_slot, 5, init: 0
  wire :in_slot, 5, init: 0
  wire :swp_i, 5, init: 0
  wire :sv_cnt, 5, init: 0
  # the remote newborn's zero-fill cursor. A counter of its own rather
  # than `sv_cnt`, which state 2 already writes — one write site each.
  wire :rz_i, 5, init: 0
  wire :rsp_go, 1
  wire :sv_zw, 1
  wire :swaps, 8, init: 0

  # deferred death bookkeeping
  wire :nb_slot, 5, init: 0
  wire :nb_serial, 22, init: 0
  wire :sp_seat, 2, init: 0
  wire :sp_rd, 4, init: 0
  wire :pid_done, 1, init: 0

  wire :dpend, 1, init: 0
  wire :dslot, 5, init: 0
  wire :dreason, 8, init: 0

  # comb helpers
  wire :f_val, 1
  wire :f_bud, 6
  wire :f_slot, 5
  wire :want_swap, 1
  wire :want_evict, 1
  wire :want_unseat, 1
  wire :evicting, 1, init: 0
  wire :want_seat, 1
  wire :want_reload, 1
  wire :start_save, 1
  wire :start_seat, 1
  wire :pend_go, 1
  wire :sfill_go, 1
  wire :rest_done, 1
  wire :cmd_free, 1
  wire :sv_we, 1
  wire :sv_slot, 5

  comb do
    seat_val = sval3 * 8 + sval2 * 4 + sval1 * 2 + sval0
    slot0 = sslot0
    slot1 = sslot1
    slot2 = sslot2
    slot3 = sslot3

    x_slot = (x_seat == 0) * sslot0 + (x_seat == 1) * sslot1 + (x_seat == 2) * sslot2 +
      (x_seat == 3) * sslot3

    x_serial = (x_seat == 0) * sser0 + (x_seat == 1) * sser1 + (x_seat == 2) * sser2 +
      (x_seat == 3) * sser3

    # PID word = tag_pid(5) << 32 | engine << 28 | slot << 22 | serial,
    # matching PicoBEAM.Term.make(:pid, ...) bit for bit.
    #
    # The engine field used to be a hardcoded zero, with a comment
    # saying there was only one engine so it folded away. There is more
    # than one now, and a pid is the ROUTE (`notes/12` Bet 2): a process
    # on engine 1 minting pids that claim engine 0 sends every reply to
    # the wrong node, and the incarnation check at the far end would
    # then reject it — a message lost with no error anywhere.
    self_pid = 21_474_836_480 + eng_id * 268_435_456 + x_slot * 4_194_304 + x_serial

    f_val = (f_seat == 0) * sval0 + (f_seat == 1) * sval1 + (f_seat == 2) * sval2 +
      (f_seat == 3) * sval3

    f_bud = (f_seat == 0) * bud0 + (f_seat == 1) * bud1 + (f_seat == 2) * bud2 +
      (f_seat == 3) * bud3

    f_slot = (f_seat == 0) * sslot0 + (f_seat == 1) * sslot1 + (f_seat == 2) * sslot2 +
      (f_seat == 3) * sslot3

    f_slot_o = f_slot

    f_serial = (f_seat == 0) * sser0 + (f_seat == 1) * sser1 + (f_seat == 2) * sser2 +
      (f_seat == 3) * sser3

    # THE RULE — evaluated at the owning seat's own F slot
    # a context committing a spawn holds the drain and the command port
    # this cycle, so a deschedule of the SAME seat defers one turn
    want_swap =
      band(f_run,
        band(bnot(spawn_commit),
          band(st == 0, band(f_val, band(f_bud == 0, bnot(rq_empty))))))
    want_seat = band(bnot(spawn_commit), band(st == 0, band(bnot(f_val), bnot(rq_empty))))
    want_reload = band(st == 0, band(f_val, band(f_bud == 0, rq_empty)))

    # A blocked resident is evicted whenever anyone is waiting — the
    # model's rule, unreachable until messages existed. It resumes at
    # the SAME pc, so it re-runs its `recv_wait` and re-tests the
    # condition, which is exactly what a woken process should do.
    want_evict =
      band(bnot(spawn_commit),
        band(st == 0, band(f_val, band(f_blocked, bnot(rq_empty)))))

    want_unseat = bor(want_swap, want_evict)
    start_save = band(want_unseat, drain_ready)
    start_seat = band(want_seat, drain_ready)
    # the cleared seat's pipeline is empty by its next F slot
    pend_go = band(st == 1, f_seat == tgt)

    seat_clr = start_save
    seat_idx = tgt * bnot(start_save) + f_seat * start_save
    seat_wr = st == 4
    seat_pc = pt_rd_pc

    # swap-out claims the window drain against cur[tgt] (no rename)
    op_swap = pend_go
    swap_ctx = tgt

    # ---- spawn: the newborn is staged, queued, and named
    # `spawn_ready` is the whole precondition BarrelSeq waits on; a full
    # table answers `spawn_full` instead, which kills the SPAWNER with
    # :system_limit (notes/13). The staged args drain from stg into the
    # newborn's SAVE area, so the ordinary seat-in path is what brings it
    # to life — spawn adds no restore path of its own.
    spawn_full = pt_occ == 32
    spawn_ready = band(st == 0, band(drain_ready, bnot(spawn_full)))

    # A remote creation takes the same idle FSM a local spawn takes, and
    # loses to it: a local spawn has a context parked on the answer, and
    # the ring can wait a cycle.
    rsp_go = band(rsp_req, band(bnot(spawn_commit), band(st == 0, bnot(spawn_full))))
    rsp_ok = rsp_go
    rsp_slot = pt_alloc_slot
    rsp_serial = pt_alloc_serial
    # sixteen cycles of zeroing, and the queue push waits for them
    rsp_done = band(st == 6, rz_i == 15)
    rsp_idx = rz_i
    op_spawn = spawn_commit
    sp_ctx = spawn_seat

    # The pid is known COMBINATIONALLY at commit (ProcTable answers
    # alloc in the same cycle), so it goes back as early as the spawner's
    # very next X slot — two cycles after commit, four before the
    # spawner's next bundle can read rd. Waiting for the staging drain
    # instead would let the spawner read a stale rd, and would also skew
    # any value it stages for the NEXT spawn. Spawn therefore costs one
    # visible turn, like a call, with the drain in the background.
    pid_wr = band(st == 5, band(bnot(pid_done), x_seat == sp_seat))
    pid_seat = sp_seat
    pid_reg = sp_rd
    pid_data = 21_474_836_480 + nb_slot * 4_194_304 + nb_serial

    # restore paces one word per owner turn, D slot (write lands at X)
    sfill_go = band(st == 3, band(d_seat == tgt, swp_i < 16))
    sfill_en = sfill_go
    sfill_idx = swp_i[3..0]
    sfill_seat = tgt
    sv_ra = gc_en * (gc_slot * 16 + gc_idx) +
              band(bnot(gc_en), 1) * (in_slot * 16 + swp_i[3..0])
    sv_rq = save[sv_ra]
    sfill_data = sv_rq
    gc_q = sv_rq
    rest_done = band(st == 3, band(d_seat == tgt, swp_i == 16))

    pt_rd_slot = in_slot

    # the save RAM has ONE write site: the swap-out save and the spawn
    # arg staging are the same 16-word drain aimed at different slots
    sv_we = band(bor(st == 2, st == 5), spill_valid)
    sv_slot = (st == 2) * out_slot + (st == 5) * nb_slot
    sv_gcw = band(gc_en, gc_wr)
    # ...and a third writer, the remote newborn's zero fill. Three
    # sources, one site, and they are mutually exclusive by state.
    sv_zw = st == 6
    sv_wany = bor(sv_we, bor(sv_gcw, sv_zw))

    sv_wa =
      sv_gcw * (gc_slot * 16 + gc_idx) +
        sv_zw * (nb_slot * 16 + rz_i[3..0]) +
        band(bnot(bor(sv_gcw, sv_zw)), 1) * (sv_slot * 16 + spill_idx)

    sv_wd =
      sv_gcw * gc_data + sv_zw * rsp_arg_d +
        band(bnot(bor(sv_gcw, sv_zw)), 1) * spill_data

    # ProcTable command port: FSM first, deferred death when it is free
    cmd_free = bnot(bor(pend_go, bor(st == 4, bor(spawn_commit, rsp_go))))
    # an evicted blocked process is PARKED (7), a descheduled runnable
    # one is SAVED (3) — the two differ only in where they end up
    pt_cmd =
      band(pend_go, bnot(evicting)) * 3 + band(pend_go, evicting) * 7 +
        (st == 4) * 4 + bor(spawn_commit, rsp_go) * 1 + band(dpend, cmd_free) * 2
    died_slot =
      (died_seat == 0) * sslot0 + (died_seat == 1) * sslot1 +
        (died_seat == 2) * sslot2 + (died_seat == 3) * sslot3

    died_pid =
      21_474_836_480 + eng_id * 268_435_456 + died_slot * 4_194_304 +
        ((died_seat == 0) * sser0 + (died_seat == 1) * sser1 +
           (died_seat == 2) * sser2 + (died_seat == 3) * sser3)

    pt_slot = pend_go * out_slot + (st == 4) * in_slot + band(dpend, cmd_free) * dslot
    pt_pc =
      pend_go * f_pc + spawn_commit * spawn_pc + rsp_go * rsp_pc +
        band(dpend, cmd_free) * dreason

    # queue: pop the head we are about to seat, push the one we unseat
    rq_pop = bor(start_seat, pend_go)
    # a blocked process does NOT go to the run queue; only a message
    # can put it back there
    # ...and the remote newborn is queued only once its registers exist.
    # Queueing it at `rsp_go` would let it be seated and start executing
    # against sixteen words of whatever the last occupant left.
    rq_push = bor(band(pend_go, bnot(evicting)), bor(spawn_commit, rsp_done))
    rq_push_data =
      band(pend_go, bnot(evicting)) * out_slot + spawn_commit * pt_alloc_slot +
        rsp_done * nb_slot

    dbg_st = st
    ev_on = bor(band(st == 1, evicting), band(start_save, want_evict))
    ev_slot = start_save * f_slot + bnot(start_save) * out_slot
    dbg_swaps = swaps
  end

  on :clk do
    if rst == 1 do
      sval0 = 0
      sval1 = 0
      sval2 = 0
      sval3 = 0
      bud0 = 0
      bud1 = 0
      bud2 = 0
      bud3 = 0
      st = 0
      rz_i = 0
      swp_i = 0
      sv_cnt = 0
      swaps = 0
      evicting = 0
      dpend = 0
    else
      # ---- reduction counters: one bundle retired = one reduction
      if x_en == 1 do
        if band(x_seat == 0, bud0 != 0) == 1 do
          bud0 = bud0 - 1
        end

        if band(x_seat == 1, bud1 != 0) == 1 do
          bud1 = bud1 - 1
        end

        if band(x_seat == 2, bud2 != 0) == 1 do
          bud2 = bud2 - 1
        end

        if band(x_seat == 3, bud3 != 0) == 1 do
          bud3 = bud3 - 1
        end

        # yield = exhaust now; the F-slot rule does the rest
        if is_yield_x == 1 do
          if x_seat == 0 do
            bud0 = 0
          end

          if x_seat == 1 do
            bud1 = 0
          end

          if x_seat == 2 do
            bud2 = 0
          end

          if x_seat == 3 do
            bud3 = 0
          end
        end
      end

      # ---- keep-the-seat: exhausted with nobody waiting
      if want_reload == 1 do
        if f_seat == 0 do
          bud0 = budget
        end

        if f_seat == 1 do
          bud1 = budget
        end

        if f_seat == 2 do
          bud2 = budget
        end

        if f_seat == 3 do
          bud3 = budget
        end
      end

      # ---- death: invalidate the seat, defer the free if the port is busy
      if died == 1 do
        dpend = 1
        dreason = death_reason

        if died_seat == 0 do
          sval0 = 0
          dslot = sslot0
        end

        if died_seat == 1 do
          sval1 = 0
          dslot = sslot1
        end

        if died_seat == 2 do
          sval2 = 0
          dslot = sslot2
        end

        if died_seat == 3 do
          sval3 = 0
          dslot = sslot3
        end
      end

      if band(dpend, cmd_free) == 1 do
        dpend = 0
      end

      # ---- the FSM
      if start_save == 1 do
        tgt = f_seat
        out_slot = f_slot
        evicting = want_evict
        st = 1
      end

      if start_seat == 1 do
        tgt = f_seat
        in_slot = rq_head
        swp_i = 0
        st = 3
      end

      if pend_go == 1 do
        # f_pc is now the retired pc: saved above via pt_cmd, and the
        # window drain of cur[tgt] starts this cycle
        in_slot = rq_head
        sv_cnt = 0
        st = 2
      end

      if sv_wany == 1 do
        save[sv_wa] = sv_wd
      end

      if sv_we == 1 do
        if sv_cnt == 15 do
          swp_i = 0

          if st == 2 do
            st = 3
          else
            st = 0
          end
        else
          sv_cnt = sv_cnt + 1
        end
      end

      # A spawn that arrived over the ring: allocate and name it here,
      # then spend sixteen cycles making its save area zero rather than
      # whatever the last occupant of that slot left in it.
      #
      # The advance is written BEFORE the entry, because assignments in
      # an `on` block are blocking: entering with `st = 6` and then
      # testing `st == 6` in the same cycle reads the value just
      # written and burns the first index.
      if st == 6 do
        rz_i = rz_i + 1

        if rz_i == 15 do
          st = 0
        end
      end

      if rsp_go == 1 do
        nb_slot = pt_alloc_slot
        nb_serial = pt_alloc_serial
        rz_i = 0
        st = 6
      end

      # spawn: allocate, queue, name, and stage the newborn's args
      if spawn_commit == 1 do
        nb_slot = pt_alloc_slot
        nb_serial = pt_alloc_serial
        sp_seat = spawn_seat
        sp_rd = spawn_rd
        sv_cnt = 0
        pid_done = 0
        st = 5
      end

      if pid_wr == 1 do
        pid_done = 1
      end

      if sfill_go == 1 do
        swp_i = swp_i + 1
      end

      if rest_done == 1 do
        st = 4
      end

      if st == 4 do
        # activate: bind the seat, reload its budget, wake the context
        if tgt == 0 do
          sslot0 = in_slot
          sser0 = pt_rd_serial
          sval0 = 1
          bud0 = budget
        end

        if tgt == 1 do
          sslot1 = in_slot
          sser1 = pt_rd_serial
          sval1 = 1
          bud1 = budget
        end

        if tgt == 2 do
          sslot2 = in_slot
          sser2 = pt_rd_serial
          sval2 = 1
          bud2 = budget
        end

        if tgt == 3 do
          sslot3 = in_slot
          sser3 = pt_rd_serial
          sval3 = 1
          bud3 = budget
        end

        if swaps != 255 do
          swaps = swaps + 1
        end

        st = 0
      end
    end
  end
end
