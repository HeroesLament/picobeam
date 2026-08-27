defmodule PicoBEAM.RTL.BarrelEngine do
  @moduledoc """
  M3 pass 8 — the engine, integrated. Everything the pass-3..7
  testbenches stood in for is now real RTL:

      F   f_pc → CodeMem (sync read)
      D   Decode + Classify → window read addresses (sync read)
      X   Decode + Classify again → ALU, write-back, control

  ## Why the decoders appear twice

  A bundle is decoded at D to form the window's READ addresses, and
  again at X to drive the ALU, the write ports and the control path.
  The alternative — carrying ~150 bits of decoded fields across the
  D→X boundary — costs more flops than re-decoding costs LUTs, because
  `Decode` is pure bit-slicing (free) and `Classify` is a handful of
  byte compares. So the bundle itself (72 bits) is the pipeline
  register and the decode is duplicated on purpose.

  ## Port 0 of the register window, and why it still needs no arbiter

  Seven sources land on write port 0, in strict phase order:

      ret-fill · swap-in fill · spawn's pid · ret dest · ALU result ·
      arg staging · self

  The first four belong to PARKED contexts — a context that is
  ret-filling, being swapped, or waiting on a spawn has no bundle in X,
  so its X slot is free precisely when those writes want it. The last
  three belong to the running context's own X slot. One context owns
  any given X cycle, so the mux is a priority, not an arbiter: the
  fifth time the barrel's one-owner-per-cycle rule has deleted
  arbitration.

  ## Per-seat latches the barrel needs and M2 did not

  M2 committed a call in the same neighbourhood of cycles that decoded
  it, so the dest register and the return value could ride combinational
  wires. Here a call/spawn commits at a LATER F slot, so the engine
  keeps per-seat latches — call dest, spawn rd, and the ret value —
  written at X and read at the owning seat's commit. Same reason
  `BarrelSeq` latches the target: in a barrel, "later" means "another
  context has been through in between".

  ## M4: messages

  `send` is one turn — decode the pid, check the incarnation serial,
  enqueue — and the mailbox's command port takes it in preference to
  anything the receive side wants, because a scan that misses a
  message arriving mid-scan finds it on the next round anyway.

  The receive family splits by cost. `recv_start`, `recv_hash`,
  `recv_skip` and `recv_take` are one turn each and ride the X stage.
  `recv_peek` PARKS its context and claims the mailbox's match unit at
  its own F slot; the scan then runs while the other three seats keep
  executing, which is what makes `notes/05`'s "the scan costs the
  mutator nothing" structural here rather than aspirational.
  `recv_wait` blocks only if the mailbox says nothing is unseen, and a
  delivery to a blocked resident unblocks it — the first scheduling
  event in this machine that the rotation did not generate.

  `recv_take` writes rd from the per-seat LATCHED peek word rather than
  re-reading the mailbox: by the protocol a take always follows a
  successful peek on the same cursor, so the word is already in hand
  and the take costs one turn instead of another sync read.

  ## The heap and the wb2 turn

  A bundle carrying a heap op sets `has_wb2`: the context's NEXT turn
  fetches nothing, and its X slot strobes `wb2_en` so the late result
  lands through port 0, which that context owns on that cycle by the
  rotation. The cost is one extra turn, and the slot M2 wasted is other
  contexts' X time now.

  The result cannot simply be read at the wb2 turn — the heap's sync
  reads have moved on by then, four cycles later. So `rd_late` is
  captured the cycle AFTER the command into a per-seat latch (`hl*`),
  alongside the destination register (`hd*`), and the wb2 turn only
  moves what is already in hand. This is the same shape as the ret
  value, the spawn pid and the peek word — the fourth time this
  machine's answer to "later" has been a per-seat latch, and the fourth
  bug it would otherwise have been.

  `tset` is the exception that has to be named: it writes the heap and
  produces nothing, and its `rd` field is zero, so granting it a wb2
  turn would write a stale word into r0. It gets no wb2 turn at all —
  `hp_writes` excludes it — which is also correct on cost, since a tset
  is a single-cycle write.

  ## Deliberately not here yet

  `ldc` and the literal pool. `LitPool` is not instantiated and
  `is_ldc` is unconnected; `has_wb2` already exists for it to use.
  
  ## try / catch (notes/32)

  Per process, four deep, in `ctch` ({depth:4, pc:9, rd:4} at
  {slot:5, idx:2}) with the nesting counts in one shift-indexed
  register. `try_begin` records the frame depth it stands at, its
  handler label and its `rd`, and pre-loads `rd` with the class atom
  `error` — the only class this machine can raise. `try_end`
  decrements. Neither touches a frame, a window, or the sequencer.

  A fault asks `cc_n != 0`. No, and the process dies on exactly the
  path it always took; yes, and it lands. Deep landings (the fault is
  below the try's frame — the shape `erlc` emits) take the ret path
  with an absolute pop and write the reason on the fill's own dest
  turn. Shallow landings take a parked context's free X turn.

"""

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # image loader side-door (SdBoot / a ROM streamer)
  input :ld_code_en, 1
  input :ld_code_addr, 9
  input :ld_code_data, 72

  # the literal pool's loader side-door, alongside the code store's
  input :ld_pool_en, 1
  input :ld_pool_addr, 8
  input :ld_pool_data, 36

  # create the first process: allocate at boot_pc and enqueue it
  input :boot_en, 1
  input :boot_pc, 9

  # the observability port
  output :out_valid, 1
  output :out_data, 36

  # which engine this is. A PID's engine field is compared against it to
  # decide local delivery from a ring packet, and it is the high nibble
  # of every PID this engine mints.
  input :eng_id, 4
  # the VM-wide halt sideband (`notes/33`). `erlang:halt/0` stops the
  # RUNTIME, not one process, and with two engines that means both of
  # them. A sideband and not a ring packet: a packet queues behind a
  # full FIFO, and the one thing halt must not do is wait.
  input :halt_in, 1

  # ---- the ring: the only thing between engines (notes/12)
  output :ring_w_en, 1
  output :ring_w_head, 1
  output :ring_w_kind, 4
  output :ring_w_deng, 4
  output :ring_w_word, 36
  output :ring_w_len, 7
  input :ring_w_ready, 1

  input :ring_r_valid, 1
  input :ring_r_head, 1
  input :ring_r_kind, 4
  input :ring_r_deng, 4
  input :ring_r_word, 36
  input :ring_r_len, 7
  output :ring_r_pop, 1

  # the machine is done when no process remains
  output :idle, 1

  # The LAST ABNORMAL DEATH, and what of. Not a health flag: in a
  # language whose supervision model is built on children dying, a
  # process exiting with a non-`normal` reason is routine, and a single
  # sticky bit that goes high on the first one and never comes down
  # cannot tell a working supervisor from a crash loop. `fault_count`
  # is what distinguishes them, and `fault_slot` says who it was.
  #
  # `fault_reason` reports the reason the process ACTUALLY died of.
  # That is not always the X-stage fault reason: a process killed by a
  # signal never faulted at X, and until this was fixed such a death
  # reported `normal`, which is a contradiction the port had no right
  # to state. A doomed slot's reason comes from its table entry.
  output :faulted, 1
  output :fault_reason, 8
  output :fault_slot, 5
  output :fault_count, 8
  output :halt_req, 1

  # debug taps
  output :dbg_occ, 6
  output :dbg_qcount, 6
  output :dbg_swaps, 8
  output :dbg_spawns, 12
  output :dbg_deaths, 12
  output :dbg_sends, 12
  output :dbg_recvs, 12
  output :dbg_scan, 6
  output :dbg_evicts, 8
  output :dbg_x_seat, 2
  output :dbg_x_en, 1
  output :dbg_pc, 9
  output :dbg_st0, 5
  output :dbg_st1, 5
  output :dbg_st2, 5
  output :dbg_st3, 5

  # ---- pipeline / sequencer
  wire :f_seat, 2
  wire :f_en, 1
  wire :f_pc, 9
  wire :f_tgt, 9
  wire :d_seat, 2
  wire :d_en, 1
  wire :x_seat, 2
  wire :x_en, 1
  wire :x_pc, 9
  wire :cm_bundle, 72
  wire :xb, 72, init: 0

  wire :call_commit, 1
  wire :commit_seat, 2
  wire :link_pc, 9
  wire :pop_en, 1
  wire :fill_en, 1
  wire :fill_idx, 4
  wire :fill_seat, 2
  wire :dest_wr, 1
  wire :spawn_commit, 1
  wire :spawn_seat, 2
  wire :peek_go, 1
  wire :peek_seat, 2
  wire :f_blocked, 1
  wire :died, 1
  wire :died_seat, 2
  wire :died_fault, 1

  # ---- D-stage decode (read addressing only)
  wire :d_op0, 8
  wire :d_rd0, 4
  wire :d_ra0, 4
  wire :d_rb0, 4
  wire :d_imm0, 12
  wire :d_i80, 8
  wire :d_op1, 8
  wire :d_rd1, 4
  wire :d_ra1, 4
  wire :d_rb1, 4
  wire :d_imm1, 12
  wire :d_i81, 8
  wire :d_op2, 8
  wire :d_rd2, 4
  wire :d_ra2, 4
  wire :d_rb2, 4
  wire :d_imm2, 12
  wire :d_i82, 8
  wire :dr0_rsf1, 1
  wire :dr1_rsf1, 1
  wire :dr2_rsf1, 1
  wire :ra_a0, 4
  wire :ra_a2, 4
  wire :ra_a4, 4

  # ---- X-stage decode
  wire :op0, 8
  wire :rd0, 4
  wire :ra0, 4
  wire :rb0, 4
  wire :imm0, 12
  wire :i80, 8
  wire :op1, 8
  wire :rd1, 4
  wire :ra1, 4
  wire :rb1, 4
  wire :imm1, 12
  wire :i81, 8
  wire :op2, 8
  wire :rd2, 4
  wire :ra2, 4
  wire :rb2, 4
  wire :imm2, 12
  wire :i82, 8

  wire :c0_sel, 5
  wire :c0_wr, 1
  wire :c0_jmp, 1
  wire :c0_bift, 1
  wire :c0_biff, 1
  wire :c0_call, 1
  wire :c0_cfun, 1
  wire :c0_mseti, 1
  wire :c0_tail, 1
  wire :c0_ret, 1
  wire :c0_arg, 1
  wire :c0_halt, 1
  wire :c0_try, 1
  wire :c0_tend, 1
  wire :c0_out, 1
  wire :c0_spawn, 1
  wire :c0_yield, 1
  wire :c0_self, 1
  wire :c0_send, 1
  wire :c0_rstart, 1
  wire :c0_rhash, 1
  wire :c0_rpeek, 1
  wire :c0_rskip, 1
  wire :c0_rtake, 1
  wire :c0_rwait, 1
  wire :c1_sel, 5
  wire :c1_wr, 1
  wire :c1_jmp, 1
  wire :c1_bift, 1
  wire :c1_biff, 1
  wire :c1_call, 1
  wire :c1_cfun, 1
  wire :c1_mseti, 1
  wire :c1_tail, 1
  wire :c1_ret, 1
  wire :c1_arg, 1
  wire :c1_halt, 1
  wire :c1_try, 1
  wire :c1_tend, 1
  wire :c1_out, 1
  wire :c1_spawn, 1
  wire :c1_yield, 1
  wire :c1_self, 1
  wire :c1_send, 1
  wire :c1_rstart, 1
  wire :c1_rhash, 1
  wire :c1_rpeek, 1
  wire :c1_rskip, 1
  wire :c1_rtake, 1
  wire :c1_rwait, 1
  wire :c2_sel, 5
  wire :c2_wr, 1
  wire :c2_jmp, 1
  wire :c2_bift, 1
  wire :c2_biff, 1
  wire :c2_call, 1
  wire :c2_cfun, 1
  wire :c2_mseti, 1
  wire :c2_tail, 1
  wire :c2_ret, 1
  wire :c2_arg, 1
  wire :c2_halt, 1
  wire :c2_try, 1
  wire :c2_tend, 1
  wire :c2_out, 1
  wire :c2_spawn, 1
  wire :c2_yield, 1
  wire :c2_self, 1
  wire :c2_send, 1
  wire :c2_rstart, 1
  wire :c2_rhash, 1
  wire :c2_rpeek, 1
  wire :c2_rskip, 1
  wire :c2_rtake, 1
  wire :c2_rwait, 1

  # ---- window
  wire :rw_rd0, 36
  wire :rw_rd1, 36
  wire :rw_rd2, 36
  wire :rw_rd3, 36
  wire :rw_rd4, 36
  wire :rw_rd5, 36
  wire :w_ctx, 2
  wire :w0_en, 1
  wire :w0_stg, 1
  wire :w0_addr, 4
  wire :w0_data, 36
  wire :w1_en, 1
  wire :w2_en, 1
  wire :w1_data, 36
  wire :w2_data, 36
  wire :drain_ready, 1
  wire :drain_done, 1
  wire :drain_done_seat, 2
  wire :spill_valid, 1
  wire :spill_idx, 4
  wire :spill_data, 36
  wire :spill_seat, 2

  # ---- ALU
  wire :alu0_y, 36
  wire :alu0_f, 1
  wire :alu0_fr, 8
  wire :alu1_y, 36
  wire :alu1_f, 1
  wire :alu1_fr, 8
  wire :alu2_y, 36
  wire :alu2_f, 1
  wire :alu2_fr, 8

  # ---- frames
  wire :fr_fill_d, 36
  wire :fr_ret_pc, 9
  wire :fr_ret_dest, 4
  wire :fr_gc_q, 36

  # ---- `notes/40`: the collector, wired in
  #
  # `notes/46` — a collection is a SEQUENCE of per-process collections
  # sharing one to-space, and the engine runs between them.
  #
  #   0 idle
  #   1 begin   quiet the background workers, then move the allocation
  #             base to to-space and mark every live process pending
  #   2 gap     RUN. The engine is not frozen here; this is the whole
  #             point. It leaves when somebody is waiting or the gap
  #             timer expires
  #   3 settle  frozen, waiting for quiet again
  #   4 walk    one process's roots
  #   5 scan    Cheney, to completion, before it resumes
  #   6 adopt   take the collector's bump pointer back, clear the bit
  #
  # The pause is states 3..6 and it is ONE process's roots and live set.
  # States 0 and 2 are not pauses at all.
  wire :gc_st, 3, init: 0
  wire :gc_wait, 6, init: 0
  wire :gc_want, 1, init: 0
  # which semispace is being evacuated, and who has not been done yet
  wire :gc_from, 1, init: 0
  wire :gc_pend, 32, init: 0
  wire :gc_slot, 5, init: 0
  # contexts parked waiting for their own collection, one bit each
  wire :gc_pk, 4, init: 0
  wire :gc_start, 1, init: 0
  wire :gc_res4, 4
  wire :gc_active, 1
  wire :gc_busy, 1
  wire :gc_park, 1
  wire :gc_hf_x, 1
  wire :gc_alloc_x, 1
  wire :gc_pend_x, 1
  wire :gc_gate_x, 1
  wire :gc_quiet, 1
  wire :gc_req_dz, 1
  wire :gc_pick, 5
  wire :gc_any, 1
  wire :gc_urg, 1
  wire :gc_p0, 1
  wire :gc_p1, 1
  wire :gc_p2, 1
  wire :gc_p3, 1
  wire :gc_ok4, 4
  wire :gc_fin1, 1
  wire :gc_hold, 1
  param :GC_GAP, default: 32
  wire :dz_fits, 1
  wire :dz_lim, 9
  wire :take_want, 1
  wire :hp_f_e, 1
  wire :engine_frozen, 1
  wire :sv_gc_q, 36
  wire :live_vec, 32
  wire :seat_val, 4

  wire :cx_busy, 1
  wire :cx_done, 1
  wire :cx_to_hp, 9
  wire :gc_to_base, 9
  wire :cx_ovf, 1
  wire :cx_ack, 1
  wire :cx_new, 36
  wire :cx_haddr, 8
  wire :cx_wr0, 1
  wire :cx_wr1, 1
  wire :cx_d0, 36
  wire :cx_d1, 36

  wire :rk_busy, 1
  wire :rk_done, 1
  wire :rk_root_en, 1
  wire :rk_root_word, 36
  wire :rk_roots_done, 1
  wire :rk_ctx, 2
  wire :rk_stg, 1
  wire :rk_addr, 4
  wire :rk_we, 1
  wire :rk_data, 36
  wire :rk_sv_en, 1
  wire :rk_sv_slot, 5
  wire :rk_sv_idx, 4
  wire :rk_sv_wr, 1
  wire :rk_sv_data, 36
  wire :rk_fr_en, 1
  wire :rk_fr_slot, 5
  wire :rk_fr_depth, 4
  wire :rk_fr_idx, 4
  wire :rk_fr_wr, 1
  wire :rk_fr_data, 36
  wire :rk_fr_qslot, 5

  # register-file port 0, muxed between the machine and the walker
  wire :gw_rd_ctx, 2
  wire :gw_rd_a0, 4
  wire :gw_stg0, 1
  wire :gw_w_ctx, 2
  wire :gw_w_en0, 1
  wire :gw_w_stg0, 1
  wire :gw_w_a0, 4
  wire :gw_w_d0, 36
  wire :gw_q_slot, 5
  wire :fr_ovf, 1
  wire :fr_unf, 1
  wire :x_depth, 4
  wire :raw_ret, 1
  wire :ret_top, 1
  # the scheduler quantum: bundles a process retires before it is asked
  # to give up its seat. 24 since M3 pass 6.
  wire :sched_budget, 6
  wire :stk_ovf, 1
  # sticky, cleared by `boot_en` so a halted machine can be re-booted
  # with a new image rather than needing the board reset
  wire :vm_halt, 1, init: 0
  wire :real_halt, 1
  # ---- try/catch (notes/32)
  # Per-slot catch state, four deep. A `try` does NOT claim a frame: the
  # model's handler lands in the try-owner's window AS IT STANDS, not in
  # a snapshot, so there is nothing to save at `try_begin` and nothing
  # to restore — only a depth to unwind to, a handler to land on, and
  # the register pair to fill in.
  #
  #   {depth:4, pc:9, rd:4}   at {slot:5, idx:2}
  memory :ctch, width: 17, depth: 128
  # 32 x 3-bit nesting counters in one shift-indexed register, the same
  # idiom the frame store's depths use
  wire :ccnt, 96, init: 0
  wire :cc_n, 3
  wire :cc_top, 17
  wire :cc_inc, 1
  wire :cc_dec, 1
  wire :cc_we, 1
  wire :cc_val, 3
  wire :cc_clr, 96
  wire :cc_mask, 96
  wire :c_depth, 4
  wire :c_pc, 9
  wire :c_rd, 4
  wire :has_catch, 1
  wire :catch_go, 1
  wire :catch_deep, 1
  wire :catch_pc, 9
  wire :try_ovf, 1
  wire :any_try, 1
  wire :any_tend, 1
  wire :try_dest_x, 4
  wire :sys_try, 1
  wire :dest_mode, 1
  wire :uw_rd, 4
  wire :uw_rsn, 8
  wire :cwb_en, 1
  wire :cwb_seat, 2
  wire :cwb_rd, 4
  wire :cwb_rsn, 8
  wire :fault_r0, 8
  wire :fill_rv_e, 36
  wire :w_ctx_b, 2
  wire :w0_addr_b, 4
  wire :w0_data_b, 36
  # per-seat: the landing's register and reason, and "this seat's ret
  # claim is really a catch unwind"
  wire :cr0, 4, init: 0
  wire :cr1, 4, init: 0
  wire :cr2, 4, init: 0
  wire :cr3, 4, init: 0
  wire :cn0, 8, init: 0
  wire :cn1, 8, init: 0
  wire :cn2, 8, init: 0
  wire :cn3, 8, init: 0
  wire :cd_0, 4, init: 0
  wire :cd_1, 4, init: 0
  wire :cd_2, 4, init: 0
  wire :cd_3, 4, init: 0
  wire :uwd0, 1, init: 0
  wire :uwd1, 1, init: 0
  wire :uwd2, 1, init: 0
  wire :uwd3, 1, init: 0
  wire :pop_abs, 1
  wire :pop_to, 4

  # ---- seat unit / tables
  wire :su_cmd, 4
  wire :su_slot, 5
  wire :su_pc, 9
  wire :su_rq_push, 1
  wire :su_rq_data, 5
  wire :su_rq_pop, 1
  wire :pt_cmd, 4
  wire :pt_slot, 5
  wire :pt_pc, 9
  wire :pt_rd_slot, 5
  wire :pt_rd_pc, 9
  wire :pt_rd_serial, 22
  wire :pt_rd_state, 2
  wire :alloc_ok, 1
  wire :alloc_slot, 5
  wire :alloc_serial, 22
  wire :occ, 6
  wire :rq_push, 1
  wire :rq_data, 5
  wire :rq_pop, 1
  wire :rq_head, 5
  wire :rq_empty, 1
  wire :rq_full, 1
  wire :rq_count, 6
  wire :seat_wr, 1
  wire :seat_clr, 1
  wire :seat_idx, 2
  wire :seat_pc, 9
  wire :spawn_ready, 1
  wire :spawn_full, 1
  wire :op_swap, 1
  wire :swap_ctx, 2
  wire :op_spawn, 1
  wire :sp_ctx, 2
  wire :sfill_en, 1
  wire :sfill_idx, 4
  wire :sfill_seat, 2
  wire :sfill_data, 36
  wire :pid_wr, 1
  wire :pid_seat, 2
  wire :pid_reg, 4
  wire :pid_data, 36
  wire :slot0, 5
  wire :slot1, 5
  wire :slot2, 5
  wire :slot3, 5
  wire :x_slot, 5
  wire :x_serial, 22
  wire :self_pid, 36

  # ---- aggregation / control
  wire :any_jump, 1
  wire :any_call, 1
  wire :any_ret, 1
  wire :any_halt, 1
  wire :any_spawn, 1
  wire :any_yield, 1
  wire :any_out, 1
  wire :any_tail, 1
  wire :any_self, 1
  wire :br0, 1
  wire :br1, 1
  wire :br2, 1
  wire :ctl0, 1
  wire :ctl1, 1
  wire :ctl2, 1
  wire :pc_target, 9
  wire :any_fault, 1
  wire :any_fault_r, 8
  wire :wb0, 1
  wire :wb1, 1
  wire :wb2w, 1
  wire :ag0, 1
  wire :ag1, 1
  wire :ag2, 1
  wire :self0, 1
  # The rd-writing system ops — `self`, `recv_take`, `monitor` — all
  # land through port 0, which the bundle's single system op owns. They
  # used to be keyed on the SLOT-0 strobe, so the same op sitting in
  # slot 1 or 2 computed its value and wrote nowhere. The contract puts
  # a system op last, not first, and "last occupied slot" is slot 1 in
  # any two-op bundle — so this was a real hole that only stayed shut
  # because the front end emits one op per bundle.
  wire :sys_self, 1
  wire :sys_rtk, 1
  wire :sys_mon, 1
  wire :sys_any, 1
  wire :sys_rd, 4
  wire :rtk0, 1
  wire :rpk0, 1
  wire :ret_word, 36
  wire :call_dest_x, 4
  wire :spawn_rd_x, 4

  # ---- heap
  wire :c0_heap, 1
  wire :c1_heap, 1
  wire :c2_heap, 1
  wire :any_heap, 1
  wire :hp_writes, 1
  wire :hp_cmd, 4
  wire :hp_pa, 36
  wire :hp_pb, 36
  wire :hp_i8_raw, 8
  wire :hp_i8, 8
  wire :hp_rd, 4
  wire :hp_en, 1
  wire :hp_rd_late, 36
  wire :hp_f, 1
  wire :hp_fr, 8
  wire :hp_hp, 9
  wire :hp_full, 1
  wire :hp_bq0, 36
  wire :hp_bq1, 36
  wire :c0_ldc, 1
  wire :c1_ldc, 1
  wire :c2_ldc, 1
  wire :any_ldc, 1
  wire :c0_fail, 1
  wire :c1_fail, 1
  wire :c2_fail, 1
  wire :any_fail, 1
  wire :fail_reason, 8
  wire :lp_addr, 8
  wire :lp_q, 36
  # `notes/42` — the closure literal, addressed a stage early
  wire :lp2_addr, 8
  wire :lp2_q, 36
  # `notes/42` — `callfun`: the funinfo read at X, the target latched at
  # X+1, and the arity check that happens a stage after the seat has
  # moved on and therefore needs a death of its own.
  wire :any_cfun, 1
  wire :cfun_raw, 1
  wire :cf_pa, 36
  wire :cf_ar, 4
  wire :cf_d, 1, init: 0
  wire :cf_seat_d, 2, init: 0
  wire :cf_ar_d, 4, init: 0
  wire :ftgt_en, 1
  wire :ftgt_seat, 2
  wire :ftgt_pc, 9
  wire :ba_bad, 1
  wire :ba_go, 1
  wire :ba_pend, 1, init: 0
  wire :ba_seat, 2, init: 0
  # the reason has to be alive when the DEATH is, not when the error
  # is noticed: `sfl` is a register, so `died` fires the cycle after
  # `bad_en` and reads `any_fault_r` then (`notes/26`'s failure class
  # two, met again).
  wire :ba_rsn, 1, init: 0
  wire :mk_x, 1
  wire :mk_op, 8
  wire :mk_nfree, 4
  wire :mat_x, 1
  wire :mat_i, 36
  # the per-PROCESS map index `mseti` latches — 32 slots of 8 bits, the
  # same wide-wire idiom the catch counters use. Per process and not per
  # seat, because a process can be swapped out between the `mseti` and
  # the `mset` and come back on a different seat.
  wire :midx, 256, init: 0
  wire :mi_n, 8
  wire :mi_set, 1
  wire :mi_val, 8
  wire :mset_x, 1
  wire :mkm_x, 1
  wire :mkm_i, 36

  # `badarity` as a reserved index, read out of `Term` rather than
  # written here as a number
  param :A_BADARITY,
    default: Enum.find_index(PicoBEAM.Term.reserved_atoms(), &(&1 == :badarity))
  # ---- supervision (notes/13)
  wire :c0_link, 1
  wire :c1_link, 1
  wire :c2_link, 1
  wire :c0_unlink, 1
  wire :c1_unlink, 1
  wire :c2_unlink, 1
  wire :c0_exit2, 1
  wire :c1_exit2, 1
  wire :c2_exit2, 1
  wire :c0_trap, 1
  wire :c1_trap, 1
  wire :c2_trap, 1
  wire :any_link, 1
  wire :any_unlink, 1
  wire :any_exit2, 1
  wire :any_trap, 1
  wire :any_sup, 1
  wire :sup_pid, 36
  wire :sup_slot, 5
  wire :sup_serial, 22
  wire :sup_alive, 1
  wire :sup_bad, 1

  # ---- registered names (`notes/50`)
  wire :c0_regn, 1
  wire :c1_regn, 1
  wire :c2_regn, 1
  wire :c0_wher, 1
  wire :c1_wher, 1
  wire :c2_wher, 1
  wire :c0_unreg, 1
  wire :c1_unreg, 1
  wire :c2_unreg, 1
  wire :any_regn, 1
  wire :any_wher, 1
  wire :any_unreg, 1
  wire :nm_name_w, 36
  wire :nm_pid_w, 36
  wire :nm_alive, 1
  wire :regn_ok, 1
  wire :nm_bad, 1
  wire :nm_lim, 1
  # ---- the node registry interface (`notes/53`): the CAM lives at the
  # NODE — an engine is a scheduler, and register/whereis are node ops.
  # One full interface per engine; the CAM is dual-ported so nothing
  # here ever waits.
  output :nm_q_name, 16
  input :nm_q_hit, 1
  input :nm_q_eng, 4
  input :nm_q_slot, 5
  input :nm_q_serial, 22
  input :nm_name_taken, 1
  input :nm_pid_taken, 1
  input :nm_full, 1
  output :nm_w_en, 1
  output :nm_w_eng, 4
  output :nm_w_slot, 5
  output :nm_w_serial, 22
  output :nm_clr_en, 1

  # the auto-unregister feed: this engine's deaths, for the node CAM
  output :nm_die, 1
  output :nm_die_pid, 36

  # a pid being REGISTERED may live on the peer: the node routes this
  # probe to the pid's home table; the serial compare stays here
  output :nm_probe_slot, 5
  input :nm_probe_state, 2
  input :nm_probe_serial, 22

  # ...and this engine answers the PEER's probes from its own table
  input :peer_probe_slot, 5
  output :peer_probe_state, 2
  output :peer_probe_serial, 22

  wire :nm_loc, 1
  wire :nm_alive_rem, 1
  wire :whe_word, 36
  wire :sys_whe, 1
  wire :snd_atom, 1
  wire :snd_pid_res, 36
  wire :ser_wake, 1
  wire :pt_rd6_state, 2
  wire :pt_rd7_state, 2
  wire :pt_rd7_serial, 22
  param :A_UNDEF,
    default: Enum.find_index(PicoBEAM.Term.reserved_atoms(), &(&1 == :undefined))
  wire :ex_reason, 8

  wire :lt_cmd, 3
  wire :lt_cmd_pid, 36
  wire :lt_a, 5
  wire :lt_b, 5
  wire :lt_die, 1
  wire :lt_die_slot, 5
  wire :lt_die_reason, 8
  wire :lt_doomed, 1
  wire :pt_rd4_reason, 8
  wire :lt_die_pid, 36
  wire :lt_ready, 1
  wire :lt_busy, 1
  wire :lt_sig, 1
  wire :lt_sig_slot, 5
  wire :lt_sig_from, 36
  wire :lt_sig_reason, 8
  wire :lt_done, 1
  wire :c0_mon, 1
  wire :c1_mon, 1
  wire :c2_mon, 1
  wire :any_mon, 1
  wire :mon_rd, 4
  wire :lt_ref, 22
  wire :lt_sig_kind, 1
  wire :lt_sig_ref, 22
  wire :lt_mon_full, 1
  wire :lt_rem_full, 1
  wire :lt_sig_remote, 1
  wire :lt_sig_peer, 36
  wire :next_ref, 22, init: 1
  wire :ref_word, 36
  wire :ref_wr, 1
  wire :sd_kind, 1, init: 0
  wire :sd_ref, 22, init: 0
  wire :down_hash, 8
  # 4 flits for an EXIT, 5 for a DOWN — a wire rather than an inline
  # expression, so its width is stated once and cannot be inferred
  # from whatever it happens to be multiplied by
  wire :sd_len, 6

  # ---- the deserialiser: a compound `recv_take` rebuilds on the heap
  wire :ri0, 6, init: 0
  wire :ri1, 6, init: 0
  wire :ri2, 6, init: 0
  wire :ri3, 6, init: 0
  wire :x_ridx, 6
  wire :is_rtake_long, 1
  # the peek's destination register, latched per seat: the rebuild it
  # kicks finishes many cycles later, by which time the rotation has
  # moved on. Sixth instance of the produced-here/consumed-there latch.
  wire :pk0, 4, init: 0
  wire :pk1, 4, init: 0
  wire :pk2, 4, init: 0
  wire :pk3, 4, init: 0
  wire :scan_long, 1

  # ---- the transmit half: `send` of a compound term
  #
  # An immediate message is its own flit and retires at X exactly as it
  # always has — that is what keeps ping-pong at its measured cost. A
  # POINTER cannot be enqueued as a word: doing so shipped the sender's
  # heap address into the receiver's mailbox, which worked only because
  # one heap is shared and became memory corruption the moment there
  # were two engines (`notes/26` bug 1). So a compound send parks, and
  # `SerUnit` walks the term and streams it in as flits.
  wire :snd_ptr, 1
  wire :is_send_long, 1
  wire :deliver_now, 1
  # per-seat latches: `send_go` lands at the sender's F slot, cycles
  # after the X where the message word and the routed slot were valid
  wire :sg_msg0, 36, init: 0
  wire :sg_msg1, 36, init: 0
  wire :sg_msg2, 36, init: 0
  wire :sg_msg3, 36, init: 0
  wire :sg_slot0, 5, init: 0
  wire :sg_slot1, 5, init: 0
  wire :sg_slot2, 5, init: 0
  wire :sg_slot3, 5, init: 0

  wire :send_go, 1
  wire :send_seat, 2
  wire :ser_free, 1
  wire :ser_start, 1
  wire :ser_term, 36
  wire :ser_busy, 1
  wire :ser_done, 1
  wire :ser_fault, 1
  wire :ser_freason, 8
  wire :ser_count, 7
  wire :ser_counted, 1
  wire :ser_go_emit, 1
  wire :ser_abort, 1
  wire :ser_stall, 1
  wire :ser_haddr, 8
  wire :ser_emit, 1
  wire :ser_word, 36
  wire :ser_arity, 8
  wire :ser_first, 36
  # who is streaming, and to which slot
  wire :sr_seat, 2, init: 0
  wire :sr_slot, 5, init: 0
  wire :sr_len, 7, init: 0
  wire :sr_head, 1, init: 0
  wire :sr_fits, 1
  wire :sr_stream, 1
  wire :mb_ser, 1
  wire :ser_ret, 1, init: 0
  wire :mb_hi, 1
  # egress: a remote send's packet
  wire :snd_remote, 1
  wire :snd_rslot, 6
  wire :sg_pid0, 36, init: 0
  wire :sg_pid1, 36, init: 0
  wire :sg_pid2, 36, init: 0
  wire :sg_pid3, 36, init: 0
  wire :sg_rem0, 1, init: 0
  wire :sg_rem1, 1, init: 0
  wire :sg_rem2, 1, init: 0
  wire :sg_rem3, 1, init: 0
  wire :sr_rem, 1, init: 0
  wire :sr_pid, 36, init: 0
  wire :sr_hdr, 1, init: 0
  wire :ring_push, 1
  # ingress: a packet arriving from the ring
  wire :rg_st, 2, init: 0
  wire :rg_pid, 36, init: 0
  wire :rg_len, 7, init: 0
  wire :rg_left, 7, init: 0
  wire :rg_head, 1, init: 0
  wire :rg_ok, 1, init: 0
  wire :rg_slot, 5
  wire :rg_ser, 22
  wire :rg_kind, 4, init: 0
  wire :rg_live, 1
  wire :mb_rg, 1
  wire :pt_rd5_serial, 22
  wire :pt_rd5_state, 2
  wire :sh_word, 36
  # heap port B, shared. `SerUnit` owns it today; the collector will
  # take it during a collection, and the two are never live together
  # because a collection stops the world.
  wire :hpb_addr, 8
  wire :hpb_wr0, 1
  wire :hpb_wr1, 1
  wire :hpb_d0, 36
  wire :hpb_d1, 36
  wire :hpb_space, 1
  wire :hp_flip, 1
  wire :hp_flip_ap, 9
  wire :hp_flip_sp, 1
  wire :rk_one_en, 1
  wire :rk_one_slot, 5
  wire :sh_arity, 8
  wire :sh_first, 36
  wire :take_go, 1
  wire :take_seat, 2
  wire :dz_start, 1
  wire :dz_busy, 1
  wire :dz_done, 1
  # The deserialiser's completion, DEFERRED to its owner's X slot
  # (`notes/52`). `dz_done` is a free-running pulse: it can land on any
  # seat's X cycle, and the w0 priority chain let it beat `wb0` — the
  # RUNNING context's ALU writeback — which was then silently dropped.
  # Every other late writer on that port paces itself to the parked
  # owner's turn, whose X slot is empty by construction; this makes the
  # deserialiser do the same. The owner is parked on the rebuild, so
  # its slot comes within one rotation.
  wire :dzw_pend, 1, init: 0
  wire :dzw_seat, 2, init: 0
  wire :dzw_rd, 4, init: 0
  wire :dzw_result, 36, init: 0
  wire :dzw_wb, 1
  wire :dz_result, 36
  wire :dz_slot, 5
  wire :dz_idx, 6
  wire :dz_len, 6
  wire :dz_h_req, 1
  wire :dz_h_cmd, 3
  wire :dz_h_pa, 36
  wire :dz_h_pb, 36
  wire :dz_h_i8, 8
  wire :dz_grant, 1
  wire :deser_free, 1
  wire :mb_rf_slot, 5
  wire :mb_rf_idx, 6
  # the parked take's identity, for the write-back when the rebuild ends
  wire :dz_seat, 2, init: 0
  wire :dz_rd, 4, init: 0
  wire :dz_pslot, 5, init: 0
  wire :dz_plen, 6, init: 0
  wire :dz_take, 1, init: 0

  # ---- receive timeouts
  wire :c0_rwaitt, 1
  wire :c1_rwaitt, 1
  wire :c2_rwaitt, 1
  wire :any_rwaitt, 1
  wire :tm_arm, 1
  wire :tm_delay, 32
  wire :tm_pc, 9
  wire :tm_cancel, 1
  wire :tm_cancel_slot, 5
  wire :tm_fire, 1
  wire :tm_fire_slot, 5
  wire :tm_fire_pc, 9
  wire :tm_ready, 1
  wire :tm_now, 32
  wire :tm_armed, 32
  wire :rwaitt_blk, 1
  wire :tf0, 1
  wire :tf1, 1
  wire :tf2, 1
  wire :tf3, 1
  wire :tm_resident, 1
  wire :wk_pc, 9, init: 0
  wire :wk_jump, 1, init: 0
  wire :lt_next, 5
  wire :lt_nextv, 1
  wire :lt_mask, 32

  wire :pt_rd3_slot, 5
  wire :pt_rd3_trap, 1
  wire :pt_rd3_state, 2

  # the {'EXIT', From, Reason} emitter: four flits of immediates, in
  # PicoBEAM.Serial's postfix order, straight into the target's mailbox
  wire :sd_st, 3, init: 0
  wire :sd_slot, 5, init: 0
  wire :sd_from, 36, init: 0
  wire :sd_reason, 8, init: 0
  wire :sd_en, 1
  wire :sd_word, 36
  wire :sd_head, 1
  wire :sd_idle, 1
  wire :exit_hash, 8
  wire :sig_traps, 1
  # `next_slot` names the peer the walk is ABOUT to signal, so the trap
  # bit read from it belongs to that peer — and by the time `sig_en`
  # rises for it, `next_slot` has already advanced to the one after.
  # The consumer therefore wants the PREVIOUS cycle's answer, which is
  # the same shape as every other "later means another cycle" in this
  # machine.
  wire :sig_traps_d, 1, init: 0

  wire :has_wb2_w, 1
  wire :wb2_en_w, 1
  wire :wb2_addr, 4
  wire :wb2_data, 36

  # the wb2 pipeline: a heap command in X this cycle means a result on
  # `rd_late` the next one, for the seat that WAS in X
  wire :hp_en_d, 1, init: 0
  wire :hp_seat_d, 2, init: 0
  wire :hp_rd_d, 4, init: 0
  # which unit the pending late result will come from: 0 heap, 1 pool
  wire :hp_src_d, 1, init: 0
  wire :late_word, 36

  # per-seat heap result latches
  wire :hl0, 36, init: 0
  wire :hl1, 36, init: 0
  wire :hl2, 36, init: 0
  wire :hl3, 36, init: 0
  wire :hd0, 4, init: 0
  wire :hd1, 4, init: 0
  wire :hd2, 4, init: 0
  wire :hd3, 4, init: 0

  # per-seat latches (a commit happens turns after the decode)
  wire :cd0, 4, init: 0
  wire :cd1, 4, init: 0
  wire :cd2, 4, init: 0
  wire :cd3, 4, init: 0
  wire :rv0, 36, init: 0
  wire :rv1, 36, init: 0
  wire :rv2, 36, init: 0
  wire :rv3, 36, init: 0
  wire :sr0, 4, init: 0
  wire :sr1, 4, init: 0
  wire :sr2, 4, init: 0
  wire :sr3, 4, init: 0

  # ---- cross-engine spawn (`notes/49`)
  #
  # Placement is round-robin from HOME and only for a spawn whose
  # arguments are all IMMEDIATE — a boxed argument is a pointer into
  # THIS engine's heap and the far end cannot read it. `Machine` makes
  # the same decision with `Enum.all?(args, &immediate?/1)`; this is the
  # gate's version of that test, kept exact rather than conservative by
  # tracking boxedness at the moment each argument is STAGED.
  param :N_ENG, default: 1
  param :TB_CONS, default: PicoBEAM.Term.tag_value(:cons)
  param :TB_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)
  param :TB_FUN, default: PicoBEAM.Term.tag_value(:fun)
  param :TB_MAP, default: PicoBEAM.Term.tag_value(:map)
  param :TB_BIN, default: PicoBEAM.Term.tag_value(:bin)

  # per-seat staging boxedness: bit i is set when staged register i
  # holds a pointer. Stale bits above the live arity are harmless
  # because the test masks to `(1 << arity) - 1`, and every index below
  # the arity is written by an `arg` before the spawn that reads it.
  wire :bx0, 16, init: 0
  wire :bx1, 16, init: 0
  wire :bx2, 16, init: 0
  wire :bx3, 16, init: 0
  wire :bx_w0, 1
  wire :bx_w1, 1
  wire :bx_w2, 1
  wire :bx_d0, 1
  wire :bx_d1, 1
  wire :bx_d2, 1
  wire :bx_set, 16
  wire :bx_clr, 16
  wire :bx_cur, 16
  wire :sp_rr, 4, init: 0
  wire :sp_tgt, 4
  wire :sp_arity_x, 3
  wire :sp_mask, 16
  wire :sp_boxed_x, 1
  wire :sp_remote_x, 1
  # per-seat spawn placement latches, written at X with the rest
  wire :spr0, 1, init: 0
  wire :spr1, 1, init: 0
  wire :spr2, 1, init: 0
  wire :spr3, 1, init: 0
  wire :spt0, 4, init: 0
  wire :spt1, 4, init: 0
  wire :spt2, 4, init: 0
  wire :spt3, 4, init: 0
  wire :spa0, 3, init: 0
  wire :spa1, 3, init: 0
  wire :spa2, 3, init: 0
  wire :spa3, 3, init: 0
  wire :f_rem, 1
  wire :f_tgt_eng, 4
  wire :f_arity, 3

  # ---- the remote-spawn transport
  #
  # One outstanding remote spawn per engine. Four could be, but the
  # gain is throughput on a path that is already a ring round trip and
  # the cost is four copies of every register below; a spawn-parked
  # context cannot be unseated (`f_run` is `cur_state == 1`) and cannot
  # be reordered past anything, so one at a time changes nothing a
  # program can observe.
  wire :ro_busy, 1, init: 0
  wire :ro_seat, 2, init: 0
  wire :ro_have, 1, init: 0
  wire :ro_pdone, 1, init: 0
  wire :ro_pid, 36, init: 0
  wire :ro_sr, 4
  wire :ro_pw, 1
  wire :rem_ok, 1
  wire :rem_bad, 1
  wire :su_spawn_ready, 1
  wire :su_spawn_full, 1
  wire :su_pid_wr, 1
  wire :su_pid_seat, 2
  wire :su_pid_reg, 4
  wire :su_pid_data, 36
  wire :su_op_spawn, 1
  wire :su_sp_ctx, 2
  wire :spawn_park, 1
  wire :sc_rem, 1
  wire :sc_local, 1
  wire :f_slot_o, 5
  wire :f_serial, 22

  # egress FSM: 0 idle · 1 collect (drain the staging bank) ·
  #             2 head · 3 payload
  wire :rt_st, 2, init: 0
  # the ACTUAL ring kind — 1 request, 2 reply — and not a flag that the
  # egress adds one to. `rt_kind + 1` in a one-bit wire is `0`, which
  # sent every reply out as a MESSAGE and left the requester parked
  # forever. Verilog's self-determined width rule, for the third time
  # in this project (`notes/26` entry 27).
  wire :rt_kind, 4, init: 0
  wire :rt_busy, 1
  wire :rt_i, 3, init: 0
  wire :rt_n, 4, init: 0
  wire :rt_deng, 4, init: 0
  wire :rt_hword, 36, init: 0
  wire :rt_arity, 3, init: 0
  wire :rt_pc, 9, init: 0
  wire :rt_pay, 36
  wire :rt_sel, 36
  wire :rt_j, 3
  wire :rt_wr, 1
  wire :rt_start, 1
  wire :rt_rep_go, 1
  wire :rg_ready, 1
  wire :ser_ring_en, 1
  wire :tx0, 36, init: 0
  wire :tx1, 36, init: 0
  wire :tx2, 36, init: 0
  wire :tx3, 36, init: 0
  wire :tx4, 36, init: 0
  wire :tx5, 36, init: 0
  wire :tx6, 36, init: 0
  wire :tx7, 36, init: 0

  # ingress side of the same transaction
  wire :rx_pend, 1, init: 0
  wire :rx_rep, 1, init: 0
  wire :rx_pc, 9, init: 0
  wire :rx_ar, 3, init: 0
  wire :rx_from, 36, init: 0
  wire :rx_child, 36, init: 0
  wire :rx_idx, 7
  wire :rx_sel, 36
  wire :rx_full, 1
  wire :rg_req, 1
  wire :rg_rep, 1
  wire :rg_take, 1
  wire :rx0, 36, init: 0
  wire :rx1, 36, init: 0
  wire :rx2, 36, init: 0
  wire :rx3, 36, init: 0
  wire :rx4, 36, init: 0
  wire :rx5, 36, init: 0
  wire :rx6, 36, init: 0
  wire :rx7, 36, init: 0
  wire :su_rsp_req, 1
  wire :su_rsp_pc, 9
  wire :su_rsp_idx, 5
  wire :su_rsp_arg, 36
  wire :su_rsp_ok, 1
  wire :su_rsp_slot, 5
  wire :su_rsp_serial, 22
  wire :su_rsp_done, 1
  wire :f_cd, 4
  wire :f_sr, 4
  wire :fill_rv, 36

  # ret-fill write trails its read by one cycle (sync frame read)
  wire :fw_en, 1, init: 0
  wire :fw_idx, 4, init: 0
  wire :fw_seat, 2, init: 0
  # swap-in fill likewise
  wire :sw_en, 1, init: 0
  wire :sw_idx, 4, init: 0
  wire :sw_seat, 2, init: 0

  # frame addressing by proc slot (the seat file's mapping)
  wire :push_slot, 5
  wire :pop_slot, 5
  wire :fill_slot, 5

  # ---- M4: mailbox / send / receive
  wire :any_send, 1
  wire :snd_en, 1
  wire :any_rstart, 1
  wire :any_rhash, 1
  wire :any_rpeek, 1
  wire :any_rskip, 1
  wire :any_rtake, 1
  wire :any_rwait, 1
  wire :snd_pid, 36
  wire :snd_msg, 36
  wire :snd_hash, 8
  wire :su_pt_slot, 5
  wire :pt_rd2_in, 5
  wire :pt_rd2_serial, 22
  wire :pt_rd2_state, 2
  wire :su_cmd_mb, 3
  wire :su_slot_mb, 5
  wire :su_word_mb, 36
  wire :mb_word_w, 36
  wire :mb_hash_w, 8
  wire :su_hash_mb, 8
  wire :delivered, 1
  wire :dead_letter, 1
  wire :mb_ovf, 1
  wire :mb_ovf_slot, 5
  wire :bad_pid, 1
  wire :mb_cmd, 3
  wire :mb_slot, 5
  wire :mb_qslot, 5
  wire :mb_filter, 8
  wire :mb_filtered, 1
  wire :mb_full, 1
  wire :mb_busy, 1
  wire :mb_done, 1
  wire :mb_hit, 1
  wire :mb_hit_word, 36
  wire :mb_scan_len, 6
  wire :mb_count, 7
  wire :mb_unseen, 1
  wire :mb_rf_word, 36
  wire :scan_free, 1
  wire :x_recv_op, 1
  wire :rwait_blk, 1
  wire :peek_slot, 5
  wire :peek_filter, 8
  wire :peek_filtered, 1
  wire :rtake_word, 36
  wire :unblock_en, 1
  wire :unblock_seat, 2
  # DECLARED, and that is not a formality. An undeclared name assigned
  # in a comb block reaches Verilog as an implicit ONE-BIT net, so
  # `unblock_pc` carried pc 9 as 1 and every receive timeout resumed at
  # bundle 1 instead of the label it named — re-running the spawn ahead
  # of it, forever, once every deadline.
  wire :unblock_jump, 1
  wire :unblock_pc, 9
  wire :kill_en, 1
  wire :kill_seat, 2
  wire :wk0, 1
  wire :wk1, 1
  wire :wk2, 1
  wire :wk3, 1
  wire :kl0, 1
  wire :kl1, 1
  wire :kl2, 1
  wire :kl3, 1
  wire :doom_vec, 32
  wire :pt_rd2_serial, 22
  wire :pt_rd2_state, 2
  wire :scan_done_seat_w, 2, init: 0
  wire :dm_pend, 1, init: 0
  wire :dm_reason, 8, init: 7
  wire :tp_pend, 1, init: 0
  wire :tp_slot, 5, init: 0
  wire :tp_flag, 1, init: 0
  wire :pt_trap_go, 1
  wire :wk_cmd, 4
  wire :trap_flag, 1
  wire :lk_pend, 1, init: 0
  wire :lk_cmd_r, 3, init: 0
  wire :lk_pid_r, 36, init: 0

  # ---- notes/53 Phase 4: supervision crosses the ring.
  #
  # A sup op whose target pid is foreign parks its context (BarrelSeq
  # state 18) and lands here: per-seat packet latches written at X,
  # claimed at the seat's own F slot into the shared egress latch.
  wire :sup_remote, 1
  wire :sup_park_f, 1
  wire :rs0_kind, 4, init: 0
  wire :rs1_kind, 4, init: 0
  wire :rs2_kind, 4, init: 0
  wire :rs3_kind, 4, init: 0
  wire :rs0_dest, 36, init: 0
  wire :rs1_dest, 36, init: 0
  wire :rs2_dest, 36, init: 0
  wire :rs3_dest, 36, init: 0
  wire :rs0_ref, 22, init: 0
  wire :rs1_ref, 22, init: 0
  wire :rs2_ref, 22, init: 0
  wire :rs3_ref, 22, init: 0
  wire :rs0_reason, 8, init: 0
  wire :rs1_reason, 8, init: 0
  wire :rs2_reason, 8, init: 0
  wire :rs3_reason, 8, init: 0
  wire :rs_kind_f, 4
  wire :rs_dest_f, 36
  wire :rs_ref_f, 22
  wire :rs_reason_f, 8
  wire :f_self_pid, 36

  # the ONE outbound-signal latch: exit signals, DOWNs, sup requests
  # and noproc replies all drain through it, one packet at a time —
  # every producer holds until it frees, which is the backpressure
  wire :sx_pend, 1, init: 0
  wire :sx_kind, 4, init: 0
  wire :sx_dest, 36, init: 0
  wire :sx_from, 36, init: 0
  wire :sx_ref, 22, init: 0
  wire :sx_reason, 8, init: 0
  wire :sx_free, 1
  wire :sxw_lt, 1
  wire :sxw_np, 1
  wire :sxw_sup, 1
  wire :np_want, 1
  wire :np_kind, 4
  wire :np_dest, 36
  wire :np_ref, 22
  wire :rt_sx_go, 1
  wire :rt_sup, 1
  wire :sx_ref_word, 36

  # ingress: the sup-kind flit latches and per-kind dispatch
  wire :rgs_a, 36, init: 0
  wire :rgs_b, 22, init: 0
  wire :rg_sup, 1
  wire :rg_fin, 1
  wire :rg_pay0, 1
  wire :rg_k3, 1
  wire :rg_k4, 1
  wire :rg_k5, 1
  wire :rg_k6, 1
  wire :rg_k7, 1
  wire :lt_gate, 1
  wire :rg3_ok, 1
  wire :rg3_add, 1
  wire :rg3_np_want, 1
  wire :rg3_pop, 1
  wire :rg4_pop, 1
  wire :rg5_np_want, 1
  wire :rg5_add, 1
  wire :rg5_pop, 1
  wire :rg6_fin, 1
  wire :rg6_rd, 1
  wire :rg6_kill, 1
  wire :rg6_doom, 1
  wire :rg6_msg, 1
  wire :rg6_drop, 1
  wire :rg6_pop, 1
  wire :rg7_fin, 1
  wire :rg7_msg, 1
  wire :rg7_pop, 1
  wire :rg_hi_pop, 1
  wire :dm_gate, 1
  wire :sd_gate, 1
  wire :lk_a_r, 5, init: 0
  wire :lk_b_r, 5, init: 0
  wire :lk_ref_r, 22, init: 0
  wire :su_died_slot, 5
  wire :su_died_pid, 36
  wire :dm_slot, 5, init: 0
  wire :wake_queued, 1
  wire :sd_wake, 1
  wire :rg_last, 1
  wire :wake_en, 1
  wire :wake_slot, 5
  wire :wk_pend, 1, init: 0
  wire :wk_slot, 5, init: 0
  wire :pt_free, 1
  wire :pt_wake_go, 1
  wire :rq_wake_go, 1
  wire :pt_doom_go, 1

  # per-seat receive state: the filter a `recv_hash` set, and the word
  # the last successful peek found (which `recv_take` writes to rd)
  wire :rf0, 8, init: 0
  wire :rf1, 8, init: 0
  wire :rf2, 8, init: 0
  wire :rf3, 8, init: 0
  wire :rfe0, 1, init: 0
  wire :rfe1, 1, init: 0
  wire :rfe2, 1, init: 0
  wire :rfe3, 1, init: 0
  # ...and its LENGTH, which `take` and `skip` both need to step over
  # a whole message rather than one flit
  wire :rl0, 6, init: 1
  wire :rl1, 6, init: 1
  wire :rl2, 6, init: 1
  wire :rl3, 6, init: 1
  wire :mb_head, 1
  wire :mb_len, 6
  wire :mb_hit_idx, 6
  wire :mb_hit_len, 6
  wire :mb_free, 7
  wire :x_rlen, 6
  wire :rw0, 36, init: 0
  wire :rw1, 36, init: 0
  wire :rw2, 36, init: 0
  wire :rw3, 36, init: 0

  # ---- entry 38: a peek that hits a SHORT message must still WRITE
  # rd — the compound path lands its pointer through the deserialiser
  # writeback (`dzw_*`), and the immediate path had nothing. Same
  # deferred-latch shape: catch at scan completion, release at the
  # owner's own X slot, resume the seat on the write cycle.
  wire :pkw_pend, 1, init: 0
  wire :pkw_seat, 2, init: 0
  wire :pkw_rd, 4, init: 0
  wire :pkw_word, 36, init: 0
  wire :pkw_wb, 1

  # witnesses
  wire :sends, 12, init: 0
  wire :recvs, 12, init: 0
  wire :evicts, 8, init: 0
  wire :spawns, 12, init: 0
  wire :deaths, 12, init: 0
  wire :flt, 1, init: 0
  wire :flt_r, 8, init: 0
  wire :flt_s, 5, init: 0
  wire :flt_n, 8, init: 0

  comb do
    # ---- D stage: read addresses (rs+imm shapes read through f1)
    ra_a0 = dr0_rsf1 * d_rd0 + bnot(dr0_rsf1) * d_ra0
    ra_a2 = dr1_rsf1 * d_rd1 + bnot(dr1_rsf1) * d_ra1
    ra_a4 = dr2_rsf1 * d_rd2 + bnot(dr2_rsf1) * d_ra2

    # ---- X stage: aggregation (one-hot by the bundle contract)
    br0 = bor(band(c0_bift, rw_rd0 == 0x10000000E), band(c0_biff, rw_rd0 == 0x10000000F))
    br1 = bor(band(c1_bift, rw_rd2 == 0x10000000E), band(c1_biff, rw_rd2 == 0x10000000F))
    br2 = bor(band(c2_bift, rw_rd4 == 0x10000000E), band(c2_biff, rw_rd4 == 0x10000000F))

    # `recv_peek` latches its none-label through the SAME target mux a
    # call/jmp uses (BarrelSeq's `tgt0 = pc_target`), so it has to be in
    # this mask or the label reads as zero and a failed peek restarts the
    # module at bundle 0. Safe by rule 3: jmp/call/spawn/peek are all
    # system ops, and a bundle may hold only one.
    # `try_begin`'s imm12 is the HANDLER label, and it rides the same
    # target mux every other labelled system op rides
    ctl0 = bor(c0_try, bor(c0_jmp, bor(br0, bor(c0_call, bor(c0_spawn, c0_rpeek)))))
    ctl1 = bor(c1_try, bor(c1_jmp, bor(br1, bor(c1_call, bor(c1_spawn, c1_rpeek)))))
    ctl2 = bor(c2_try, bor(c2_jmp, bor(br2, bor(c2_call, bor(c2_spawn, c2_rpeek)))))
    pc_target = ctl0 * imm0[8..0] + ctl1 * imm1[8..0] + ctl2 * imm2[8..0]

    any_jump = bor(bor(c0_jmp, br0), bor(bor(c1_jmp, br1), bor(c2_jmp, br2)))
    any_call = bor(c0_call, bor(c1_call, c2_call))
    # `ret` from the outermost frame is the process ENDING, not a
    # return: there is no caller to return to and no link to read, and
    # BEAM exits such a process with reason `normal`. The gates used to
    # pop an empty stack, read link zero, and continue at bundle 0 —
    # which is `main`, so a spawned child that simply returned re-ran
    # the whole program, spawned another child, and did it again
    # (`notes/31`). Route it to the death path at X instead; the depth
    # comes from the frame store's query port, addressed by the X
    # context's slot.
    raw_ret = bor(c0_ret, bor(c1_ret, c2_ret))
    ret_top = band(raw_ret, x_depth == 0)
    any_ret = band(raw_ret, bnot(ret_top))
    # `real_halt` is the OPCODE. `any_halt` is what the SEQUENCER routes
    # to the death path, and `notes/31` widened that to include a
    # top-level `ret` — a process ending is not the VM ending, and
    # wiring the VM halt to `any_halt` would stop the machine every time
    # a spawned function returned.
    real_halt = bor(c0_halt, bor(c1_halt, c2_halt))
    any_halt = bor(ret_top, real_halt)
    any_try = bor(c0_try, bor(c1_try, c2_try))
    any_tend = bor(c0_tend, bor(c1_tend, c2_tend))
    try_dest_x = c0_try * rd0 + c1_try * rd1 + c2_try * rd2
    any_spawn = bor(c0_spawn, bor(c1_spawn, c2_spawn))
    any_yield = bor(c0_yield, bor(c1_yield, c2_yield))
    any_out = bor(c0_out, bor(c1_out, c2_out))
    any_tail = bor(c0_tail, bor(c1_tail, c2_tail))
    any_self = bor(c0_self, bor(c1_self, c2_self))

    any_send = bor(c0_send, bor(c1_send, c2_send))
    any_rstart = bor(c0_rstart, bor(c1_rstart, c2_rstart))
    any_rhash = bor(c0_rhash, bor(c1_rhash, c2_rhash))
    any_rpeek = bor(c0_rpeek, bor(c1_rpeek, c2_rpeek))
    any_rskip = bor(c0_rskip, bor(c1_rskip, c2_rskip))
    any_rtake = bor(c0_rtake, bor(c1_rtake, c2_rtake))
    any_rwait = bor(c0_rwait, bor(c1_rwait, c2_rwait))

    # send's two sources sit on the slot's ordinary ra/rb ports
    snd_en = band(any_send, x_en)
    snd_pid = c0_send * rw_rd0 + c1_send * rw_rd2 + c2_send * rw_rd4
    snd_msg = c0_send * rw_rd1 + c1_send * rw_rd3 + c2_send * rw_rd5

    # cons (3) or tuple (4): the only two tags that name heap cells
    snd_ptr = bor(snd_msg[35..32] == 3, snd_msg[35..32] == 4)

    # A send parks when the message needs walking OR when it is leaving
    # the engine. A REMOTE send always parks, even an immediate one:
    # a packet is a header entry plus its flits, X cannot stall to push
    # two, and routing every remote message through the serialiser —
    # an immediate is a one-flit serialisation — gives the ring one
    # producer instead of two. The model charges a wire
    # `@wire_base + hops + flits` regardless, so this costs nothing that
    # was not already in the budget.
    #
    # A LOCAL immediate still retires at X in one turn, which is the
    # case ping-pong measures.
    is_send_long = bor(band(delivered, snd_ptr), snd_remote)
    deliver_now = band(delivered, bnot(snd_ptr))

    sr_stream = band(ser_busy, sr_len != 0)

    # ---- ring egress
    #
    # The header goes in at `go_emit`, carrying the destination PID and
    # the flit count; the payload follows one entry per emitted flit.
    ring_push = band(sr_rem, bor(band(ser_go_emit, bnot(sr_hdr)), ser_emit))
    ser_ring_en = band(ring_push, rg_ready)

    # ---- ring egress: two producers, an arbiter rather than a mux
    #
    # `notes/29` left the ring with exactly one producer. The spawn
    # transport is a second, and a reply must not be able to interleave
    # into the middle of somebody's message — so the FSM takes the ring
    # WHOLE, and the serialiser sees a ring that is simply not ready
    # while it does. `rg_ready` is the one place that is expressed;
    # every serialiser test of readiness goes through it.
    rt_busy = rt_st != 0
    rg_ready = band(ring_w_ready, bnot(rt_busy))
    rt_wr = band(bor(rt_st == 2, rt_st == 3), ring_w_ready)

    ring_w_en = bor(rt_wr, ser_ring_en)
    ring_w_head = rt_busy * (rt_st == 2) +
      band(bnot(rt_busy), 1) * band(ser_go_emit, bnot(sr_hdr))

    ring_w_word =
      rt_busy * ((rt_st == 2) * rt_hword + (rt_st == 3) * rt_pay) +
        band(bnot(rt_busy), 1) *
          (band(ser_go_emit, bnot(sr_hdr)) * sr_pid +
             band(bnot(band(ser_go_emit, bnot(sr_hdr))), 1) * ser_word)

    ring_w_len = rt_busy * rt_n + band(bnot(rt_busy), 1) * ser_count
    # kind 0 is a message; 1 is `spawn_req` and 2 is `spawn_rsp`. The
    # field existed from the first packet precisely so this would be a
    # case and not a re-cut of the wire format.
    ring_w_kind = rt_busy * rt_kind
    ring_w_deng = rt_busy * rt_deng + band(bnot(rt_busy), 1) * sr_pid[31..28]

    # flit 0 of a request carries the entry pc and the arity; flits
    # 1..arity carry the arguments themselves, which are IMMEDIATE by
    # the placement rule and so mean the same thing on both engines.
    # A reply is one flit: the child's PID.
    rt_j = band(rt_kind == 1, 1) * (rt_i - 1) + band(rt_kind == 2, 1) * rt_i

    rt_sel =
      (rt_j == 0) * tx0 + (rt_j == 1) * tx1 + (rt_j == 2) * tx2 + (rt_j == 3) * tx3 +
        (rt_j == 4) * tx4 + (rt_j == 5) * tx5 + (rt_j == 6) * tx6 + (rt_j == 7) * tx7

    rt_sup = rt_kind > 2
    sx_ref_word = 25_769_803_776 + sx_ref

    # kinds 3..7 read the egress latch directly — the packet shapes:
    #   3/4 link/unlink: [from]           6 exit: [from, reason]
    #   5 monitor:       [from, ref]      7 DOWN: [ref, from, reason]
    rt_pay =
      band(rt_kind == 1, rt_i == 0) * (rt_arity * 512 + rt_pc) +
        band(bnot(band(rt_kind == 1, rt_i == 0)), bnot(rt_sup)) * rt_sel +
        band(rt_sup, bor(rt_kind == 3, rt_kind == 4)) * sx_from +
        band(rt_sup, rt_kind == 5) *
          ((rt_i == 0) * sx_from + (rt_i == 1) * sx_ref_word) +
        band(rt_sup, rt_kind == 6) *
          ((rt_i == 0) * sx_from + (rt_i == 1) * sx_reason) +
        band(rt_sup, rt_kind == 7) *
          ((rt_i == 0) * sx_ref_word + (rt_i == 1) * sx_from +
             (rt_i == 2) * sx_reason)

    # the latch takes the ring when the spawn transport is idle; a
    # reply still outranks it, a request waits behind it
    rt_sx_go = band(sx_pend, band(rt_st == 0, band(bnot(ser_busy), bnot(rx_rep))))

    # A reply outranks a request: it is unblocking a context that is
    # already parked, and the request behind it is not.
    rt_rep_go = band(rx_rep, band(rt_st == 0, bnot(ser_busy)))

    # The request starts at the parked seat's own F slot — the same
    # cycle a LOCAL spawn would commit on, which is what keeps the
    # staging drain single-claimant without an arbiter (`BarrelSeq`
    # gives at most one context an F slot per cycle, and `op_call` and
    # `op_spawn` are two states of the same context).
    # `ro_busy` alone is not the guard. `spawn_park` is true at EVERY F
    # slot of a parked seat, so the moment the reply cleared `ro_busy`
    # the next F slot started a second request — and wiped the answer
    # it had just been given on the way past. The transaction is not
    # over when the reply lands; it is over when the spawn COMMITS.
    rt_start =
      band(spawn_park,
        band(f_rem,
          band(bnot(bor(ro_busy, bor(ro_have, ro_pdone))),
            band(drain_ready,
              band(rt_st == 0,
                band(bnot(ser_busy), bnot(bor(rx_rep, sx_pend))))))))

    # ---- ring ingress
    #
    # The far end could not check this PID against our table, so it is
    # checked here, on arrival: occupied slot AND matching incarnation,
    # or the packet is consumed and dropped. That is the same
    # dead-letter rule a local send follows, one hop later.
    # In state 0 the check must read the slot of the head ARRIVING this
    # cycle, not of the pid latched from the last packet — `rg_pid` is a
    # register and would be one packet stale. `serials2`/`states2` are
    # async reads, so addressing them from the wire is valid the same
    # cycle. Sixth time this shape has bitten; first time it was caught
    # before simulation.
    rg_slot =
      band(rg_st == 0, 1) * ring_r_word[26..22] +
        band(rg_st != 0, 1) * rg_pid[26..22]

    # ...and the SERIAL has to come from the same place for the same
    # reason. Fixing only the slot left the comparison reading the
    # previous packet's incarnation, so the first head always failed the
    # check and the whole message was consumed and dropped — a machine
    # that looked like it had no ring at all.
    rg_ser =
      band(rg_st == 0, 1) * ring_r_word[21..0] +
        band(rg_st != 0, 1) * rg_pid[21..0]
    rg_live = band(pt_rd5_state != 0, pt_rd5_serial == rg_ser)
    # `ring_r_valid` is not optional here: without it the ingress
    # enqueues a zero word every cycle it sits in the payload state with
    # an empty FIFO, and the receiver dies of `mailbox_full` holding a
    # bag of nothing.
    mb_rg =
      band(band(band(band(rg_st == 1, rg_ok), ring_r_valid), rg_kind == 0),
        bnot(bor(deliver_now, sd_en)))
    # kinds 1 and 2 are the spawn transport. A REQUEST ignores `rg_ok`:
    # the head word is the REQUESTER's pid, which lives on the far
    # engine, and checking it against this table would be checking a
    # stranger's slot number. A REPLY does not ignore it — the head
    # word is ours, and a requester that died while the child was being
    # created wants its reply dropped, which is exactly what the
    # incarnation check already does for a message.
    rg_req = band(rg_st == 1, band(ring_r_valid, rg_kind == 1))
    rg_rep = band(rg_st == 1, band(ring_r_valid, rg_kind == 2))
    # the only backpressure in the ingress, and bounded: a full proc
    # table answers with a zero pid rather than holding the ring for a
    # slot that may never come.
    rg_take = band(rg_req, bnot(rx_pend))
    rx_idx = rg_len - rg_left

    # ---- ingress kinds 3..7: the sup transport (notes/53 Phase 4).
    # Non-final flits latch and pop freely; the FINAL flit pops only
    # when the action it triggers has its resources — the same
    # stall-not-drop discipline `rg_take` set the precedent for.
    rg_sup = band(rg_st == 1, band(ring_r_valid, rg_kind > 2))
    rg_fin = rg_left == 1
    rg_pay0 = rg_left == rg_len
    rg_k3 = band(rg_sup, rg_kind == 3)
    rg_k4 = band(rg_sup, rg_kind == 4)
    rg_k5 = band(rg_sup, rg_kind == 5)
    rg_k6 = band(rg_sup, rg_kind == 6)
    rg_k7 = band(rg_sup, rg_kind == 7)

    # the signal-table command latch is free and no X-stage sup op is
    # about to claim it this cycle
    lt_gate = band(bnot(lk_pend), bnot(any_sup))

    # kind 3, link_req [from]: record, or answer noproc (an exit
    # signal, kind 6) when the target is dead or the store is full —
    # a link that could not be recorded must FAIL LOUDLY, because a
    # silent drop is a supervisor that cannot see its child die
    rg3_ok = band(rg_k3, band(rg_ok, bnot(lt_rem_full)))
    rg3_add = band(rg3_ok, lt_gate)
    rg3_np_want = band(rg_k3, bnot(band(rg_ok, bnot(lt_rem_full))))
    rg3_pop = bor(rg3_add, band(rg3_np_want, sxw_np))

    # kind 4, unlink_req [from]: remove, or drop for a dead target
    rg4_pop =
      bor(band(rg_k4, band(rg_ok, lt_gate)), band(rg_k4, bnot(rg_ok)))

    # kind 5, monitor_req [from, ref]: record at the TARGET, or answer
    # a DOWN carrying noproc
    rg5_np_want = band(rg_k5, band(rg_fin, bnot(band(rg_ok, bnot(lt_rem_full)))))
    rg5_add = band(rg_k5, band(rg_fin, band(rg_ok, band(bnot(lt_rem_full), lt_gate))))
    rg5_pop = bor(band(rg_k5, bnot(rg_fin)), bor(rg5_add, band(rg5_np_want, sxw_np)))

    # kind 6, exit_signal [from, reason]: the model's rules verbatim —
    # kill is untrappable and lands as killed; a trapping target gets
    # {'EXIT', From, Reason}; normal kills nobody; anything else dooms
    rg6_fin = band(rg_k6, rg_fin)
    rg6_rd = band(rg6_fin, band(rg_ok, band(bnot(any_sup), bnot(sd_en))))
    rg6_kill = ring_r_word[7..0] == 2
    rg6_doom =
      band(rg6_rd, bor(rg6_kill, band(bnot(pt_rd3_trap), ring_r_word[7..0] != 0)))
    rg6_msg = band(rg6_rd, band(bnot(rg6_kill), pt_rd3_trap))
    rg6_drop =
      band(rg6_rd, band(bnot(rg6_kill), band(bnot(pt_rd3_trap), ring_r_word[7..0] == 0)))
    dm_gate =
      bnot(bor(dm_pend, bor(lt_sig, bor(mb_ovf, ser_abort))))
    sd_gate = band(sd_st == 0, band(mb_free > 4, bnot(lt_sig)))
    rg6_pop =
      bor(band(rg_k6, bnot(rg_fin)),
        bor(band(rg6_fin, bnot(rg_ok)),
          bor(band(rg6_doom, dm_gate), bor(band(rg6_msg, sd_gate), rg6_drop))))

    # kind 7, down_signal [ref, from, reason]: always a message
    rg7_fin = band(rg_k7, rg_fin)
    rg7_msg =
      band(rg7_fin, band(rg_ok, band(sd_gate, band(bnot(any_sup), bnot(sd_en)))))
    rg7_pop =
      bor(band(rg_k7, bnot(rg_fin)), bor(band(rg7_fin, bnot(rg_ok)), rg7_msg))

    rg_hi_pop = band(rg_st == 1, band(ring_r_valid, rg_kind > 7))

    # ---- the noproc replies claim the egress latch; a remote sup op
    # parked at its F slot claims it last
    sx_free = bnot(sx_pend)
    sxw_lt = band(lt_sig, lt_sig_remote)
    np_want = bor(rg3_np_want, rg5_np_want)
    sxw_np = band(np_want, band(sx_free, bnot(sxw_lt)))
    np_kind = rg3_np_want * 6 + rg5_np_want * 7
    np_dest = rg3_np_want * ring_r_word + rg5_np_want * rgs_a
    np_ref = rg5_np_want * ring_r_word[21..0]
    sxw_sup = band(sup_park_f, band(sx_free, bnot(bor(sxw_lt, np_want))))

    rs_kind_f =
      (f_seat == 0) * rs0_kind + (f_seat == 1) * rs1_kind + (f_seat == 2) * rs2_kind +
        (f_seat == 3) * rs3_kind
    rs_dest_f =
      (f_seat == 0) * rs0_dest + (f_seat == 1) * rs1_dest + (f_seat == 2) * rs2_dest +
        (f_seat == 3) * rs3_dest
    rs_ref_f =
      (f_seat == 0) * rs0_ref + (f_seat == 1) * rs1_ref + (f_seat == 2) * rs2_ref +
        (f_seat == 3) * rs3_ref
    rs_reason_f =
      (f_seat == 0) * rs0_reason + (f_seat == 1) * rs1_reason + (f_seat == 2) * rs2_reason +
        (f_seat == 3) * rs3_reason
    f_self_pid = 21_474_836_480 + eng_id * 268_435_456 + f_slot_o * 4_194_304 + f_serial

    ring_r_pop =
      bor(band(rg_st == 0, ring_r_valid),
        band(band(rg_st == 1, ring_r_valid),
          bor(mb_rg,
            bor(band(bnot(rg_ok), rg_kind == 0),
              bor(rg_take,
                bor(rg_rep,
                  bor(rg3_pop,
                    bor(rg4_pop,
                      bor(rg5_pop,
                        bor(rg6_pop, bor(rg7_pop, rg_hi_pop)))))))))))

    # ---- the receiving half of a remote spawn
    #
    # A full table answers :system_limit rather than waiting: the reply
    # carries a zero pid and the REQUESTER dies of it, which is the
    # same death a local `spawn` into a full table takes (`notes/13`).
    rx_full = band(rx_pend, su_spawn_full)
    su_rsp_req = band(rx_pend, bnot(su_spawn_full))
    su_rsp_pc = rx_pc

    rx_sel =
      (su_rsp_idx == 0) * rx0 + (su_rsp_idx == 1) * rx1 + (su_rsp_idx == 2) * rx2 +
        (su_rsp_idx == 3) * rx3 + (su_rsp_idx == 4) * rx4 + (su_rsp_idx == 5) * rx5 +
        (su_rsp_idx == 6) * rx6 + (su_rsp_idx == 7) * rx7

    su_rsp_arg = band(su_rsp_idx < rx_ar, 1) * rx_sel

    # ---- the sending half: what `BarrelSeq` is told at the F slot
    #
    # State 9 is ALREADY the wait. `notes/47` sized a fourth state
    # machine here — a park that resumes with a value and does not
    # replay — and it turned out not to be needed: a spawn park resumes
    # on `spawn_ready` and advances its own pc, so a remote spawn is
    # the same park with a slower answer.
    rem_ok = band(band(ro_pdone, ro_seat == f_seat), ro_pid != 0)
    rem_bad = band(band(ro_pdone, ro_seat == f_seat), ro_pid == 0)
    spawn_ready = f_rem * rem_ok + band(bnot(f_rem), 1) * su_spawn_ready
    spawn_full = f_rem * rem_bad + band(bnot(f_rem), 1) * su_spawn_full
    sc_rem = band(spawn_commit, f_rem)
    sc_local = band(spawn_commit, bnot(f_rem))

    # The staging drain has one claimant per cycle because `BarrelSeq`
    # gives one context the F slot; a remote request claims it in the
    # same place a local commit does.
    op_spawn = bor(su_op_spawn, rt_start)
    sp_ctx = rt_start * spawn_seat + band(bnot(rt_start), 1) * su_sp_ctx

    # The pid write-back waits for a cycle the destination seat is not
    # using — which is every cycle, because it is parked. That is the
    # trick `SeatUnit` already plays for a local spawn, and the reason
    # the two can share the write port: a seat cannot be doing both.
    ro_sr = (ro_seat == 0) * sr0 + (ro_seat == 1) * sr1 + (ro_seat == 2) * sr2 +
      (ro_seat == 3) * sr3

    ro_pw = band(band(ro_have, bnot(ro_pdone)), x_seat == ro_seat)
    pid_wr = bor(su_pid_wr, ro_pw)
    pid_seat = su_pid_wr * su_pid_seat + ro_pw * ro_seat
    pid_reg = su_pid_wr * su_pid_reg + ro_pw * ro_sr
    pid_data = su_pid_wr * su_pid_data + ro_pw * ro_pid
    ser_free = bnot(ser_busy)
    ser_start = send_go
    ser_term =
      (send_seat == 0) * sg_msg0 + (send_seat == 1) * sg_msg1 +
        (send_seat == 2) * sg_msg2 + (send_seat == 3) * sg_msg3

    # the free-space check the two-pass protocol exists for: pass 0
    # publishes a count and HOLDS, and only a message that fits is
    # emitted. One that does not dooms the RECEIVER with `mailbox_full`,
    # which is the same rule an immediate overflow already follows.
    # A LOCAL message is measured against the target's free space before
    # a flit moves; a REMOTE one is not, because the space that matters
    # is on another engine and this side cannot see it. What a remote
    # packet waits for instead is room on the ring for its header.
    sr_fits = ser_count <= mb_free
    ser_go_emit =
      bor(band(bnot(sr_rem), band(ser_counted, sr_fits)),
        band(sr_rem, band(ser_counted, rg_ready)))

    ser_abort = band(bnot(sr_rem), band(ser_counted, bnot(sr_fits)))

    # A flit that loses the mailbox command port is RE-PRESENTED, not
    # dropped: `SerUnit` freezes on `stall` and offers the same word
    # again next cycle. The two claimants above it cannot stall — a send
    # retires at X, and the exit emitter is a fixed-length burst — so
    # backpressure is the only shape that works, and it is the shape a
    # 63-flit message needs. (The exit emitter has the older, weaker
    # version of this: it DROPS a flit that loses. Rare at 4 flits;
    # it would not have been at 63.)
    sh_word = band(bnot(sr_stream), 1) * snd_msg + sr_stream * ser_term
    sh_arity = sr_stream * ser_arity
    sh_first = sr_stream * ser_first

    # `SerUnit` addresses a cell within the ACTIVE semispace — its own
    # address is seven bits — so the space bit belongs here. It has been
    # correct only because nothing has ever flipped; the first
    # collection would have sent every serialisation reading into the
    # dead half.
    # Port B belongs to `SerUnit` while the machine runs and to the
    # collector while it does not (`notes/40`). It is a mux and not an
    # arbiter for the usual reason: the collector only runs with the
    # world stopped, and a stopped world serialises nothing.
    hpb_addr =
      cx_busy * cx_haddr +
        band(bnot(cx_busy), 1) * (hpb_space * 128 + ser_haddr[6..0])

    hpb_wr0 = band(cx_busy, cx_wr0)
    hpb_wr1 = band(cx_busy, cx_wr1)
    hpb_d0 = cx_d0
    hpb_d1 = cx_d1
    # the heap adopts the new space AND the new bump pointer: the live
    # data is already over there, so resetting to zero hands it out twice
    # two different flips (`notes/46`): state 1 MOVES the allocation
    # base to to-space and takes the space with it; state 6 adopts the
    # collector's bump pointer after one process, and must not.
    # ...and both are PULSES. State 1 waits for quiet, so it is many
    # cycles long, and a flip held high across all of them toggles the
    # semispace once per cycle. `gc_fin1` is the same condition the FSM
    # leaves state 1 on, so the flip happens on exactly the cycle the
    # state does.
    gc_fin1 = band(gc_st == 1, band(gc_wait > 8, gc_quiet))
    hp_flip = bor(gc_fin1, gc_st == 6)
    hp_flip_sp = gc_fin1
    hp_flip_ap = gc_fin1 * gc_to_base + (gc_st == 6) * cx_to_hp
    # `notes/46` split the two things `flip_en` used to conflate and gave
    # `RootWalker` a one-process mode. Both are wired here to reproduce
    # today's behaviour exactly until the per-process engine FSM drives
    # them: the flip still moves the space, the walk is still the full
    # sweep, and the collector's cursor still starts at the bottom of
    # to-space.
    gc_to_base = bnot(hpb_space) * 128
    rk_one_en = 1
    rk_one_slot = gc_slot

    mb_ser = band(band(ser_emit, bnot(sr_rem)), bnot(bor(deliver_now, sd_en)))

    # a flit is stalled by whatever it is waiting for: the mailbox
    # command port when it is going local, the ring's own space when it
    # is not. A full ring parks the sender; it does not kill anyone.
    ser_stall =
      band(ser_emit, bor(band(bnot(sr_rem), bnot(mb_ser)),
        band(sr_rem, bnot(rg_ready))))
    mb_hi = bor(deliver_now, bor(sd_en, bor(mb_ser, mb_rg)))

    # the per-seat receive filter and the last peeked word
    peek_filter =
      (peek_seat == 0) * rf0 + (peek_seat == 1) * rf1 + (peek_seat == 2) * rf2 +
        (peek_seat == 3) * rf3

    peek_filtered =
      (peek_seat == 0) * rfe0 + (peek_seat == 1) * rfe1 + (peek_seat == 2) * rfe2 +
        (peek_seat == 3) * rfe3

    peek_slot =
      (peek_seat == 0) * slot0 + (peek_seat == 1) * slot1 + (peek_seat == 2) * slot2 +
        (peek_seat == 3) * slot3

    rtake_word =
      (x_seat == 0) * rw0 + (x_seat == 1) * rw1 + (x_seat == 2) * rw2 + (x_seat == 3) * rw3

    # ---- supervision: the exit-signal path
    #
    # Whether the engine can take the NEXT signal depends on what that
    # peer is: a non-trapping one is killed through ProcTable's doom
    # vector and needs the command port, a trapping one is handed an
    # {'EXIT', From, Reason} message and needs the emitter idle. So the
    # link table publishes its next target a cycle early (`next_slot`),
    # ProcTable's third read port answers "does it trap", and the
    # readiness that gates the walk is chosen by the answer.
    # rd3 answers whoever needs a trap bit THIS cycle. An `exit2` wants
    # its target's, a failed `link` wants the caller's, and the fan-out
    # wants its next peer's — but only one system op retires per cycle,
    # so the X stage takes it and the walk waits one cycle. Bounded, and
    # it keeps a third replicated column from becoming a fourth.
    # rd3 serves whoever needs a per-process bit THIS cycle: an
    # `exit2`'s target, a failed `link`'s caller, the process an exit
    # message is landing in, or the fan-out's next peer. Everything but
    # the last of those pauses the walk for a cycle, which is why
    # `lt_ready` excludes them rather than the mux picking a loser.
    pt_rd3_slot =
      any_exit2 * sup_slot + band(any_sup, bnot(any_exit2)) * x_slot +
        band(bnot(any_sup), sd_en) * sd_slot +
        band(bnot(any_sup), bnot(sd_en)) *
          (rg6_rd * rg_slot + band(bnot(rg6_rd), 1) * lt_next)

    sig_traps = pt_rd3_trap
    lt_ready =
      band(bnot(bor(any_sup, bor(sd_en, rg6_rd))),
        band(lt_nextv,
          bor(band(sig_traps, band(sd_idle, mb_free > 4)),
            band(bnot(sig_traps), pt_free))))

    sd_idle = sd_st == 0

    # {'EXIT', From, Reason} in PicoBEAM.Serial's postfix order — four
    # flits, every one an immediate. notes/13's allocation-free rule
    # made physical: a process dying of `heap_full` can still tell its
    # supervisor why, because telling it costs no heap.
    sd_en = sd_st != 0
    sd_head = sd_st == 1

    # Two shapes through one emitter, because they differ only in
    # length and in what sits in the middle:
    #
    #   {'EXIT', From, Reason}       4 flits
    #   {'DOWN', Ref, From, Reason}  5 flits
    #
    # Postfix, so the header is last and the emitter never has to know
    # the length before it starts — except that the MAILBOX does, which
    # is why `mb_len` is a constant per kind rather than a counter.
    sd_word =
      band(bnot(sd_kind), 1) *
        ((sd_st == 1) * 0x10000000C +
           (sd_st == 2) * sd_from +
           (sd_st == 3) * (0x100000000 + sd_reason) +
           (sd_st == 4) * 0x900000003) +
        sd_kind *
          ((sd_st == 1) * 0x10000000D +
             (sd_st == 2) * (0x600000000 + sd_ref) +
             (sd_st == 3) * sd_from +
             (sd_st == 4) * (0x100000000 + sd_reason) +
             (sd_st == 5) * 0x900000004)

    # kind 2 (tuple), arity 3 or 4, first element an atom whose low
    # three bits are 12 & 7 = 4 for EXIT and 13 & 7 = 5 for DOWN — must
    # equal Encoding.shape_hash/1 for the same shapes, which
    # scripts/check_shape_hash.exs proves
    exit_hash = 156
    down_hash = 165
    sd_len = 4 + sd_kind

    lt_cmd = band(lk_pend, bnot(lt_busy)) * lk_cmd_r
    lt_cmd_pid = lk_pid_r
    lt_a = lk_a_r
    lt_b = lk_b_r
    lt_ref = lk_ref_r
    lt_die = band(died, bnot(lt_busy))
    lt_die_slot = su_died_slot
    lt_die_pid = su_died_pid
    # a halt is `normal` (reserved atom 0) and propagates to nobody
    # A process killed by a SIGNAL never faulted at X, so `any_fault_r`
    # reads `normal` for it — and `normal` does not propagate, which
    # silently stopped a dying child's reason from ever reaching a
    # linked, trapping supervisor. The reason a doomed slot died of is
    # the one written into its table entry; take it from there.
    lt_doomed = band(doom_vec >>> su_died_slot, 1)

    lt_die_reason =
      lt_doomed * pt_rd4_reason + band(bnot(lt_doomed), died_fault) * any_fault_r
    mb_word_w =
      band(bnot(bor(sd_en, bor(mb_ser, mb_rg))), 1) * su_word_mb +
        sd_en * sd_word +
        band(bnot(sd_en), mb_ser) * ser_word +
        band(bnot(bor(sd_en, mb_ser)), mb_rg) * ring_r_word
    mb_hash_w =
      band(bnot(sd_en), 1) * su_hash_mb +
        band(sd_en, bnot(sd_kind)) * exit_hash + band(sd_en, sd_kind) * down_hash

    # ---- the mailbox command port: enqueue first, then the X-stage
    # receive ops, then a parked context's scan claim. One X context and
    # one F context per cycle, so this is a priority chain, not an
    # arbiter — the seventh time that rule has paid.
    x_recv_op =
      bor(band(x_en, bor(any_rstart, bor(any_rskip, band(any_rtake, bnot(is_rtake_long))))),
        dz_take)

    # no new scan while a peek writeback is still waiting for its
    # owner's slot: a second short hit would need the same latch
    pkw_wb = band(pkw_pend, x_seat == pkw_seat)
    scan_free =
      band(bnot(mb_busy), band(bnot(mb_hi), band(bnot(x_recv_op), bnot(pkw_pend))))

    # an exit-signal message sits between a send and the receive ops:
    # it is already the lowest-priority producer in the machine, and
    # making it wait on a receive would let a process delay news of its
    # own supervisor's death
    mb_cmd =
      deliver_now * 1 +
        band(bnot(deliver_now), sd_en) * 1 +
        band(bnot(bor(deliver_now, sd_en)), mb_ser) * 1 +
        band(bnot(bor(deliver_now, sd_en)), mb_rg) * 1 +
        band(bnot(mb_hi), band(x_en, any_rstart)) * 2 +
        band(bnot(mb_hi), band(x_en, any_rskip)) * 5 +
        band(bnot(mb_hi), band(x_en, band(any_rtake, bnot(is_rtake_long)))) * 4 +
        band(bnot(mb_hi), dz_take) * 4 +
        band(bnot(bor(mb_hi, x_recv_op)), peek_go) * 3

    mb_slot =
      deliver_now * su_slot_mb +
        band(bnot(deliver_now), sd_en) * sd_slot +
        band(bnot(bor(deliver_now, sd_en)), mb_ser) * sr_slot +
        band(bnot(bor(deliver_now, sd_en)), mb_rg) * rg_slot +
        band(bnot(mb_hi), band(x_recv_op, bnot(dz_take))) * x_slot +
        band(bnot(mb_hi), dz_take) * dz_pslot +
        band(bnot(bor(mb_hi, x_recv_op)), peek_go) * peek_slot

    # the probe port answers `full` for a send and `unseen` for a wait;
    # only one of the two can be at X in any cycle
    # rd2 answers `send` when a send is at X and the supervision ops
    # otherwise; one system op per bundle means they never both want it
    pt_rd2_in =
      any_sup * sup_slot + band(any_regn, nm_loc) * nm_pid_w[27..22] +
        band(bnot(bor(any_sup, band(any_regn, nm_loc))), 1) * su_pt_slot

    # the probe slot: the sender's target at X, the emitter's while it
    # runs, and — new — the serialiser's while pass 0's count is being
    # measured against that slot's free space
    mb_qslot =
      any_send * su_pt_slot +
        band(bnot(any_send), sd_en) * sd_slot +
        band(bnot(any_send), band(bnot(sd_en), bor(ser_counted, sr_stream))) * sr_slot +
        band(bnot(any_send), band(bnot(sd_en), bnot(bor(ser_counted, sr_stream)))) * x_slot
    mb_filter = peek_filter
    mb_filtered = peek_filtered

    # the running seat's latched message length. take and skip step by
    # a whole message; an enqueue on the immediate path is one flit and
    # is its own head.
    x_rlen = (x_seat == 0) * rl0 + (x_seat == 1) * rl1 + (x_seat == 2) * rl2 + (x_seat == 3) * rl3
    x_ridx = (x_seat == 0) * ri0 + (x_seat == 1) * ri1 + (x_seat == 2) * ri2 + (x_seat == 3) * ri3

    # A one-flit message IS its own term — an immediate needs no heap and
    # no rebuild, which is what let ping-pong run before the heap came
    # back (notes/17 decision 5). A compound one is rebuilt at the PEEK,
    # not at the take: a receive clause has to look INSIDE the candidate
    # to decide whether it matches, and BEAM's own lowering does exactly
    # that — `istag`/`tarity`/`tget` against the peeked value, then
    # `remove_message` only if the pattern held. So the peek is what
    # parks (`scan_long`), the rebuilt pointer replaces the head flit in
    # the per-seat latch, and `recv_take` is always the short path: hand
    # over the latch, free the entry.
    #
    # The price is a rebuild for candidates the clause then rejects —
    # heap garbage, bounded by the scan, and the honest cost of an
    # architecture with no GC yet. The alternative (match on the shape
    # hash first, via `recv_hash`) is an optimisation on top of this,
    # not a substitute for it: a hash cannot decide a value-level test.
    is_rtake_long = 0
    scan_long = mb_hit_len > 1
    # `notes/46` — a rebuild allocates on behalf of a RECEIVER, and the
    # receiver may not have been collected yet, so it does not run
    # during a collection at all. The conservative version of the
    # model's `:any` gate; narrowing it to the receiver's own pending
    # bit is an optimisation, not a correctness question.
    deser_free = band(bnot(dz_busy), band(dz_fits, bnot(gc_active)))
    dz_start = take_go

    dz_slot =
      (take_seat == 0) * slot0 + (take_seat == 1) * slot1 +
        (take_seat == 2) * slot2 + (take_seat == 3) * slot3

    dz_idx =
      (take_seat == 0) * ri0 + (take_seat == 1) * ri1 +
        (take_seat == 2) * ri2 + (take_seat == 3) * ri3

    dz_len =
      (take_seat == 0) * rl0 + (take_seat == 1) * rl1 +
        (take_seat == 2) * rl2 + (take_seat == 3) * rl3

    # the heap's command port belongs to the X stage; the rebuild takes
    # whatever cycles are left over. Priority, not arbitration — the
    # rebuilding context is parked and a stall costs it nothing it was
    # not already spending.
    dz_grant = band(dz_h_req, bnot(band(any_heap, x_en)))
    mb_head =
      band(bnot(bor(sd_en, bor(mb_ser, mb_rg))), 1) + band(sd_en, sd_head) +
        band(bnot(sd_en), band(mb_ser, sr_head)) +
        band(bnot(bor(sd_en, mb_ser)), band(mb_rg, rg_head))

    mb_len =
      deliver_now * 1 + band(bnot(deliver_now), sd_en) * (sd_head * sd_len) +
        band(bnot(bor(deliver_now, sd_en)), mb_ser) * (sr_head * sr_len) +
        band(bnot(bor(deliver_now, sd_en)), mb_rg) * (rg_head * rg_len) +
        band(bnot(mb_hi), dz_take) * dz_plen +
        band(bnot(mb_hi), bnot(dz_take)) * x_rlen

    # `recv_waitt` blocks on the same condition `recv_wait` does; what
    # it adds is a deadline. The delay rides f1 (`rs_in_f1` already
    # covers 0x49) and the timeout target is the slot's imm12.
    any_rwaitt = band(bor(c0_rwaitt, bor(c1_rwaitt, c2_rwaitt)), x_en)
    rwaitt_blk = band(any_rwaitt, bnot(mb_unseen))
    rwait_blk = bor(band(any_rwait, bnot(mb_unseen)), rwaitt_blk)

    tm_arm = rwaitt_blk
    tm_delay =
      c0_rwaitt * rw_rd0[31..0] + c1_rwaitt * rw_rd2[31..0] + c2_rwaitt * rw_rd4[31..0]
    tm_pc = c0_rwaitt * imm0[8..0] + c1_rwaitt * imm1[8..0] + c2_rwaitt * imm2[8..0]

    # a message that lands cancels the deadline it beat
    tm_cancel = wake_en
    tm_cancel_slot = wake_slot

    # a timeout, like a delivery, wakes a resident in place or requeues
    # an evicted process — and unlike a delivery it redirects the pc
    tf0 = band(tm_fire, band(slot0 == tm_fire_slot, dbg_st0 == 12))
    tf1 = band(tm_fire, band(slot1 == tm_fire_slot, dbg_st1 == 12))
    tf2 = band(tm_fire, band(slot2 == tm_fire_slot, dbg_st2 == 12))
    tf3 = band(tm_fire, band(slot3 == tm_fire_slot, dbg_st3 == 12))
    tm_resident = bor(tf0, bor(tf1, bor(tf2, tf3)))

    # the wheel may only fire when the engine can act on it
    tm_ready = band(bnot(wk_pend), bnot(boot_en))

    # A delivery wakes a waiting process, and where it is decides how.
    # Resident (ProcTable state 2, context state 12): unblock the seat.
    # Evicted (ProcTable state 3): make it queued and push it — the
    # mailbox is the only thing that may do that, which is why a blocked
    # process was parked rather than queued in the first place.
    #
    # An exit signal converted to a message is a delivery like any
    # other and must wake its target the same way. It arrives as four
    # flits and only the LAST one completes the message, so the wake
    # rides that one — waking on the first would let the receiver's
    # matcher see a head whose continuations have not landed yet.
    # the wake rides the LAST flit, which is 4 for an EXIT and 5 for a
    # DOWN: waking on the first would let the receiver's matcher see a
    # head whose continuations have not landed yet
    #
    # ...and a message off the RING is a delivery too. It was not a wake
    # source at all: a process blocked in `receive` on engine 1 stayed
    # blocked when engine 0 sent to it, forever. `tb_ring2` could not
    # see it, because its receiver SPINS on `recv_peek` and `jmp`
    # instead of blocking — the one program shape that does not need
    # waking. `notes/49`: the first program to block across the ring
    # was the first one to notice.
    #
    # Like the exit emitter's, this wake rides the LAST flit. Waking on
    # the first would let the matcher see a head whose continuations
    # have not landed yet.
    sd_wake = band(sd_en, sd_st == 4 + sd_kind)
    rg_last = band(mb_rg, rg_left == 1)

    # ...and a compound LOCAL send is a delivery whose flits land cycles
    # after its X. The X-time wake (`delivered`) fires before the
    # message exists; a receiver that blocks in the gap missed its only
    # wake and waited forever (`notes/50` — the same lost-wakeup as
    # `notes/26` entry 31, one path over). The real wake rides the
    # stream's COMPLETION, like the exit emitter's rides its last flit.
    # `delivered` stays a wake source: waking a receiver early is a
    # spurious wake it re-parks from; not waking it at the end is a hang.
    ser_wake = band(ser_done, bnot(sr_rem))
    wake_en = bor(delivered, bor(sd_wake, bor(rg_last, ser_wake)))

    wake_slot =
      delivered * su_slot_mb + band(bnot(delivered), sd_wake) * sd_slot +
        band(bnot(bor(delivered, sd_wake)), rg_last) * rg_slot +
        band(bnot(bor(delivered, bor(sd_wake, rg_last))), ser_wake) * sr_slot

    # the three wake sources read the target's state through DIFFERENT
    # ports — a send's target is on rd2 (where `send` already put it),
    # an exit message's is on rd3 (where the emitter put it), a ring
    # arrival's is on rd5 (where the incarnation check put it) — so this
    # cannot be one comparison against one port.
    wake_queued =
      bor(band(delivered, pt_rd2_state == 3),
        bor(band(sd_wake, pt_rd3_state == 3),
          bor(band(rg_last, pt_rd5_state == 3),
            band(ser_wake, pt_rd6_state == 3))))

    wk0 = band(wake_en, band(slot0 == wake_slot, dbg_st0 == 12))
    wk1 = band(wake_en, band(slot1 == wake_slot, dbg_st1 == 12))
    wk2 = band(wake_en, band(slot2 == wake_slot, dbg_st2 == 12))
    wk3 = band(wake_en, band(slot3 == wake_slot, dbg_st3 == 12))
    unblock_en = bor(bor(wk0, bor(wk1, bor(wk2, wk3))), tm_resident)
    unblock_seat =
      band(bnot(tm_resident), 1) * (wk1 * 1 + wk2 * 2 + wk3 * 3) +
        tm_resident * (tf1 * 1 + tf2 * 2 + tf3 * 3)

    unblock_jump = tm_resident
    unblock_pc = tm_fire_pc

    # a doomed process dies wherever it is, including on a seat
    kl0 = band(band(doom_vec >>> slot0, 1), bor(dbg_st0 == 1, dbg_st0 == 12))
    kl1 = band(band(doom_vec >>> slot1, 1), bor(dbg_st1 == 1, dbg_st1 == 12))
    kl2 = band(band(doom_vec >>> slot2, 1), bor(dbg_st2 == 1, dbg_st2 == 12))
    kl3 = band(band(doom_vec >>> slot3, 1), bor(dbg_st3 == 1, dbg_st3 == 12))
    kill_en = bor(kl0, bor(kl1, bor(kl2, kl3)))
    kill_seat = kl1 * 1 + kl2 * 2 + kl3 * 3

    # A call one frame past the store's depth is `:stack_overflow`
    # (reserved atom 8). `FrameRamProc` has raised `overflow` since pass
    # 5 and NOTHING has ever read it — the engine declared `fr_ovf` and
    # left it dangling — so a 16th nested call pushed no frame, recorded
    # no link, and returned to whatever the 15th had left there. Catch
    # it at X off the same depth query `ret_top` uses, one turn before
    # the push would have been refused.
    stk_ovf = band(bor(any_call, cfun_raw), x_depth == 15)

    # ---- `notes/46`: heap exhaustion as a request, per process
    #
    # Crossing the end of the semispace no longer stops the engine. It
    # starts a collection, the allocation base moves to the other
    # semispace, and the asker replays into it — once its own process
    # has been collected, which is the one thing it has to wait for.
    gc_active = gc_st != 0
    # the pause. States 0 and 2 are not it: in state 2 the engine runs
    # at full speed with a collection half done.
    gc_busy = band(gc_active, gc_st != 2)
    engine_frozen = bor(vm_halt, gc_busy)

    # an ALLOCATING heap op at X. `tset`/`tget`/`hd`/`tl` are not: they
    # read and write objects that already exist, and reading from-space
    # is safe for the whole collection.
    gc_alloc_x =
      band(band(any_heap, x_en),
        band(bnot(dz_grant),
          bor(hp_cmd == 0,
            bor(hp_cmd == 3, bor(hp_cmd == 7, bor(hp_cmd == 10, hp_cmd == 12))))))

    gc_hf_x = band(band(hp_f, hp_fr == 6), gc_alloc_x)
    gc_pend_x = band(gc_pend >>> x_slot, 1)

    # Two reasons to park, one rule to leave: your process has not been
    # collected yet.
    #
    #   * out of room and no collection running — start one, and wait
    #     for your turn in it;
    #   * allocating while your own process is still pending — you may
    #     not put a from-space pointer into a fresh to-space object,
    #     because your root scan will see a to-space pointer, leave that
    #     object alone, and never find what is inside it.
    #
    # `heap_full` WITH a collection running means to-space filled, and
    # that is a real fault: the death `Machine.alloc/4` throws in the
    # same situation, which is what keeps the two sides running out of
    # memory on the same allocation.
    # The gated half is separate because `hp_en` has to be able to
    # suppress the store from it, and `gc_hf_x` reads `heap_full`, which
    # the store computes FROM `cmd_en`. Gating the enable on the whole
    # of `gc_park` closes a combinational loop through the heap; gating
    # it on this half does not, and this is the half that needs it — a
    # `heap_full` park is already a no-op inside the store.
    gc_gate_x = band(gc_alloc_x, band(gc_active, gc_pend_x))
    # `gc_st <= 1`, not "no collection running". State 1 waits for the
    # background workers to go quiet, and `frozen` stops FETCHING —
    # bundles already at D and X still retire, and one of them can be an
    # allocation. Until state 1 ENDS the base has not moved, so that
    # allocation is asking for room that is about to exist: it parks.
    # Treating it as a real `heap_full` killed whichever process
    # happened to be mid-allocation when somebody else's collection
    # started.
    gc_park = bor(band(gc_hf_x, bor(gc_st == 0, gc_st == 1)), gc_gate_x)

    hp_f_e = band(hp_f, bnot(gc_park))

    # ...and a parked context resumes when its slot's bit clears. Not
    # when the collection ends — when ITS process is done. `gc_st == 1`
    # holds everybody for the one state in which `gc_pend` has not been
    # written yet and is therefore lying.
    gc_p0 = band(gc_pend >>> slot0, 1)
    gc_p1 = band(gc_pend >>> slot1, 1)
    gc_p2 = band(gc_pend >>> slot2, 1)
    gc_p3 = band(gc_pend >>> slot3, 1)

    gc_ok4 = bnot(gc_p0) * 1 + bnot(gc_p1) * 2 + bnot(gc_p2) * 4 + bnot(gc_p3) * 8

    # ...and nobody resumes while `gc_pend` is lying. It is zero between
    # the park that ASKS for a collection and the state that marks every
    # live process pending, and "nothing is pending" reads as "everyone
    # may go" — so the asker resumed, allocated into a to-space it had
    # not been collected into yet, and the collection then moved its
    # data out from under a pointer it was already holding.
    gc_hold = bor(band(gc_want, gc_st == 0), gc_st == 1)
    gc_res4 = band(gc_pk, band(gc_ok4, bnot(gc_hold) * 15))

    # A rebuild is the other allocator and it cannot park: the context
    # is already parked waiting for it. So the room is checked BEFORE it
    # starts. A message of `n` flits rebuilds into at most `n` cells —
    # every allocation is triggered by consuming at least one flit — so
    # this bound is sound and not merely generous.
    # `notes/46` — `hp_hp` is an ABSOLUTE cell address now, so the
    # room left is measured to the end of the semispace it is in.
    dz_lim = hpb_space * 128 + 128
    dz_fits = bnot((hp_hp + dz_len) > dz_lim)
    # ...and it does not run at all during a collection. It allocates on
    # behalf of a RECEIVER, and the receiver may not have been collected
    # yet. Blocking the rebuild is the conservative version of the
    # model's `:any` gate; narrowing it to the receiver's own pending
    # bit is a later optimisation, not a correctness question.
    gc_req_dz = band(take_want, band(bnot(dz_busy), bnot(dz_fits)))

    # the machine is quiet enough to hand the heap over: nothing
    # serialising, nothing rebuilding, no mailbox scan, no signal being
    # emitted, no window drain in flight
    gc_quiet =
      band(bnot(ser_busy),
        band(bnot(dz_busy), band(bnot(mb_busy), band(sd_st == 0, drain_ready))))

    # is there anything left to collect, and is the cursor on it? No
    # priority encoder: `gc_slot` is a rotating cursor advanced one slot
    # per cycle in state 2, which is the state where the engine is
    # RUNNING. A scan that costs nothing does not need to be wide.
    gc_any = gc_pend != 0
    gc_urg = gc_pk != 0
    gc_pick = band(gc_pend >>> gc_slot, 1)

    # ---- port 0 of the register file, borrowed while the world is
    # stopped. The barrel is frozen, so the D-stage read and the X-stage
    # write it normally carries are both idle.
    # `gc_busy`, not `gc_active`. A collection used to be a state in
    # which the engine was frozen for all of it, so "a collection is
    # running" and "the pipeline is not using this port" were the same
    # question. They are not any more: state 2 IS a collection, and it
    # is also the engine executing at full speed. Handing the walker
    # port 0 there gave every D-stage read the wrong register and sent
    # every X-stage write to the wrong one (`notes/46`).
    # `rk_busy`, not `gc_busy` and certainly not `gc_active`. Freezing
    # the engine stops FETCHING; the bundles already at D and X take
    # another eight cycles to retire, and states 1 and 3 exist to wait
    # for exactly that. Handing the walker port 0 on the FIRST cycle of
    # the freeze gave those in-flight bundles the walker's word instead
    # of their own register — a `tset` read 42 as its tuple pointer and
    # died of `bad_tag`, an `add` read a pointer and died of `badarith`.
    #
    # The walker is only busy in state 4, by which time the drain that
    # states 1 and 3 waited for has happened. That is the correct
    # handover point and it was always available (`notes/46`).
    gw_rd_ctx = rk_busy * rk_ctx + band(bnot(rk_busy), 1) * d_seat
    gw_rd_a0 = rk_busy * rk_addr + band(bnot(rk_busy), 1) * ra_a0
    gw_stg0 = band(rk_busy, rk_stg)
    gw_w_ctx = rk_busy * rk_ctx + band(bnot(rk_busy), 1) * w_ctx
    gw_w_en0 = rk_busy * rk_we + band(bnot(rk_busy), 1) * w0_en
    gw_w_stg0 = rk_busy * rk_stg + band(bnot(rk_busy), 1) * w0_stg
    gw_w_a0 = rk_busy * rk_addr + band(bnot(rk_busy), 1) * w0_addr
    gw_w_d0 = rk_busy * rk_data + band(bnot(rk_busy), 1) * w0_data
    gw_q_slot = rk_busy * rk_fr_qslot + band(bnot(rk_busy), 1) * x_slot

    any_fault =
      bor(try_ovf,
        bor(stk_ovf,
          bor(sup_bad,
            bor(nm_bad,
              bor(nm_lim,
                bor(any_fail,
                  bor(bad_pid, bor(hp_f_e, bor(alu0_f, bor(alu1_f, alu2_f))))))))))

    # :badarg is reserved atom 10 — a send to a non-pid is a program
    # error on the SENDER, not a delivery failure
    fault_r0 =
      bor(bad_pid, bor(sup_bad, nm_bad)) * 10 + nm_lim * 9 +
        band(bnot(bor(bad_pid, sup_bad)), hp_f_e) * hp_fr +
        band(bnot(bor(bad_pid, hp_f_e)), alu0_f) * alu0_fr +
        band(bnot(bor(bad_pid, hp_f_e)), band(bnot(alu0_f), alu1_f)) * alu1_fr +
        band(bnot(bor(bad_pid, hp_f_e)),
          band(bnot(alu0_f), band(bnot(alu1_f), alu2_f))) * alu2_fr +
        band(any_fail,
          bnot(bor(bad_pid, bor(hp_f_e, bor(alu0_f, bor(alu1_f, alu2_f)))))) * fail_reason

    # :system_limit is 9, :stack_overflow is 8
    any_fault_r =
      ba_rsn * A_BADARITY +
        band(bnot(ba_rsn), 1) *
          (try_ovf * 9 + band(bnot(try_ovf), stk_ovf) * 8 +
             band(bnot(bor(try_ovf, stk_ovf)), 1) * fault_r0)

    # ---- try/catch bookkeeping (notes/32)
    cc_n = band(ccnt >>> (x_slot * 3), 7)
    has_catch = cc_n != 0
    cc_top = ctch[x_slot * 4 + band(has_catch, 1) * (cc_n - 1)]
    c_depth = cc_top[16..13]
    c_pc = cc_top[12..4]
    c_rd = cc_top[3..0]

    # four nested `try`s per process. A fifth is `:system_limit`
    # (reserved atom 9) rather than a silent overwrite, which is the
    # same answer the proc table gives a spawn it cannot seat.
    try_ovf = band(any_try, cc_n == 4)

    catch_go = band(any_fault, band(has_catch, bnot(try_ovf)))
    catch_deep = x_depth != c_depth
    catch_pc = c_pc

    # `try_begin` pre-loads the CLASS register. It is always `error`
    # (reserved atom 17) — `throw` and `exit` carry their own and the
    # front end does not emit them — and `Erl` allocates rd and rd+1 for
    # the `try` alone, so nothing can observe it early. That leaves one
    # register for the landing to write instead of two, and one register
    # is a write port the landing already has.
    sys_try = band(any_try, bnot(try_ovf))

    # the counter file: one write site, an alloc clear that cannot
    # collide with it (a slot being claimed is not a slot executing)
    cc_dec = band(x_en, bor(catch_go, band(any_tend, bnot(any_fault))))
    cc_inc = band(x_en, band(any_try, bnot(bor(any_fault, try_ovf))))
    cc_we = bor(cc_inc, cc_dec)
    cc_val = cc_n + cc_inc - cc_dec
    cc_clr = (pt_cmd == 1) * (7 <<< (pt_slot * 3))
    cc_mask = cc_we * (7 <<< (x_slot * 3))

    # the unwind, per seat: which register the handler's reason goes in,
    # what that reason is, and how far down the frames to come back
    pop_abs =
      (commit_seat == 0) * uwd0 + (commit_seat == 1) * uwd1 + (commit_seat == 2) * uwd2 +
        (commit_seat == 3) * uwd3

    pop_to =
      (commit_seat == 0) * cd_0 + (commit_seat == 1) * cd_1 + (commit_seat == 2) * cd_2 +
        (commit_seat == 3) * cd_3

    dest_mode =
      (fill_seat == 0) * uwd0 + (fill_seat == 1) * uwd1 + (fill_seat == 2) * uwd2 +
        (fill_seat == 3) * uwd3

    uw_rd =
      (fill_seat == 0) * cr0 + (fill_seat == 1) * cr1 + (fill_seat == 2) * cr2 +
        (fill_seat == 3) * cr3

    uw_rsn =
      (fill_seat == 0) * cn0 + (fill_seat == 1) * cn1 + (fill_seat == 2) * cn2 +
        (fill_seat == 3) * cn3

    cwb_rd =
      (cwb_seat == 0) * cr0 + (cwb_seat == 1) * cr1 + (cwb_seat == 2) * cr2 +
        (cwb_seat == 3) * cr3

    cwb_rsn =
      (cwb_seat == 0) * cn0 + (cwb_seat == 1) * cn1 + (cwb_seat == 2) * cn2 +
        (cwb_seat == 3) * cn3

    # the deep landing rides the ret fill's dest turn: same port, same
    # cycle, a different address and a different word
    fill_rv_e =
      band(dest_mode, 1) * (0x100000000 + uw_rsn) + band(bnot(dest_mode), 1) * fill_rv

    # Exact, not approximate: one context is at X per cycle, and `out`
    # and `halt` are both system ops, so contract rule 3 forbids them
    # sharing a bundle. Nothing can emit in the cycle the halt retires,
    # and from the next one the latch is up.
    sched_budget = 24
    out_valid = band(any_out, band(x_en, bnot(vm_halt)))
    out_data = c0_out * rw_rd0 + c1_out * rw_rd2 + c2_out * rw_rd4
    ret_word = c0_ret * rw_rd0 + c1_ret * rw_rd2 + c2_ret * rw_rd4
    # `callfun` is a call, so its destination register is recorded the
    # same way — the per-seat `cd*` latch the frame push reads. Missing
    # this is the difference between a closure that returns its answer
    # and one that returns it into r0 (`notes/42`).
    call_dest_x =
      c0_call * rd0 + c1_call * rd1 + c2_call * rd2 +
        c0_cfun * rd0 + c1_cfun * rd1 + c2_cfun * rd2
    spawn_rd_x = c0_spawn * rd0 + c1_spawn * rd1 + c2_spawn * rd2

    # ---- heap: at most one op per bundle (contract rule 2), so these
    # one-hot sums are muxes and there is nothing to arbitrate
    any_heap = bor(c0_heap, bor(c1_heap, c2_heap))
    # four bits, not three: group 2 has sixteen code points and `fget`
    # (0x28) is the ninth that reaches the store (`notes/42`)
    hp_cmd =
      band(bnot(dz_grant), 1) *
        (any_cfun * 8 +
           band(bnot(any_cfun), 1) *
             (c0_heap * op0[3..0] + c1_heap * op1[3..0] + c2_heap * op2[3..0])) +
        dz_grant * dz_h_cmd
    # `mkfun`'s `pa` is not a register: it is the closure literal, and it
    # arrives from the pool's second read port, addressed at D above.
    hp_pa =
      band(bnot(dz_grant), 1) *
        (any_cfun * cf_pa +
           band(bnot(any_cfun), 1) *
             (mk_x * lp2_q +
                band(bnot(mk_x), 1) *
                  (c0_heap * rw_rd0 + c1_heap * rw_rd2 + c2_heap * rw_rd4))) +
        dz_grant * dz_h_pa
    hp_pb =
      band(bnot(dz_grant), 1) * (c0_heap * rw_rd1 + c1_heap * rw_rd3 + c2_heap * rw_rd5) +
        dz_grant * dz_h_pb
    # `tset` rides the four-field shape, so its index is f4 alone —
    # the i8 field would carry `rs` in its high nibble. Every other
    # heap op uses the full eight bits. The heap used to mask this
    # itself, which quietly made a 16-element tuple impossible to
    # build; masking here keeps the store general and puts the slot
    # encoding where slot encodings belong.
    hp_i8_raw = c0_heap * i80 + c1_heap * i81 + c2_heap * i82
    # ...and its `i8` is `nfree`, which rides f2 because f3/f4 are spent
    # on the pool index. Twenty-four bits, exactly full.
    hp_i8 =
      band(bnot(dz_grant), band(bnot(any_cfun), 1)) *
        (mk_x * mk_nfree +
           mat_x * mat_i[7..0] +
           mset_x * mi_n +
           mkm_x * mkm_i[7..0] +
           band(bnot(bor(mk_x, bor(mat_x, bor(mset_x, mkm_x)))), 1) *
             ((hp_cmd == 4) * hp_i8_raw[3..0] + bnot(hp_cmd == 4) * hp_i8_raw)) +
        dz_grant * dz_h_i8
    hp_rd =
      c0_heap * rd0 + c1_heap * rd1 + c2_heap * rd2 +
        c0_ldc * rd0 + c1_ldc * rd1 + c2_ldc * rd2
    # ...and a bundle that is PARKING did not happen. `heap_full` already
    # suppresses the bump and the writes inside the store, which is what
    # made the old park a clean no-op; the gated park of `notes/46` has
    # no fault behind it, so the store has to be told directly. Without
    # this the allocation went through, the destination register did not
    # (the context left at X), and the `tset`s that filled the object
    # ran against a stale register — `bad_tag`, three bundles later.
    hp_en =
      band(bnot(gc_gate_x), bor(band(any_heap, x_en), bor(any_cfun, dz_grant)))
    # tset (4) writes the heap and returns nothing; its rd field is 0,
    # so a wb2 turn would clobber r0 with a word that means nothing
    # `tset` (4) and `mset` (11) write the HEAP and return nothing: their
    # rd field is zero, so a wb2 turn would clobber r0 with a word that
    # means nothing. `mset` learned that the hard way — it wrote
    # `rd_late` over the very map pointer it had just been handed, and
    # the next `mapat` said `badmap` about it.
    hp_writes = band(any_heap, band(hp_cmd != 4, hp_cmd != 11))

    # `ldc` takes the same late turn as a heap op — the pool is a sync
    # read and its answer lands a cycle later, exactly like `rd_late`.
    # Rule 5 of the bundle contract says at most one of the two per
    # bundle (the sequencer allocates ONE wb2 turn), so they share the
    # per-seat latch and a single bit remembers which unit to read.
    any_ldc = bor(c0_ldc, bor(c1_ldc, c2_ldc))
    lp_addr = c0_ldc * imm0[7..0] + c1_ldc * imm1[7..0] + c2_ldc * imm2[7..0]

    # `mkfun rd, k, nfree` (`notes/42`) — `k` is a pool index in f3/f4 and
    # `nfree` is in f2, so the funinfo the object carries is a literal
    # like any other. It is read HERE, off the D-stage bundle, because
    # the heap command that writes it into the object issues at X and a
    # sync read addressed at X answers a cycle too late.
    lp2_addr =
      (d_op0 == 0x27) * d_i80 + (d_op1 == 0x27) * d_i81 + (d_op2 == 0x27) * d_i82

    mk_op = c0_heap * op0 + c1_heap * op1 + c2_heap * op2
    mk_x = band(bnot(dz_grant), band(any_heap, mk_op == 0x27))
    mk_nfree = c0_heap * ra0 + c1_heap * ra1 + c2_heap * ra2

    # `mapat rd, rm, ri` (`notes/42`) is the one heap read whose INDEX is
    # a register rather than an immediate, because the probe loop that
    # walks a map computes it. It rides the rb port — the same one `pb`
    # uses — so it costs a mux on `i8` and no new read.
    mat_x = band(any_heap, bor(mk_op == 0x29, mk_op == 0x2D))
    mat_i = c0_heap * rw_rd1 + c1_heap * rw_rd3 + c2_heap * rw_rd5

    mi_n = band(midx >>> (x_slot * 8), 255)
    mi_set = band(bor(c0_mseti, bor(c1_mseti, c2_mseti)), x_en)
    mi_val = (c0_mseti * rw_rd0 + c1_mseti * rw_rd2 + c2_mseti * rw_rd4)[7..0]
    mset_x = band(any_heap, mk_op == 0x2B)
    # `mkmap rd, rn` takes its PAIR COUNT from a register too: a map
    # literal knows its size at assembly time but `map_put` does not, and
    # one op that always reads a register is a smaller ISA than two.
    mkm_x = band(any_heap, bor(mk_op == 0x2A, mk_op == 0x2C))
    mkm_i = c0_heap * rw_rd0 + c1_heap * rw_rd2 + c2_heap * rw_rd4

    # `callfun rd, rf, arity` (`notes/42`). At X it reads word 0 of the
    # closure — the funinfo — through `fget`, and parks like a call. At
    # X+1 the answer is in `rd_late` and the seat's target latch takes
    # the entry out of it. That is one cycle, three cycles before the
    # earliest F slot the commit could use, so nothing waits on it.
    #
    # `badfun` needs no help: the store raises it at X, for the seat at
    # X, on the ordinary fault path. `badarity` is the awkward one — it
    # cannot be known until the funinfo is back, by which time the seat
    # has moved on.
    cfun_raw = bor(c0_cfun, bor(c1_cfun, c2_cfun))
    any_cfun = band(cfun_raw, x_en)
    cf_pa = c0_cfun * rw_rd0 + c1_cfun * rw_rd2 + c2_cfun * rw_rd4
    cf_ar = c0_cfun * rb0 + c1_cfun * rb1 + c2_cfun * rb2

    ftgt_en = cf_d
    ftgt_seat = cf_seat_d
    ftgt_pc = hp_rd_late[16..8]

    # funinfo is {entry:9, arity:4, nfree:4} in a fixnum payload
    ba_bad = band(cf_d, hp_rd_late[7..4] != cf_ar_d)
    # an X-stage fault owns the death port this cycle; the arity error
    # waits a turn rather than being dropped
    ba_go = band(ba_pend, bnot(any_fault))

    has_wb2_w = band(bor(hp_writes, any_ldc), x_en)
    late_word = hp_src_d * lp_q + bnot(hp_src_d) * hp_rd_late

    # `fail` is an exit the program asked for: the reason is a reserved
    # atom index in imm12, and it joins the same die path a badarith
    # takes. Lowest priority in the chain — a bundle that faults for a
    # hardware reason has a better reason than the one it declared.
    any_fail = band(bor(c0_fail, bor(c1_fail, c2_fail)), x_en)

    # ---- supervision ops at X. All are system ops, so at most one per
    # bundle by rule 3 and these one-hot sums are muxes.
    any_link = band(bor(c0_link, bor(c1_link, c2_link)), x_en)
    any_unlink = band(bor(c0_unlink, bor(c1_unlink, c2_unlink)), x_en)
    any_exit2 = band(bor(c0_exit2, bor(c1_exit2, c2_exit2)), x_en)
    any_trap = band(bor(c0_trap, bor(c1_trap, c2_trap)), x_en)
    any_mon = band(bor(c0_mon, bor(c1_mon, c2_mon)), x_en)
    any_sup = bor(any_link, bor(any_unlink, bor(any_exit2, any_mon)))

    # `monitor` writes a ref, so unlike its neighbours its rd really is
    # in f1 — and the ref it writes is this engine's counter, which is
    # the only piece of process identity that is not derived from a
    # slot. The word is REF-tagged (6) so a stale one cannot be
    # mistaken for a pid or a fixnum.
    mon_rd = c0_mon * rd0 + c1_mon * rd1 + c2_mon * rd2
    ref_word = 0x600000000 + next_ref
    ref_wr = band(any_mon, bnot(sup_bad))

    # the pid operand rides ra (f2), the way `send`'s does
    sup_pid =
      bor(c0_link, bor(c0_unlink, bor(c0_exit2, c0_mon))) * rw_rd0 +
        bor(c1_link, bor(c1_unlink, bor(c1_exit2, c1_mon))) * rw_rd2 +
        bor(c2_link, bor(c2_unlink, bor(c2_exit2, c2_mon))) * rw_rd4

    # exit2's reason rides rb (f3)
    ex_reason =
      c0_exit2 * rw_rd1[7..0] + c1_exit2 * rw_rd3[7..0] + c2_exit2 * rw_rd5[7..0]

    sup_slot = sup_pid[27..22]
    sup_serial = sup_pid[21..0]

    # `link`/`exit2` to something that is not a pid is a program error
    # on the CALLER — the same :badarg `send` raises — and to a pid
    # whose incarnation has moved on is the dead-letter rule, not an
    # error. `unlink` of a stale pid is simply a no-op: there is
    # nothing to remove and nobody to tell.
    sup_bad = band(bor(any_link, bor(any_exit2, any_mon)), sup_pid[35..32] != 5)

    # the pid is a real pid and it lives on another engine: the op
    # becomes a ring packet and the context parks (notes/53 Phase 4).
    # With one engine the comparison is constant-false and all of it
    # folds away, like `sp_remote_x`.
    sup_remote =
      band(N_ENG > 1,
        band(any_sup, band(sup_pid[35..32] == 5, sup_pid[31..28] != eng_id)))

    # ---- registered names at X (`notes/50`). All three are system ops,
    # so at most one per bundle and these sums are muxes.
    any_regn = band(bor(c0_regn, bor(c1_regn, c2_regn)), x_en)
    any_wher = band(bor(c0_wher, bor(c1_wher, c2_wher)), x_en)
    any_unreg = band(bor(c0_unreg, bor(c1_unreg, c2_unreg)), x_en)

    # the name rides ra (f2) for all three; reg_name's pid rides rb (f3)
    nm_name_w =
      bor(c0_regn, bor(c0_wher, c0_unreg)) * rw_rd0 +
        bor(c1_regn, bor(c1_wher, c1_unreg)) * rw_rd2 +
        bor(c2_regn, bor(c2_wher, c2_unreg)) * rw_rd4

    nm_pid_w = c0_regn * rw_rd1 + c1_regn * rw_rd3 + c2_regn * rw_rd5

    # aliveness: a LOCAL pid reads rd2 — free this cycle, because a
    # register op at X means no send and no supervision op is at X. A
    # pid on the peer reads the peer's table through the node's probe
    # route; the serial compare happens here either way (`notes/53`).
    nm_loc = nm_pid_w[31..28] == eng_id
    nm_probe_slot = nm_pid_w[26..22]
    nm_alive = band(pt_rd2_state != 0, pt_rd2_serial == nm_pid_w[21..0])
    nm_alive_rem = band(nm_probe_state != 0, nm_probe_serial == nm_pid_w[21..0])

    # BEAM's rules: the name is an atom and not `undefined`, the pid is
    # a LIVE pid — on ANY engine, because an engine is a scheduler and
    # the registry belongs to the node — the name is unbound and the
    # process is unnamed
    regn_ok =
      band(nm_name_w[35..32] == 1,
        band(nm_name_w[15..0] != A_UNDEF,
          band(nm_pid_w[35..32] == 5,
            band(nm_loc * nm_alive + band(bnot(nm_loc), 1) * nm_alive_rem,
              band(bnot(nm_name_taken), bnot(nm_pid_taken))))))

    # the ninth name is :system_limit, by agreement with the model
    nm_lim = band(any_regn, band(regn_ok, nm_full))

    nm_bad =
      bor(band(any_regn, bnot(regn_ok)),
        bor(band(any_unreg, bnot(band(nm_name_w[35..32] == 1, nm_name_taken))),
          band(any_wher, nm_name_w[35..32] != 1)))

    nm_w_en = band(any_regn, band(regn_ok, bnot(nm_full)))
    nm_w_eng = nm_pid_w[31..28]
    nm_clr_en = band(any_unreg, bnot(nm_bad))

    # `Name ! Msg` — an atom destination resolves through the table
    # before `SendUnit` sees it: a hit substitutes the pid (alive by
    # construction — the table clears on death), a miss leaves the atom
    # to fall into SendUnit's bad-destination path, which is `Name !
    # Msg` to an unregistered name being badarg on the sender, for free.
    snd_atom = band(any_send, snd_pid[35..32] == 1)
    nm_q_name = snd_atom * snd_pid[15..0] + band(bnot(snd_atom), 1) * nm_name_w[15..0]

    # the resolved pid carries the CAM entry's ENGINE — a name may be
    # registered to a process anywhere in the node, and a hit on a
    # foreign engine simply makes this a remote send (the existing
    # ring path picks it up untouched)
    snd_pid_res =
      band(snd_atom, nm_q_hit) *
        (21_474_836_480 + nm_q_eng * 268_435_456 + nm_q_slot * 4_194_304 + nm_q_serial) +
        band(bnot(band(snd_atom, nm_q_hit)), 1) * snd_pid

    # whereis writes through the system port, the way `monitor` does
    sys_whe = band(any_wher, bnot(nm_bad))
    nm_w_slot = nm_pid_w[26..22]
    nm_w_serial = nm_pid_w[21..0]

    # answering the peer's aliveness probes from this table's mirror
    peer_probe_state = pt_rd7_state
    peer_probe_serial = pt_rd7_serial

    nm_die = died
    nm_die_pid = su_died_pid

    whe_word =
      nm_q_hit *
        (21_474_836_480 + nm_q_eng * 268_435_456 + nm_q_slot * 4_194_304 + nm_q_serial) +
        band(bnot(nm_q_hit), 1) * (4_294_967_296 + A_UNDEF)
    sup_alive =
      band(pt_rd2_state != 0, pt_rd2_serial == sup_serial)
    fail_reason = c0_fail * imm0[7..0] + c1_fail * imm1[7..0] + c2_fail * imm2[7..0]

    wb2_addr = (x_seat == 0) * hd0 + (x_seat == 1) * hd1 + (x_seat == 2) * hd2 + (x_seat == 3) * hd3
    wb2_data = (x_seat == 0) * hl0 + (x_seat == 1) * hl1 + (x_seat == 2) * hl2 + (x_seat == 3) * hl3

    # ---- write ports
    wb0 = band(c0_wr, x_en)
    wb1 = band(c1_wr, x_en)
    wb2w = band(c2_wr, x_en)
    ag0 = band(c0_arg, x_en)
    ag1 = band(c1_arg, x_en)
    ag2 = band(c2_arg, x_en)
    self0 = band(c0_self, x_en)
    sys_self = band(any_self, x_en)
    sys_rtk = band(any_rtake, x_en)
    sys_mon = band(any_mon, bnot(sup_bad))
    sys_any = bor(sys_try, bor(sys_self, bor(sys_rtk, bor(sys_mon, sys_whe))))

    sys_rd =
      (c0_self + c0_rtake + c0_mon + c0_try + c0_wher) * rd0 +
        (c1_self + c1_rtake + c1_mon + c1_try + c1_wher) * rd1 +
        (c2_self + c2_rtake + c2_mon + c2_try + c2_wher) * rd2
    rtk0 = band(c0_rtake, x_en)
    rpk0 = band(c0_rpeek, x_en)

    w1_en = bor(wb1, ag1)
    w1_data = wb1 * alu1_y + ag1 * rw_rd2
    w2_en = bor(wb2w, ag2)
    w2_data = wb2w * alu2_y + ag2 * rw_rd4

    # the returning context's latched ret value, selected by fill owner
    fill_rv =
      (fill_seat == 0) * rv0 + (fill_seat == 1) * rv1 + (fill_seat == 2) * rv2 +
        (fill_seat == 3) * rv3

    # port 0: parked-context writes first (their X slots are free by
    # construction), then the running context's own
    # `cwb_en` is the shallow catch landing. It heads the chain because
    # its turn belongs to a context with no bundle in flight, so nothing
    # else on this port can be claiming it.
    dzw_wb = band(dzw_pend, x_seat == dzw_seat)

    w0_en =
      bor(cwb_en,
        bor(fw_en,
          bor(sw_en,
            bor(pid_wr,
              bor(dest_wr,
                bor(dzw_wb,
                  bor(pkw_wb, bor(wb2_en_w, bor(wb0, bor(ag0, sys_any))))))))))
    w0_stg = band(ag0, bnot(bor(cwb_en, bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr))))))

    # ---- staging boxedness, and the placement it decides (`notes/49`)
    #
    # The three staging write ports each carry a term; a term with one
    # of the five boxed tags is a POINTER into this engine's heap and
    # cannot leave it. Port 0's staging write is the one that actually
    # lands (`w0_stg` already loses to every higher-priority writer on
    # that port), so the bitmap is keyed on the write, not on the op.
    bx_w0 = w0_stg
    bx_w1 = ag1
    bx_w2 = ag2

    bx_d0 =
      bor(rw_rd0[35..32] == TB_CONS,
        bor(rw_rd0[35..32] == TB_TUPLE,
          bor(rw_rd0[35..32] == TB_FUN,
            bor(rw_rd0[35..32] == TB_MAP, rw_rd0[35..32] == TB_BIN))))

    bx_d1 =
      bor(rw_rd2[35..32] == TB_CONS,
        bor(rw_rd2[35..32] == TB_TUPLE,
          bor(rw_rd2[35..32] == TB_FUN,
            bor(rw_rd2[35..32] == TB_MAP, rw_rd2[35..32] == TB_BIN))))

    bx_d2 =
      bor(rw_rd4[35..32] == TB_CONS,
        bor(rw_rd4[35..32] == TB_TUPLE,
          bor(rw_rd4[35..32] == TB_FUN,
            bor(rw_rd4[35..32] == TB_MAP, rw_rd4[35..32] == TB_BIN))))

    # set-and-clear, because a staged register can go from a list to an
    # integer and a stale set bit would strand the spawn at home forever
    bx_set =
      band(bx_w0, bx_d0) * (1 <<< rd0) + band(bx_w1, bx_d1) * (1 <<< rd1) +
        band(bx_w2, bx_d2) * (1 <<< rd2)

    bx_clr = bx_w0 * (1 <<< rd0) + bx_w1 * (1 <<< rd1) + bx_w2 * (1 <<< rd2)

    bx_cur =
      (x_seat == 0) * bx0 + (x_seat == 1) * bx1 + (x_seat == 2) * bx2 + (x_seat == 3) * bx3

    # the arity rides `spawn`'s immediate above the nine-bit target
    sp_arity_x = c0_spawn * imm0[11..9] + c1_spawn * imm1[11..9] + c2_spawn * imm2[11..9]
    sp_mask = bnot(65535 <<< sp_arity_x)
    sp_boxed_x = band(bx_cur, sp_mask) != 0

    # `band(eng_id + sp_rr, N_ENG - 1)` is `rem(eid + rr, n)` for a
    # power-of-two engine count and nothing else. Every fabric this
    # design fits is 1, 2 or 4 engines; the model says `rem` and
    # `notes/49` records that the two agree exactly there.
    sp_tgt = band(eng_id + sp_rr, N_ENG - 1)

    # With one engine the comparison is constant-false and the whole
    # remote path folds away — every existing testbench is untouched.
    sp_remote_x =
      band(N_ENG > 1,
        band(band(any_spawn, x_en), band(sp_tgt != eng_id, bnot(sp_boxed_x))))

    f_rem = (f_seat == 0) * spr0 + (f_seat == 1) * spr1 + (f_seat == 2) * spr2 +
      (f_seat == 3) * spr3

    f_tgt_eng = (f_seat == 0) * spt0 + (f_seat == 1) * spt1 + (f_seat == 2) * spt2 +
      (f_seat == 3) * spt3

    f_arity = (f_seat == 0) * spa0 + (f_seat == 1) * spa1 + (f_seat == 2) * spa2 +
      (f_seat == 3) * spa3

    w_ctx = cwb_en * cwb_seat + band(bnot(cwb_en), 1) * w_ctx_b
    w0_addr = cwb_en * (cwb_rd + 1) + band(bnot(cwb_en), 1) * w0_addr_b
    w0_data = cwb_en * (0x100000000 + cwb_rsn) + band(bnot(cwb_en), 1) * w0_data_b

    w_ctx_b =
      fw_en * fw_seat + band(bnot(fw_en), sw_en) * sw_seat +
        band(bnot(bor(fw_en, sw_en)), pid_wr) * pid_seat +
        band(bnot(bor(fw_en, bor(sw_en, pid_wr))), dest_wr) * fill_seat +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), dzw_wb) * dzw_seat +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))),
          band(bnot(dzw_wb), pkw_wb)) * pkw_seat +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))),
          band(bnot(dzw_wb), bnot(pkw_wb))) * x_seat

    w0_addr_b =
      fw_en * fw_idx + band(bnot(fw_en), sw_en) * sw_idx +
        band(bnot(bor(fw_en, sw_en)), pid_wr) * pid_reg +
        band(bnot(bor(fw_en, bor(sw_en, pid_wr))), dest_wr) *
          (dest_mode * (uw_rd + 1) + band(bnot(dest_mode), 1) * fr_ret_dest) +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))),
          bor(dzw_wb, bor(pkw_wb, bor(wb2_en_w, bor(wb0, bor(ag0, sys_any)))))) *
          (dzw_wb * dzw_rd + band(bnot(dzw_wb), pkw_wb) * pkw_rd +
             band(bnot(dzw_wb), band(bnot(pkw_wb), wb2_en_w)) * wb2_addr +
             band(bnot(dzw_wb), band(bnot(pkw_wb), band(bnot(wb2_en_w), sys_any))) * sys_rd +
             band(bnot(dzw_wb), band(bnot(pkw_wb), band(bnot(wb2_en_w), bnot(sys_any)))) * rd0)

    w0_data_b =
      fw_en * fr_fill_d + band(bnot(fw_en), sw_en) * sfill_data +
        band(bnot(bor(fw_en, sw_en)), pid_wr) * pid_data +
        band(bnot(bor(fw_en, bor(sw_en, pid_wr))), dest_wr) * fill_rv_e +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), wb0) * alu0_y +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), ag0) * rw_rd0 +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), sys_try) * 0x100000011 +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), sys_self) * self_pid +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), sys_mon) * ref_word +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), sys_whe) * whe_word +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), sys_rtk) * rtake_word +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), wb2_en_w) * wb2_data +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), dzw_wb) * dzw_result +
        band(bnot(bor(fw_en, bor(sw_en, bor(pid_wr, dest_wr)))), pkw_wb) * pkw_word

    # ---- seat file → frame addressing
    f_cd = (f_seat == 0) * cd0 + (f_seat == 1) * cd1 + (f_seat == 2) * cd2 + (f_seat == 3) * cd3
    f_sr = (f_seat == 0) * sr0 + (f_seat == 1) * sr1 + (f_seat == 2) * sr2 + (f_seat == 3) * sr3

    push_slot =
      (commit_seat == 0) * slot0 + (commit_seat == 1) * slot1 + (commit_seat == 2) * slot2 +
        (commit_seat == 3) * slot3

    pop_slot =
      (f_seat == 0) * slot0 + (f_seat == 1) * slot1 + (f_seat == 2) * slot2 +
        (f_seat == 3) * slot3

    fill_slot =
      (fill_seat == 0) * slot0 + (fill_seat == 1) * slot1 + (fill_seat == 2) * slot2 +
        (fill_seat == 3) * slot3

    # ---- boot owns the tables until the first process exists
    # deferred ProcTable commands wait for a free port rather than
    # displacing a seat-unit command: a doom, then a wake
    pt_free = band(bnot(boot_en), su_cmd == 0)
    pt_doom_go = band(dm_pend, pt_free)
    pt_wake_go = band(wk_pend, band(pt_free, bnot(pt_doom_go)))
    wk_cmd = wk_jump * 3 + bnot(wk_jump) * 8
    # `process_flag(trap_exit, _)` is a one-bit write that shares the
    # command port with everything else, so it queues like a doom does
    pt_trap_go = band(tp_pend, band(pt_free, bnot(bor(pt_doom_go, pt_wake_go))))
    trap_flag = c0_trap * imm0[0] + c1_trap * imm1[0] + c2_trap * imm2[0]

    pt_cmd =
      boot_en * 1 + band(bnot(boot_en), su_cmd != 0) * su_cmd + pt_doom_go * 6 +
        pt_trap_go * 9 +
        pt_wake_go * wk_cmd

    pt_slot =
      band(bnot(boot_en), su_cmd != 0) * su_slot + pt_doom_go * dm_slot +
        pt_trap_go * tp_slot +
        pt_wake_go * wk_slot

    pt_pc =
      boot_en * boot_pc + band(bnot(boot_en), su_cmd != 0) * su_pc +
        pt_doom_go * dm_reason + pt_trap_go * tp_flag +
        band(pt_wake_go, wk_jump) * wk_pc
    # the woken process joins the run queue when the seat unit is not
    # pushing; its ProcTable state moves in the same deferred pass
    rq_wake_go = band(wk_pend, band(bnot(boot_en), bnot(su_rq_push)))
    rq_push = bor(boot_en, bor(su_rq_push, rq_wake_go))

    rq_data =
      boot_en * alloc_slot + band(bnot(boot_en), su_rq_push) * su_rq_data +
        band(bnot(boot_en), band(bnot(su_rq_push), rq_wake_go)) * wk_slot
    rq_pop = band(bnot(boot_en), su_rq_pop)

    # a halted machine is idle. It is the only kind of idle that can
    # have live processes in it, which is the point: they are still
    # there to be looked at.
    idle = bor(band(occ == 0, rq_empty), vm_halt)
    halt_req = vm_halt
    faulted = flt
    fault_reason = flt_r
    fault_slot = flt_s
    fault_count = flt_n

    dbg_occ = occ
    dbg_qcount = rq_count
    dbg_spawns = spawns
    dbg_deaths = deaths
    dbg_sends = sends
    dbg_recvs = recvs
    dbg_scan = mb_scan_len
    dbg_evicts = evicts
    dbg_x_seat = x_seat
    dbg_x_en = x_en
    dbg_pc = x_pc
  end

  on :clk do
    if rst == 1 do
      # The reset audit (`notes/26` entry 36, `notes/53` phase 1). An
      # `init:` value is BITSTREAM-time state — it survives the soft
      # reset an image push asserts — so everything SEMANTIC belongs
      # here: counters a program can observe (`sp_rr` bit first),
      # every FSM state, every valid/pending flag. Pure data latches
      # (cd/hl/rv/sg payloads, tx/rx buffers, per-seat result words)
      # stay init-only on purpose: each is written before its consumer
      # reads it, and the FSM that sequences that write IS reset here.
      sp_rr = 0
      # the model's counter starts at 1 (`Machine.new`), and the FIRST
      # ref minted after an image push must agree with it
      next_ref = 1
      rg_st = 0
      rg_ok = 0
      rg_head = 0
      rg_left = 0
      rg_len = 0
      rt_st = 0
      rt_i = 0
      rt_kind = 0
      rt_n = 0
      ro_busy = 0
      ro_have = 0
      ro_pdone = 0
      rx_pend = 0
      rx_rep = 0
      sr_rem = 0
      sr_head = 0
      sr_hdr = 0
      sd_st = 0
      dzw_pend = 0
      dz_take = 0
      ser_ret = 0
      wk_jump = 0
      tp_flag = 0
      sg_rem0 = 0
      sg_rem1 = 0
      sg_rem2 = 0
      sg_rem3 = 0
      spr0 = 0
      spr1 = 0
      spr2 = 0
      spr3 = 0
      bx0 = 0
      bx1 = 0
      bx2 = 0
      bx3 = 0
      xb = 0
      vm_halt = 0
      ccnt = 0
      uwd0 = 0
      uwd1 = 0
      uwd2 = 0
      uwd3 = 0
      fw_en = 0
      sw_en = 0
      spawns = 0
      deaths = 0
      sends = 0
      recvs = 0
      evicts = 0
      dm_pend = 0
      wk_pend = 0
      tp_pend = 0
      lk_pend = 0
      # the sup transport (notes/53 phase 4): the egress latch is a
      # pending SIGNAL — cross-program by nature — and the rs kinds
      # gate what a parked seat would emit. Dest/ref/reason payloads
      # are data latches by the rule above.
      sx_pend = 0
      sx_kind = 0
      pkw_pend = 0
      rs0_kind = 0
      rs1_kind = 0
      rs2_kind = 0
      rs3_kind = 0
      rfe0 = 0
      rfe1 = 0
      rfe2 = 0
      rfe3 = 0
      flt = 0
      flt_n = 0
      midx = 0
      cf_d = 0
      cf_seat_d = 0
      cf_ar_d = 0
      ba_pend = 0
      ba_seat = 0
      ba_rsn = 0
      gc_st = 0
      gc_wait = 0
      gc_want = 0
      gc_from = 0
      gc_pend = 0
      gc_slot = 0
      gc_pk = 0
      gc_start = 0
    else
      # F→D→X: the bundle IS the pipeline register
      xb = cm_bundle

      # ---- the VM-wide halt (notes/33)
      if bor(band(x_en, real_halt), halt_in) == 1 do
        vm_halt = 1
      end

      if boot_en == 1 do
        vm_halt = 0
      end

      # ---- the map index (`notes/42`). One write site: `mseti` names a
      # slot's index and nothing else touches it.
      if mi_set == 1 do
        midx = bor(band(midx, bnot(255 <<< (x_slot * 8))), mi_val <<< (x_slot * 8))
      end

      # ---- `callfun` (`notes/42`): one pipeline stage, and a pending
      # arity error for the cycle after that. The clear is written before
      # the set so a fault raised in the same cycle it is noticed still
      # gets its turn rather than being overwritten by it.
      cf_d = any_cfun
      cf_seat_d = x_seat
      cf_ar_d = cf_ar

      ba_rsn = ba_go

      if ba_go == 1 do
        ba_pend = 0
      end

      if ba_bad == 1 do
        ba_pend = 1
        ba_seat = cf_seat_d
      end

      # ---- the collection (`notes/46`)
      gc_start = 0

      # one write site for the parked-context bitmap: a park sets the
      # asking seat's bit, and the resume the collection hands out
      # clears it. They cannot name the same seat in the same cycle —
      # a parked context is not at X.
      gc_pk = bor(band(gc_pk, bnot(gc_res4)), gc_park * (1 <<< x_seat))

      if gc_park == 1 do
        gc_want = 1
      end

      if gc_req_dz == 1 do
        gc_want = 1
      end

      hdl_case <<gc_st::3>> do
        # ---- 0: nothing to do. A halted VM does not collect: there is
        # nothing left to allocate for, and the corpse is the record.
        <<0::3>> ->
          if band(gc_want, bnot(vm_halt)) == 1 do
            gc_wait = 0
            gc_st = 1
          end

        # ---- 1: quiet the background workers, then MOVE THE ALLOCATION
        # BASE. `frozen` stops fetching; bundles already at D and X still
        # retire and one of them can touch the heap, so two rotations at
        # T=4 is eight cycles — and a serialisation, a rebuild, a mailbox
        # scan, a signal or a window drain has to finish as well, because
        # the collector is about to take the port one of them is using.
        #
        # The flip here is the one that MOVES: `hp_flip_sp` toggles the
        # semispace, `hp_flip_ap` puts the bump pointer at the bottom of
        # the fresh one, and from that instant the mutator allocates in
        # to-space while from-space stops growing. Nothing has been
        # collected yet.
        <<1::3>> ->
          gc_wait = gc_wait + 1

          if band(gc_wait > 8, gc_quiet) == 1 do
            gc_from = hpb_space
            gc_pend = live_vec
            gc_wait = 0
            gc_st = 2
          end

        # ---- 2: RUN. This is the state the whole design is for: a
        # collection is half done, from-space still holds every process
        # that has not had its turn, and the engine is executing at full
        # speed.
        #
        # It leaves when the cursor lands on a pending slot AND either
        # the gap has been served or somebody is parked waiting for
        # their own collection. The cursor rotates one slot per cycle;
        # a scan that costs nothing does not need to be wide.
        <<2::3>> ->
          if gc_any == 0 do
            gc_want = 0
            gc_st = 0
          else
            if bor(gc_wait >= GC_GAP, gc_urg) == 1 do
              if gc_pick == 1 do
                gc_wait = 0
                gc_st = 3
              else
                gc_slot = gc_slot + 1
              end
            else
              gc_wait = gc_wait + 1
            end
          end

        # ---- 3: settle. Frozen again, and waiting for the same quiet
        # as state 1 — a serialisation that started while the engine was
        # running in state 2 has to finish before the collector takes
        # the port.
        <<3::3>> ->
          gc_wait = gc_wait + 1

          if band(gc_wait > 8, gc_quiet) == 1 do
            gc_start = 1
            gc_st = 4
          end

        # ---- 4: `RootWalker`, on ONE slot
        <<4::3>> ->
          if rk_done == 1 do
            gc_st = 5
          end

        # ---- 5: Cheney's scan, to completion. Not an optimisation:
        # this process may not resume holding a to-space pointer to an
        # object whose own contents still point into from-space
        # (`notes/46`).
        <<5::3>> ->
          if cx_done == 1 do
            gc_st = 6
          end

        # ---- 6: the heap adopts the collector's bump pointer — no
        # space change this time, the space moved in state 1 — and this
        # slot's bit clears, which is what lets it resume.
        #
        # `cx_ovf` means the live set did not fit. There is nothing to
        # do about it here: the slot is marked done, the collection
        # carries on, and the next allocation into a full to-space is a
        # real `heap_full`, which is the death `Machine.alloc/4` throws
        # in the same situation.
        <<6::3>> ->
          gc_pend = band(gc_pend, bnot(1 <<< gc_slot))
          gc_wait = 0
          gc_st = 2
      end
      # ---- try/catch (notes/32)
      # one write site for the nesting counters: the alloc clear and the
      # X-stage update address different slots by construction
      ccnt = bor(band(band(ccnt, bnot(cc_clr)), bnot(cc_mask)), cc_we * (cc_val <<< (x_slot * 3)))

      if cc_inc == 1 do
        ctch[x_slot * 4 + cc_n] = x_depth * 8192 + pc_target * 16 + try_dest_x
      end

      # The reason has to be REMEMBERED: by the time the frames have
      # been walked back, the ALU that raised it has long since moved on
      # and the handler is entitled to the reason the process actually
      # failed with. Per seat, because the fill stream is shared and
      # another context's ret can get in front of this one.
      if band(x_en, catch_go) == 1 do
        if x_seat == 0 do
          cr0 = c_rd
          cn0 = any_fault_r
          cd_0 = c_depth
          uwd0 = catch_deep
        end

        if x_seat == 1 do
          cr1 = c_rd
          cn1 = any_fault_r
          cd_1 = c_depth
          uwd1 = catch_deep
        end

        if x_seat == 2 do
          cr2 = c_rd
          cn2 = any_fault_r
          cd_2 = c_depth
          uwd2 = catch_deep
        end

        if x_seat == 3 do
          cr3 = c_rd
          cn3 = any_fault_r
          cd_3 = c_depth
          uwd3 = catch_deep
        end
      end

      if dest_wr == 1 do
        if fill_seat == 0 do
          uwd0 = 0
        end

        if fill_seat == 1 do
          uwd1 = 0
        end

        if fill_seat == 2 do
          uwd2 = 0
        end

        if fill_seat == 3 do
          uwd3 = 0
        end
      end

      # the two fill streams' one-cycle write delays
      fw_en = fill_en
      fw_idx = fill_idx
      fw_seat = fill_seat
      sw_en = sfill_en
      sw_idx = sfill_idx
      sw_seat = sfill_seat

      # the deserialiser no longer drives the mailbox: the rebuild happens
      # at the peek, and the entry is freed by the `recv_take` that
      # follows a matching clause
      dz_take = 0

      ser_ret = 0

      # a compound send parks: remember the message and where it is
      # bound, because `send_go` lands at this seat's F slot, cycles
      # after the X that decided both
      if is_send_long == 1 do
        if x_seat == 0 do
          sg_msg0 = snd_msg
          sg_slot0 = su_slot_mb
          sg_pid0 = snd_pid_res
          sg_rem0 = snd_remote
        end

        if x_seat == 1 do
          sg_msg1 = snd_msg
          sg_slot1 = su_slot_mb
          sg_pid1 = snd_pid_res
          sg_rem1 = snd_remote
        end

        if x_seat == 2 do
          sg_msg2 = snd_msg
          sg_slot2 = su_slot_mb
          sg_pid2 = snd_pid_res
          sg_rem2 = snd_remote
        end

        if x_seat == 3 do
          sg_msg3 = snd_msg
          sg_slot3 = su_slot_mb
          sg_pid3 = snd_pid_res
          sg_rem3 = snd_remote
        end
      end

      if send_go == 1 do
        sr_seat = send_seat
        sr_head = 1
        sr_len = 0
        sr_hdr = 0

        sr_rem =
          (send_seat == 0) * sg_rem0 + (send_seat == 1) * sg_rem1 +
            (send_seat == 2) * sg_rem2 + (send_seat == 3) * sg_rem3

        sr_pid =
          (send_seat == 0) * sg_pid0 + (send_seat == 1) * sg_pid1 +
            (send_seat == 2) * sg_pid2 + (send_seat == 3) * sg_pid3

        sr_slot =
          (send_seat == 0) * sg_slot0 + (send_seat == 1) * sg_slot1 +
            (send_seat == 2) * sg_slot2 + (send_seat == 3) * sg_slot3
      end

      # the count is in and it fits: the head flit carries the length
      if ser_go_emit == 1 do
        sr_len = ser_count
      end

      # only the FIRST accepted flit is the head; a stalled one is not
      # accepted and must stay the head
      if mb_ser == 1 do
        sr_head = 0
      end

      # the packet header goes in once, and only once it has been
      # ACCEPTED — a full ring must not swallow it
      if band(band(sr_rem, ser_ring_en), band(ser_go_emit, bnot(sr_hdr))) == 1 do
        sr_hdr = 1
      end

      # ---- the remote-spawn transport (`notes/49`)
      #
      # Egress. State 1 collects: the staging bank drains sixteen words
      # over sixteen cycles and cannot be paused, so the first eight are
      # LATCHED here and transmitted afterwards at the ring's pace.
      if rt_st == 1 do
        if spill_valid == 1 do
          if spill_idx == 0 do
            tx0 = spill_data
          end

          if spill_idx == 1 do
            tx1 = spill_data
          end

          if spill_idx == 2 do
            tx2 = spill_data
          end

          if spill_idx == 3 do
            tx3 = spill_data
          end

          if spill_idx == 4 do
            tx4 = spill_data
          end

          if spill_idx == 5 do
            tx5 = spill_data
          end

          if spill_idx == 6 do
            tx6 = spill_data
          end

          if spill_idx == 7 do
            tx7 = spill_data
          end

          if spill_idx == 15 do
            rt_st = 2
          end
        end
      end

      if band(rt_st == 2, ring_w_ready) == 1 do
        rt_st = 3
        rt_i = 0
      end

      if band(rt_st == 3, ring_w_ready) == 1 do
        if rt_i + 1 == rt_n do
          rt_st = 0
        else
          rt_i = rt_i + 1
        end
      end

      # A reply outranks a request; both are written before the starts
      # below so that a start in the same cycle cannot be undone by the
      # advance above it (`on` assignments are sequential).
      if rt_rep_go == 1 do
        rt_st = 2
        rt_kind = 2
        rt_n = 1
        rt_deng = rx_from[31..28]
        rt_hword = rx_from
        tx0 = rx_child
        rx_rep = 0
      end

      # a signal packet takes the ring whole, like everything else
      # through this FSM; its payload reads the sx latch combinationally
      if rt_sx_go == 1 do
        rt_st = 2
        rt_kind = sx_kind
        rt_n =
          bor(sx_kind == 3, sx_kind == 4) * 1 +
            bor(sx_kind == 5, sx_kind == 6) * 2 + (sx_kind == 7) * 3

        rt_deng = sx_dest[31..28]
        rt_hword = sx_dest
      end

      # ...and frees the latch when the last flit is accepted
      if band(band(rt_st == 3, ring_w_ready),
           band(rt_i + 1 == rt_n, rt_kind > 2)) == 1 do
        sx_pend = 0
      end

      if rt_start == 1 do
        rt_st = 1
        rt_kind = 1
        rt_n = f_arity + 1
        rt_deng = f_tgt_eng
        rt_arity = f_arity
        rt_pc = f_tgt
        rt_hword = 21_474_836_480 + eng_id * 268_435_456 + f_slot_o * 4_194_304 + f_serial
        ro_busy = 1
        ro_seat = f_seat
        ro_have = 0
        ro_pdone = 0
      end

      # the pid lands in the parked context's `rd`, one turn before the
      # context is told it may go
      if ro_pw == 1 do
        ro_pdone = 1
      end

      # ...and the whole transaction retires when the spawn commits
      if sc_rem == 1 do
        ro_have = 0
        ro_pdone = 0
      end

      # a requester killed while its child was being created wants no
      # answer; the reply is dropped by the incarnation check on the way
      # in, and this releases the seat's half of the bookkeeping
      if band(died, died_seat == ro_seat) == 1 do
        ro_have = 0
        ro_pdone = 0
      end

      # Ingress. The receiving half owns one request at a time, which is
      # what `rg_take` backpressures on.
      if rg_take == 1 do
        if rx_idx == 0 do
          rx_pc = ring_r_word[8..0]
          rx_ar = ring_r_word[11..9]
          rx_from = rg_pid
        end

        if rx_idx == 1 do
          rx0 = ring_r_word
        end

        if rx_idx == 2 do
          rx1 = ring_r_word
        end

        if rx_idx == 3 do
          rx2 = ring_r_word
        end

        if rx_idx == 4 do
          rx3 = ring_r_word
        end

        if rx_idx == 5 do
          rx4 = ring_r_word
        end

        if rx_idx == 6 do
          rx5 = ring_r_word
        end

        if rx_idx == 7 do
          rx6 = ring_r_word
        end

        if rx_idx == 8 do
          rx7 = ring_r_word
        end

        if rg_left == 1 do
          rx_pend = 1
        end
      end

      if rg_rep == 1 do
        if band(rg_ok, ro_busy) == 1 do
          ro_pid = ring_r_word
          ro_have = 1
        end

        ro_busy = 0
      end

      # the receiver's own half: take the request, then answer it
      if su_rsp_ok == 1 do
        rx_pend = 0
        rx_child = 21_474_836_480 + eng_id * 268_435_456 + su_rsp_slot * 4_194_304 +
          su_rsp_serial
      end

      if rx_full == 1 do
        rx_pend = 0
        rx_child = 0
        rx_rep = 1
      end

      # the reply waits for the newborn's registers to exist, so a pid
      # the requester can send to is a pid whose process is complete
      if su_rsp_done == 1 do
        rx_rep = 1
      end

      # ---- ring ingress
      if rg_st == 0 do
        if band(ring_r_valid, ring_r_head) == 1 do
          rg_pid = ring_r_word
          rg_kind = ring_r_kind
          rg_len = ring_r_len
          rg_left = ring_r_len
          rg_head = 1
          rg_st = 1
          # the arrival check, on the ADDRESS presented this cycle
          rg_ok = rg_live
        end
      else
        # an unrecognised kind is CONSUMED, not stalled on: a packet
        # this engine does not understand must not wedge the ring for
        # every packet behind it
        if band(ring_r_valid, bor(mb_rg, bor(bnot(rg_ok), rg_kind != 0))) == 1 do
          rg_head = 0

          if rg_left == 1 do
            rg_st = 0
          else
            rg_left = rg_left - 1
          end
        end
      end

      # ---- ingress sup kinds: latch the early flits, act on the last
      if band(rg_k5, bnot(rg_fin)) == 1 do
        rgs_a = ring_r_word
      end

      if band(rg_k6, bnot(rg_fin)) == 1 do
        rgs_a = ring_r_word
      end

      if band(rg_k7, bnot(rg_fin)) == 1 do
        if rg_pay0 == 1 do
          rgs_b = ring_r_word[21..0]
        else
          rgs_a = ring_r_word
        end
      end

      if rg3_add == 1 do
        lk_pend = 1
        lk_cmd_r = 4
        lk_a_r = rg_slot
        lk_pid_r = ring_r_word
      end

      if band(rg_k4, band(rg_ok, lt_gate)) == 1 do
        lk_pend = 1
        lk_cmd_r = 5
        lk_a_r = rg_slot
        lk_pid_r = ring_r_word
      end

      if rg5_add == 1 do
        lk_pend = 1
        lk_cmd_r = 6
        lk_a_r = rg_slot
        lk_pid_r = rgs_a
        lk_ref_r = ring_r_word[21..0]
      end

      if band(rg6_doom, dm_gate) == 1 do
        dm_pend = 1
        dm_slot = rg_slot
        dm_reason = rg6_kill * 1 + band(bnot(rg6_kill), 1) * ring_r_word[7..0]
      end

      if band(rg6_msg, sd_gate) == 1 do
        sd_st = 1
        sd_kind = 0
        sd_slot = rg_slot
        sd_from = rgs_a
        sd_reason = ring_r_word[7..0]
      end

      if rg7_msg == 1 do
        sd_st = 1
        sd_kind = 1
        sd_ref = rgs_b
        sd_slot = rg_slot
        sd_from = rgs_a
        sd_reason = ring_r_word[7..0]
      end

      # the stream retires — delivered, refused for want of room, or
      # unserialisable — and the sender resumes either way
      if bor(ser_done, bor(ser_abort, ser_fault)) == 1 do
        ser_ret = 1
      end

      # a message that does not fit kills the RECEIVER with
      # `mailbox_full`, the same rule an immediate overflow follows:
      # backpressure on the sender would leak one process's slowness
      # into another's WCET
      if ser_abort == 1 do
        dm_pend = 1
        dm_slot = sr_slot
        dm_reason = 7
      end

      # depth past 8 or a message past 63 flits is the SENDER's error
      if ser_fault == 1 do
        dm_pend = 1

        dm_slot =
          (sr_seat == 0) * slot0 + (sr_seat == 1) * slot1 +
            (sr_seat == 2) * slot2 + (sr_seat == 3) * slot3

        dm_reason = ser_freason
      end

      # remember where a peek wants its answer put
      if band(any_rpeek, x_en) == 1 do
        if x_seat == 0 do
          pk0 = c0_rpeek * rd0 + c1_rpeek * rd1 + c2_rpeek * rd2
        end

        if x_seat == 1 do
          pk1 = c0_rpeek * rd0 + c1_rpeek * rd1 + c2_rpeek * rd2
        end

        if x_seat == 2 do
          pk2 = c0_rpeek * rd0 + c1_rpeek * rd1 + c2_rpeek * rd2
        end

        if x_seat == 3 do
          pk3 = c0_rpeek * rd0 + c1_rpeek * rd1 + c2_rpeek * rd2
        end
      end

      # a compound peek parks; remember who it was and what to reclaim
      if take_go == 1 do
        dz_seat = take_seat
        dz_pslot = dz_slot
        dz_plen = dz_len

        dz_rd =
          (take_seat == 0) * pk0 + (take_seat == 1) * pk1 +
            (take_seat == 2) * pk2 + (take_seat == 3) * pk3
      end

      # the deferred-writeback latch: catch the pulse, hold the payload,
      # release it on the owner's own X slot
      if dz_done == 1 do
        dzw_pend = 1
        dzw_seat = dz_seat
        dzw_rd = dz_rd
        dzw_result = dz_result
      end

      if band(dzw_wb, bnot(dz_done)) == 1 do
        dzw_pend = 0
      end

      # the rebuilt term REPLACES the head flit in the per-seat latch, so
      # the `recv_take` that follows a matching clause hands over the
      # whole message rather than its first word
      if dz_done == 1 do
        if dz_seat == 0 do
          rw0 = dz_result
        end

        if dz_seat == 1 do
          rw1 = dz_result
        end

        if dz_seat == 2 do
          rw2 = dz_result
        end

        if dz_seat == 3 do
          rw3 = dz_result
        end
      end

      # the heap's answer arrives one cycle after the command, by which
      # time the rotation has moved on — so remember whose it is
      hp_en_d = band(x_en, bor(band(any_heap, hp_writes), any_ldc))
      hp_src_d = any_ldc
      hp_seat_d = x_seat
      hp_rd_d = hp_rd

      # ...and capture it, for the seat that issued it, one cycle later
      if hp_en_d == 1 do
        if hp_seat_d == 0 do
          hl0 = late_word
          hd0 = hp_rd_d
        end

        if hp_seat_d == 1 do
          hl1 = late_word
          hd1 = hp_rd_d
        end

        if hp_seat_d == 2 do
          hl2 = late_word
          hd2 = hp_rd_d
        end

        if hp_seat_d == 3 do
          hl3 = late_word
          hd3 = hp_rd_d
        end
      end

      # per-seat latches: written at X, read at a later commit
      if x_en == 1 do
        if bor(any_call, cfun_raw) == 1 do
          if x_seat == 0 do
            cd0 = call_dest_x
          end

          if x_seat == 1 do
            cd1 = call_dest_x
          end

          if x_seat == 2 do
            cd2 = call_dest_x
          end

          if x_seat == 3 do
            cd3 = call_dest_x
          end
        end

        # the staging bitmap tracks boxedness as each argument lands
        if bor(bx_w0, bor(bx_w1, bx_w2)) == 1 do
          if x_seat == 0 do
            bx0 = bor(band(bx0, bnot(bx_clr)), bx_set)
          end

          if x_seat == 1 do
            bx1 = bor(band(bx1, bnot(bx_clr)), bx_set)
          end

          if x_seat == 2 do
            bx2 = bor(band(bx2, bnot(bx_clr)), bx_set)
          end

          if x_seat == 3 do
            bx3 = bor(band(bx3, bnot(bx_clr)), bx_set)
          end
        end

        if any_spawn == 1 do
          # every spawn turns the wheel, local or not — the model's
          # counter does too, and a counter that only counted the
          # remote ones would place differently after the first
          # boxed-argument spawn stayed home
          sp_rr = sp_rr + 1

          if x_seat == 0 do
            sr0 = spawn_rd_x
            spr0 = sp_remote_x
            spt0 = sp_tgt
            spa0 = sp_arity_x
          end

          if x_seat == 1 do
            sr1 = spawn_rd_x
            spr1 = sp_remote_x
            spt1 = sp_tgt
            spa1 = sp_arity_x
          end

          if x_seat == 2 do
            sr2 = spawn_rd_x
            spr2 = sp_remote_x
            spt2 = sp_tgt
            spa2 = sp_arity_x
          end

          if x_seat == 3 do
            sr3 = spawn_rd_x
            spr3 = sp_remote_x
            spt3 = sp_tgt
            spa3 = sp_arity_x
          end
        end

        if any_ret == 1 do
          if x_seat == 0 do
            rv0 = ret_word
          end

          if x_seat == 1 do
            rv1 = ret_word
          end

          if x_seat == 2 do
            rv2 = ret_word
          end

          if x_seat == 3 do
            rv3 = ret_word
          end
        end

        # a fault a `try` catches is not a fault the MACHINE had: the
        # program asked for the possibility and handled it, and a
        # sticky `faulted` that says otherwise is the fault port lying
        # again (`notes/26` bug 3, in a new place)
        if band(any_fault, bnot(catch_go)) == 1 do
          flt = 1
          flt_r = any_fault_r
        end

        # ---- per-seat receive state
        if any_rstart == 1 do
          if x_seat == 0 do
            rfe0 = 0
          end

          if x_seat == 1 do
            rfe1 = 0
          end

          if x_seat == 2 do
            rfe2 = 0
          end

          if x_seat == 3 do
            rfe3 = 0
          end
        end

        if any_rhash == 1 do
          if x_seat == 0 do
            rf0 = imm0[7..0]
            rfe0 = 1
          end

          if x_seat == 1 do
            rf1 = imm0[7..0]
            rfe1 = 1
          end

          if x_seat == 2 do
            rf2 = imm0[7..0]
            rfe2 = 1
          end

          if x_seat == 3 do
            rf3 = imm0[7..0]
            rfe3 = 1
          end
        end

        # a take ends the receive: the filter clears with it
        if any_rtake == 1 do
          recvs = recvs + 1

          if x_seat == 0 do
            rfe0 = 0
          end

          if x_seat == 1 do
            rfe1 = 0
          end

          if x_seat == 2 do
            rfe2 = 0
          end

          if x_seat == 3 do
            rfe3 = 0
          end
        end

        # sends/recvs WRAP rather than saturate: they are activity
        # gauges for a demo that never ends, not totals
        if any_send == 1 do
          sends = sends + 1
        end
      end

      # the scan's word must be LATCHED per seat: by the time the parked
      # context resumes and `recv_take` wants it, the mailbox's output
      # has moved on (the same lesson as the ret value and the M2 link)
      if band(mb_done, mb_hit) == 1 do
        if scan_done_seat_w == 0 do
          rw0 = mb_hit_word
          rl0 = mb_hit_len
          ri0 = mb_hit_idx
        end

        if scan_done_seat_w == 1 do
          rw1 = mb_hit_word
          rl1 = mb_hit_len
          ri1 = mb_hit_idx
        end

        if scan_done_seat_w == 2 do
          rw2 = mb_hit_word
          rl2 = mb_hit_len
          ri2 = mb_hit_idx
        end

        if scan_done_seat_w == 3 do
          rw3 = mb_hit_word
          rl3 = mb_hit_len
          ri3 = mb_hit_idx
        end
      end

      # entry 38: a short hit's word must reach rd. The seat is held
      # (BarrelSeq state 19) until the owner's own X slot carries it in
      if band(mb_done, band(mb_hit, bnot(scan_long))) == 1 do
        pkw_pend = 1
        pkw_seat = scan_done_seat_w

        pkw_rd =
          (scan_done_seat_w == 0) * pk0 + (scan_done_seat_w == 1) * pk1 +
            (scan_done_seat_w == 2) * pk2 + (scan_done_seat_w == 3) * pk3

        pkw_word = mb_hit_word
      end

      if band(pkw_wb, bnot(band(mb_done, band(mb_hit, bnot(scan_long))))) == 1 do
        pkw_pend = 0
      end

      # remember which seat owns the scan in flight
      if peek_go == 1 do
        scan_done_seat_w = peek_seat
      end

      sig_traps_d = sig_traps

      # ---- the {'EXIT', ...} emitter: four cycles, one flit each
      if sd_st != 0 do
        if sd_st == 4 + sd_kind do
          sd_st = 0
        else
          sd_st = sd_st + 1
        end
      end

      # ---- a signal leaving the link fan-out (or an `exit2`)
      # A DOWN is always a message. A monitor reports the fact of a
      # death; it does not share it — which is the whole difference
      # between watching something and being tied to it.
      if band(lt_sig, bnot(lt_sig_remote)) == 1 do
        if bor(lt_sig_kind, sig_traps_d) == 1 do
          sd_st = 1
          sd_kind = lt_sig_kind
          sd_ref = lt_sig_ref
          sd_slot = lt_sig_slot
          sd_from = lt_sig_from
          sd_reason = lt_sig_reason
        else
          # `normal` reaches here now that the table no longer filters
          # it at the source (a TRAPPING partner must see it) — for a
          # non-trapper it kills nobody
          if lt_sig_reason != 0 do
            dm_pend = 1
            dm_slot = lt_sig_slot
            dm_reason = lt_sig_reason
          end
        end
      end

      # ---- the outbound-signal latch: one packet, three producers,
      # priority fixed by the comb claims (walk > noproc > sup op)
      if bor(sxw_lt, bor(sxw_np, sxw_sup)) == 1 do
        sx_pend = 1

        sx_kind =
          sxw_lt * (6 + lt_sig_kind) + sxw_np * np_kind + sxw_sup * rs_kind_f

        sx_dest = sxw_lt * lt_sig_peer + sxw_np * np_dest + sxw_sup * rs_dest_f
        sx_from = sxw_lt * lt_sig_from + sxw_np * rg_pid + sxw_sup * f_self_pid
        sx_ref = sxw_lt * lt_sig_ref + sxw_np * np_ref + sxw_sup * rs_ref_f
        sx_reason = sxw_lt * lt_sig_reason + sxw_np * 11 + sxw_sup * rs_reason_f
      end

      # ---- a sup op aimed at ANOTHER engine: latch the packet for
      # the parked seat (the context is entering BarrelSeq state 18
      # this same cycle) and do the local half here — a remote link
      # records its near side, a remote monitor mints its ref.
      if sup_remote == 1 do
        if any_link == 1 do
          lk_pend = 1
          lk_cmd_r = 4
          lk_a_r = x_slot
          lk_pid_r = sup_pid
        end

        if any_unlink == 1 do
          lk_pend = 1
          lk_cmd_r = 5
          lk_a_r = x_slot
          lk_pid_r = sup_pid
        end

        if any_mon == 1 do
          next_ref = next_ref + 1
        end

        if x_seat == 0 do
          rs0_kind = any_link * 3 + any_unlink * 4 + any_mon * 5 + any_exit2 * 6
          rs0_dest = sup_pid
          rs0_ref = next_ref
          rs0_reason = ex_reason
        end

        if x_seat == 1 do
          rs1_kind = any_link * 3 + any_unlink * 4 + any_mon * 5 + any_exit2 * 6
          rs1_dest = sup_pid
          rs1_ref = next_ref
          rs1_reason = ex_reason
        end

        if x_seat == 2 do
          rs2_kind = any_link * 3 + any_unlink * 4 + any_mon * 5 + any_exit2 * 6
          rs2_dest = sup_pid
          rs2_ref = next_ref
          rs2_reason = ex_reason
        end

        if x_seat == 3 do
          rs3_kind = any_link * 3 + any_unlink * 4 + any_mon * 5 + any_exit2 * 6
          rs3_dest = sup_pid
          rs3_ref = next_ref
          rs3_reason = ex_reason
        end
      end

      # ---- link / unlink, deferred if the table is walking a death
      if band(any_sup, band(bnot(sup_bad), bnot(sup_remote))) == 1 do
        if any_exit2 == 1 do
          # `exit2` is a signal aimed at one process rather than a
          # fan-out: the link table is not involved at all, and a stale
          # pid dead-letters silently the way `send` does.
          #
          # Two rules BEAM is emphatic about (`notes/50`): `exit(Pid,
          # kill)` is UNTRAPPABLE — a trapping process dies like anyone
          # else — and the victim's recorded reason is `killed` (1), not
          # the `kill` (2) that was sent. A supervisor matching on the
          # exit reason would otherwise see an atom BEAM never delivers.
          if sup_alive == 1 do
            if band(pt_rd3_trap, ex_reason != 2) == 1 do
              sd_st = 1
              sd_slot = sup_slot
              sd_from = self_pid
              sd_reason = ex_reason
            else
              # `normal` from exit/2 kills nobody but the caller
              # itself — the model checks reason before doom, and a
              # doomed-with-normal target was this path's quiet bug
              if bor(ex_reason != 0, sup_slot == x_slot) == 1 do
                dm_pend = 1
                dm_slot = sup_slot
                dm_reason = (ex_reason == 2) * 1 + band(ex_reason != 2, 1) * ex_reason
              end
            end
          end
        else
          if any_mon == 1 do
            # the ref is handed back through port 0 either way; what
            # differs is whether anything is recorded
            next_ref = next_ref + 1

            if sup_alive == 1 do
              lk_pend = 1
              lk_cmd_r = 3
              lk_a_r = x_slot
              lk_b_r = sup_slot
              lk_ref_r = next_ref
            else
              # monitoring a dead incarnation fires immediately: the
              # dead-letter rule, as a DOWN carrying `noproc`
              sd_st = 1
              sd_kind = 1
              sd_ref = next_ref
              sd_slot = x_slot
              sd_from = sup_pid
              sd_reason = 11
            end
          else
          if bor(any_unlink, sup_alive) == 1 do
            lk_pend = 1
            lk_cmd_r = any_link * 1 + any_unlink * 2
            lk_a_r = x_slot
            lk_b_r = sup_slot
          else
            # link to a dead incarnation: the dead-letter rule answers
            # `noproc` to the CALLER, which for a non-trapping caller
            # means the caller dies — exactly `link/1` semantics
            if pt_rd3_trap == 1 do
              sd_st = 1
              sd_slot = x_slot
              sd_from = sup_pid
              sd_reason = 11
            else
              dm_pend = 1
              dm_slot = x_slot
              dm_reason = 11
            end
          end
          end
        end
      end

      if band(lk_pend, bnot(lt_busy)) == 1 do
        lk_pend = 0
      end

      if any_trap == 1 do
        tp_pend = 1
        tp_slot = x_slot
        tp_flag = trap_flag
      end

      if pt_trap_go == 1 do
        tp_pend = 0
      end

      # a mailbox overflow dooms the TARGET; issue it when the command
      # port frees up
      if mb_ovf == 1 do
        dm_pend = 1
        dm_slot = mb_ovf_slot
        dm_reason = 7
      end

      # a `park` command going out IS an eviction
      if band(pt_cmd == 7, evicts != 255) == 1 do
        evicts = evicts + 1
      end

      if wake_queued == 1 do
        wk_pend = 1
        wk_slot = wake_slot
        wk_jump = 0
      end

      # an EVICTED process whose deadline expired is requeued with its
      # timeout pc, which is `save` (write pc, state queued) rather
      # than `wake` (state queued only) — the two commands differ by
      # exactly the thing a timeout needs
      if band(tm_fire, bnot(tm_resident)) == 1 do
        wk_pend = 1
        wk_slot = tm_fire_slot
        wk_pc = tm_fire_pc
        wk_jump = 1
      end

      # the wake retires once BOTH halves have gone out
      if band(wk_pend, band(pt_wake_go, rq_wake_go)) == 1 do
        wk_pend = 0
      end

      if pt_doom_go == 1 do
        dm_pend = 0
      end

      if spawn_commit == 1 do
        if spawns != 4095 do
          spawns = spawns + 1
        end
      end

      if died == 1 do
        if deaths != 4095 do
          deaths = deaths + 1
        end

        if died_fault == 1 do
          flt = 1
          flt_s = su_died_slot

          if flt_n != 255 do
            flt_n = flt_n + 1
          end

          # A process killed by a SIGNAL never faulted at X, so the
          # X-stage reason reads `normal` for it — the same laundering
          # `notes/25` found on the propagation path, one port over.
          # For a doomed slot the reason is the one in its table entry;
          # for an X fault the earlier `any_fault` branch already wrote
          # it, and `any_fault_r` has moved on by now, so leave it.
          if lt_doomed == 1 do
            flt_r = pt_rd4_reason
          end

          # ...and a `badarity` never faulted at X either: it was noticed
          # a stage later, when the closure's funinfo came back
          # (`notes/42`). Same laundering, third place.
          if ba_rsn == 1 do
            flt_r = A_BADARITY
          end
        end
      end
    end
  end

  instance :seq, PicoBEAM.RTL.BarrelSeq,
    clk: :clk,
    rst: :rst,
    seat_wr: :seat_wr,
    seat_idx: :seat_idx,
    seat_pc: :seat_pc,
    seat_clr: :seat_clr,
    is_jump: :any_jump,
    pc_target: :pc_target,
    is_call: :any_call,
    is_cfun: :cfun_raw,
    is_ret: :any_ret,
    is_halt: :any_halt,
    catch_go: :catch_go,
    catch_deep: :catch_deep,
    catch_pc: :catch_pc,
    frozen: :engine_frozen,
    gc_park: :gc_park,
    gc_res4: :gc_res4,
    ftgt_en: :ftgt_en,
    ftgt_seat: :ftgt_seat,
    ftgt_pc: :ftgt_pc,
    bad_en: :ba_go,
    bad_seat: :ba_seat,
    dest_mode: :dest_mode,
    cwb_en: :cwb_en,
    cwb_seat: :cwb_seat,
    is_spawn: :any_spawn,
    is_rpeek: :any_rpeek,
    is_rwait_blk: :rwait_blk,
    fault_in: :any_fault,
    has_wb2: :has_wb2_w,
    drain_ready: :drain_ready,
    drain_done: :drain_done,
    drain_done_seat: :drain_done_seat,
    ret_pc_in: :fr_ret_pc,
    spawn_ready: :spawn_ready,
    spawn_full: :spawn_full,
    scan_free: :scan_free,
    scan_done: :mb_done,
    scan_done_seat: :scan_done_seat_w,
    scan_hit: :mb_hit,
    is_rtake_long: :is_rtake_long,
    scan_long: :scan_long,
    is_send_long: :is_send_long,
    is_sup_rem: :sup_remote,
    sup_park: :sup_park_f,
    sup_done: :sxw_sup,
    sup_done_seat: :f_seat,
    ser_free: :ser_free,
    ser_done: :ser_ret,
    ser_done_seat: :sr_seat,
    send_go: :send_go,
    send_seat: :send_seat,
    deser_free: :deser_free,
    deser_done: :dzw_wb,
    deser_done_seat: :dzw_seat,
    pkw_done: :pkw_wb,
    pkw_done_seat: :pkw_seat,
    take_go: :take_go,
    take_seat: :take_seat,
    take_want: :take_want,
    unblock_en: :unblock_en,
    unblock_seat: :unblock_seat,
    unblock_jump: :unblock_jump,
    unblock_pc: :unblock_pc,
    kill_en: :kill_en,
    kill_seat: :kill_seat,
    f_seat: :f_seat,
    f_en: :f_en,
    f_pc: :f_pc,
    d_seat: :d_seat,
    d_en: :d_en,
    x_seat: :x_seat,
    x_en: :x_en,
    x_pc: :x_pc,
    call_commit: :call_commit,
    commit_seat: :commit_seat,
    link_pc: :link_pc,
    pop_en: :pop_en,
    fill_en: :fill_en,
    fill_idx: :fill_idx,
    fill_seat: :fill_seat,
    dest_wr: :dest_wr,
    wb2_en: :wb2_en_w,
    spawn_commit: :spawn_commit,
    spawn_seat: :spawn_seat,
    spawn_park: :spawn_park,
    peek_go: :peek_go,
    peek_seat: :peek_seat,
    f_blocked: :f_blocked,
    f_tgt: :f_tgt,
    died: :died,
    died_seat: :died_seat,
    died_fault: :died_fault,
    dbg_st0: :dbg_st0,
    dbg_st1: :dbg_st1,
    dbg_st2: :dbg_st2,
    dbg_st3: :dbg_st3

  # the reduction budget is fixed here rather than forwarded from a top
  # param: the elaborator resolves a child's param from literals, and a
  # budget is a machine constant, not a board option
  instance :seats, PicoBEAM.RTL.SeatUnit,
    gc_en: :rk_sv_en,
    gc_slot: :rk_sv_slot,
    gc_idx: :rk_sv_idx,
    gc_wr: :rk_sv_wr,
    gc_data: :rk_sv_data,
    gc_q: :sv_gc_q,
    seat_val: :seat_val,
    budget: :sched_budget,
    clk: :clk,
    rst: :rst,
    f_seat: :f_seat,
    f_pc: :f_pc,
    f_run: :f_en,
    f_blocked: :f_blocked,
    d_seat: :d_seat,
    x_en: :x_en,
    x_seat: :x_seat,
    is_yield_x: :any_yield,
    died: :died,
    died_seat: :died_seat,
    death_reason: :any_fault_r,
    spawn_commit: :sc_local,
    spawn_seat: :spawn_seat,
    spawn_pc: :f_tgt,
    spawn_rd: :f_sr,
    spawn_ready: :su_spawn_ready,
    spawn_full: :su_spawn_full,
    op_spawn: :su_op_spawn,
    sp_ctx: :su_sp_ctx,
    pid_wr: :su_pid_wr,
    pid_seat: :su_pid_seat,
    pid_reg: :su_pid_reg,
    pid_data: :su_pid_data,
    rsp_req: :su_rsp_req,
    rsp_pc: :su_rsp_pc,
    rsp_idx: :su_rsp_idx,
    rsp_arg_d: :su_rsp_arg,
    rsp_ok: :su_rsp_ok,
    rsp_slot: :su_rsp_slot,
    rsp_serial: :su_rsp_serial,
    rsp_done: :su_rsp_done,
    f_slot_o: :f_slot_o,
    f_serial: :f_serial,
    seat_wr: :seat_wr,
    seat_clr: :seat_clr,
    seat_idx: :seat_idx,
    seat_pc: :seat_pc,
    pt_cmd: :su_cmd,
    pt_slot: :su_slot,
    pt_pc: :su_pc,
    pt_rd_slot: :pt_rd_slot,
    pt_rd_pc: :pt_rd_pc,
    pt_rd_serial: :pt_rd_serial,
    pt_alloc_slot: :alloc_slot,
    pt_alloc_serial: :alloc_serial,
    pt_occ: :occ,
    rq_push: :su_rq_push,
    rq_push_data: :su_rq_data,
    rq_pop: :su_rq_pop,
    rq_head: :rq_head,
    rq_empty: :rq_empty,
    op_swap: :op_swap,
    swap_ctx: :swap_ctx,
    drain_ready: :drain_ready,
    spill_valid: :spill_valid,
    spill_idx: :spill_idx,
    spill_data: :spill_data,
    sfill_en: :sfill_en,
    sfill_idx: :sfill_idx,
    sfill_seat: :sfill_seat,
    sfill_data: :sfill_data,
    slot0: :slot0,
    slot1: :slot1,
    slot2: :slot2,
    slot3: :slot3,
    x_slot: :x_slot,
    x_serial: :x_serial,
    eng_id: :eng_id,
    self_pid: :self_pid,
    died_slot: :su_died_slot,
    died_pid: :su_died_pid,
    dbg_st: :su_dbg_st,
    dbg_swaps: :dbg_swaps

  instance :procs, PicoBEAM.RTL.ProcTable,
    clk: :clk,
    rst: :rst,
    cmd: :pt_cmd,
    cmd_slot: :pt_slot,
    cmd_pc: :pt_pc,
    alloc_ok: :alloc_ok,
    alloc_slot: :alloc_slot,
    alloc_serial: :alloc_serial,
    rd_slot: :pt_rd_slot,
    rd_pc: :pt_rd_pc,
    rd_serial: :pt_rd_serial,
    rd_state: :pt_rd_state,
    rd2_slot: :pt_rd2_in,
    rd3_slot: :pt_rd3_slot,
    rd4_slot: :su_died_slot,
    rd4_reason: :pt_rd4_reason,
    rd5_slot: :rg_slot,
    rd5_serial: :pt_rd5_serial,
    rd6_slot: :sr_slot,
    rd6_state: :pt_rd6_state,
    rd7_slot: :peer_probe_slot,
    rd7_state: :pt_rd7_state,
    rd7_serial: :pt_rd7_serial,
    rd5_state: :pt_rd5_state,
    rd3_trap: :pt_rd3_trap,
    rd3_state: :pt_rd3_state,
    rd2_serial: :pt_rd2_serial,
    rd2_state: :pt_rd2_state,
    doom_vec: :doom_vec,
    live_vec: :live_vec,
    occ: :occ

  instance :runq, PicoBEAM.RTL.RunQueue,
    clk: :clk,
    rst: :rst,
    push: :rq_push,
    push_data: :rq_data,
    pop: :rq_pop,
    q_head: :rq_head,
    empty: :rq_empty,
    full: :rq_full,
    count: :rq_count

  instance :code_mem, PicoBEAM.RTL.CodeMem,
    clk: :clk,
    rd_addr: :f_pc,
    rd_bundle: :cm_bundle,
    wr_en: :ld_code_en,
    wr_addr: :ld_code_addr,
    wr_data: :ld_code_data

  instance :dec_d, PicoBEAM.RTL.Decode,
    clk: :clk,
    bundle: :cm_bundle,
    op0: :d_op0,
    rd0: :d_rd0,
    ra0: :d_ra0,
    rb0: :d_rb0,
    imm0: :d_imm0,
    i8_0: :d_i80,
    op1: :d_op1,
    rd1: :d_rd1,
    ra1: :d_ra1,
    rb1: :d_rb1,
    imm1: :d_imm1,
    i8_1: :d_i81,
    op2: :d_op2,
    rd2: :d_rd2,
    ra2: :d_ra2,
    rb2: :d_rb2,
    imm2: :d_imm2,
    i8_2: :d_i82

  instance :dcl0, PicoBEAM.RTL.Classify, clk: :clk, op: :d_op0, rs_in_f1: :dr0_rsf1
  instance :dcl1, PicoBEAM.RTL.Classify, clk: :clk, op: :d_op1, rs_in_f1: :dr1_rsf1
  instance :dcl2, PicoBEAM.RTL.Classify, clk: :clk, op: :d_op2, rs_in_f1: :dr2_rsf1

  instance :dec_x, PicoBEAM.RTL.Decode,
    clk: :clk,
    bundle: :xb,
    op0: :op0,
    rd0: :rd0,
    ra0: :ra0,
    rb0: :rb0,
    imm0: :imm0,
    i8_0: :i80,
    op1: :op1,
    rd1: :rd1,
    ra1: :ra1,
    rb1: :rb1,
    imm1: :imm1,
    i8_1: :i81,
    op2: :op2,
    rd2: :rd2,
    ra2: :ra2,
    rb2: :rb2,
    imm2: :imm2,
    i8_2: :i82

  instance :xcl0, PicoBEAM.RTL.Classify,
    clk: :clk,
    op: :op0,
    alu_sel: :c0_sel,
    wr_alu: :c0_wr,
    is_jmp: :c0_jmp,
    is_bift: :c0_bift,
    is_biff: :c0_biff,
    is_call: :c0_call,
    is_cfun: :c0_cfun,
    is_mseti: :c0_mseti,
    is_tail: :c0_tail,
    is_ret: :c0_ret,
    is_arg: :c0_arg,
    is_halt: :c0_halt,
    is_try: :c0_try,
    is_tend: :c0_tend,
    is_out: :c0_out,
    is_spawn: :c0_spawn,
    is_yield: :c0_yield,
    is_self: :c0_self,
    is_send: :c0_send,
    is_rstart: :c0_rstart,
    is_rhash: :c0_rhash,
    is_rpeek: :c0_rpeek,
    is_rskip: :c0_rskip,
    is_rtake: :c0_rtake,
    is_rwait: :c0_rwait,
    is_rwaitt: :c0_rwaitt,
    is_heap: :c0_heap,
    is_ldc: :c0_ldc,
    is_fail: :c0_fail,
    is_link: :c0_link,
    is_unlink: :c0_unlink,
    is_exit2: :c0_exit2,
    is_trapexit: :c0_trap,
    is_monitor: :c0_mon,
    is_regn: :c0_regn,
    is_wher: :c0_wher,
    is_unreg: :c0_unreg

  instance :xcl1, PicoBEAM.RTL.Classify,
    clk: :clk,
    op: :op1,
    alu_sel: :c1_sel,
    wr_alu: :c1_wr,
    is_jmp: :c1_jmp,
    is_bift: :c1_bift,
    is_biff: :c1_biff,
    is_call: :c1_call,
    is_cfun: :c1_cfun,
    is_mseti: :c1_mseti,
    is_tail: :c1_tail,
    is_ret: :c1_ret,
    is_arg: :c1_arg,
    is_halt: :c1_halt,
    is_try: :c1_try,
    is_tend: :c1_tend,
    is_out: :c1_out,
    is_spawn: :c1_spawn,
    is_yield: :c1_yield,
    is_self: :c1_self,
    is_send: :c1_send,
    is_rstart: :c1_rstart,
    is_rhash: :c1_rhash,
    is_rpeek: :c1_rpeek,
    is_rskip: :c1_rskip,
    is_rtake: :c1_rtake,
    is_rwait: :c1_rwait,
    is_rwaitt: :c1_rwaitt,
    is_heap: :c1_heap,
    is_ldc: :c1_ldc,
    is_fail: :c1_fail,
    is_link: :c1_link,
    is_unlink: :c1_unlink,
    is_exit2: :c1_exit2,
    is_trapexit: :c1_trap,
    is_monitor: :c1_mon,
    is_regn: :c1_regn,
    is_wher: :c1_wher,
    is_unreg: :c1_unreg

  instance :xcl2, PicoBEAM.RTL.Classify,
    clk: :clk,
    op: :op2,
    alu_sel: :c2_sel,
    wr_alu: :c2_wr,
    is_jmp: :c2_jmp,
    is_bift: :c2_bift,
    is_biff: :c2_biff,
    is_call: :c2_call,
    is_cfun: :c2_cfun,
    is_mseti: :c2_mseti,
    is_tail: :c2_tail,
    is_ret: :c2_ret,
    is_arg: :c2_arg,
    is_halt: :c2_halt,
    is_try: :c2_try,
    is_tend: :c2_tend,
    is_out: :c2_out,
    is_spawn: :c2_spawn,
    is_yield: :c2_yield,
    is_self: :c2_self,
    is_send: :c2_send,
    is_rstart: :c2_rstart,
    is_rhash: :c2_rhash,
    is_rpeek: :c2_rpeek,
    is_rskip: :c2_rskip,
    is_rtake: :c2_rtake,
    is_rwait: :c2_rwait,
    is_rwaitt: :c2_rwaitt,
    is_heap: :c2_heap,
    is_ldc: :c2_ldc,
    is_fail: :c2_fail,
    is_link: :c2_link,
    is_unlink: :c2_unlink,
    is_exit2: :c2_exit2,
    is_trapexit: :c2_trap,
    is_monitor: :c2_mon,
    is_regn: :c2_regn,
    is_wher: :c2_wher,
    is_unreg: :c2_unreg

  instance :windows, PicoBEAM.RTL.RegWindowCtx,
    clk: :clk,
    rst: :rst,
    rd_stg0: :gw_stg0,
    rd_ctx: :gw_rd_ctx,
    rd_addr0: :gw_rd_a0,
    rd_addr1: :d_rb0,
    rd_addr2: :ra_a2,
    rd_addr3: :d_rb1,
    rd_addr4: :ra_a4,
    rd_addr5: :d_rb2,
    rd_data0: :rw_rd0,
    rd_data1: :rw_rd1,
    rd_data2: :rw_rd2,
    rd_data3: :rw_rd3,
    rd_data4: :rw_rd4,
    rd_data5: :rw_rd5,
    w_ctx: :gw_w_ctx,
    w_en0: :gw_w_en0,
    w_stg0: :gw_w_stg0,
    w_addr0: :gw_w_a0,
    w_data0: :gw_w_d0,
    w_en1: :w1_en,
    w_stg1: :ag1,
    w_addr1: :rd1,
    w_data1: :w1_data,
    w_en2: :w2_en,
    w_stg2: :ag2,
    w_addr2: :rd2,
    w_data2: :w2_data,
    op_call: :call_commit,
    call_ctx: :commit_seat,
    op_tail: :any_tail,
    tail_ctx: :x_seat,
    op_swap: :op_swap,
    swap_ctx: :swap_ctx,
    op_spawn: :op_spawn,
    spawn_ctx: :sp_ctx,
    drain_ready: :drain_ready,
    drain_done: :drain_done,
    drain_done_seat: :drain_done_seat,
    spill_valid: :spill_valid,
    spill_idx: :spill_idx,
    spill_data: :spill_data,
    spill_seat: :spill_seat

  # A compound message's hash comes from the ROOT the serialiser
  # reports, not from the pointer word: hashing a pointer produced a
  # number that said nothing about the shape, which made `recv_hash`
  # filtering on a compound message meaningless (`notes/26` bug 1).
  instance :msg_hash, PicoBEAM.RTL.ShapeHash,
    clk: :clk,
    word: :sh_word,
    tup_arity: :sh_arity,
    tup_first: :sh_first,
    hash: :snd_hash

  instance :sender, PicoBEAM.RTL.SendUnit,
    clk: :clk,
    eng_id: :eng_id,
    remote: :snd_remote,
    remote_slot: :snd_rslot,
    send_en: :snd_en,
    pid_word: :snd_pid_res,
    msg_word: :snd_msg,
    msg_hash: :snd_hash,
    pt_slot: :su_pt_slot,
    pt_serial: :pt_rd2_serial,
    pt_state: :pt_rd2_state,
    mb_cmd: :su_cmd_mb,
    mb_slot: :su_slot_mb,
    mb_word: :su_word_mb,
    mb_hash: :su_hash_mb,
    mb_full: :mb_full,
    delivered: :delivered,
    dead_letter: :dead_letter,
    overflow: :mb_ovf,
    overflow_slot: :mb_ovf_slot,
    bad_pid: :bad_pid

  instance :mbox, PicoBEAM.RTL.Mailbox,
    clk: :clk,
    rst: :rst,
    cmd: :mb_cmd,
    cmd_slot: :mb_slot,
    cmd_word: :mb_word_w,
    cmd_hash: :mb_hash_w,
    cmd_head: :mb_head,
    cmd_len: :mb_len,
    cmd_filter: :mb_filter,
    cmd_filtered: :mb_filtered,
    q_slot: :mb_qslot,
    full: :mb_full,
    busy: :mb_busy,
    done: :mb_done,
    hit: :mb_hit,
    hit_word: :mb_hit_word,
    scan_len: :mb_scan_len,
    hit_idx: :mb_hit_idx,
    hit_len: :mb_hit_len,
    rf_slot: :mb_rf_slot,
    rf_idx: :mb_rf_idx,
    rf_word: :mb_rf_word,
    free: :mb_free,
    count: :mb_count,
    unseen: :mb_unseen

  instance :tmr, PicoBEAM.RTL.Timer,
    clk: :clk,
    rst: :rst,
    arm_en: :tm_arm,
    arm_slot: :x_slot,
    arm_delay: :tm_delay,
    arm_pc: :tm_pc,
    cancel_en: :tm_cancel,
    cancel_slot: :tm_cancel_slot,
    fire_en: :tm_fire,
    fire_slot: :tm_fire_slot,
    fire_pc: :tm_fire_pc,
    fire_ready: :tm_ready,
    now: :tm_now,
    armed: :tm_armed

  instance :lt, PicoBEAM.RTL.SignalTable,
    clk: :clk,
    rst: :rst,
    cmd: :lt_cmd,
    cmd_a: :lt_a,
    cmd_b: :lt_b,
    cmd_ref: :lt_ref,
    cmd_pid: :lt_cmd_pid,
    mon_full: :lt_mon_full,
    rem_full: :lt_rem_full,
    die_en: :lt_die,
    die_slot: :lt_die_slot,
    die_reason: :lt_die_reason,
    die_pid: :lt_die_pid,
    sig_ready: :lt_ready,
    rsig_ready: :sx_free,
    busy: :lt_busy,
    sig_en: :lt_sig,
    sig_kind: :lt_sig_kind,
    sig_ref: :lt_sig_ref,
    sig_slot: :lt_sig_slot,
    sig_from: :lt_sig_from,
    sig_reason: :lt_sig_reason,
    sig_remote: :lt_sig_remote,
    sig_peer: :lt_sig_peer,
    done: :lt_done,
    next_slot: :lt_next,
    next_valid: :lt_nextv,
    rd_slot: 0,
    rd_mask: :lt_mask

  instance :dz, PicoBEAM.RTL.DeserUnit,
    clk: :clk,
    rst: :rst,
    start: :dz_start,
    slot: :dz_slot,
    idx: :dz_idx,
    len: :dz_len,
    busy: :dz_busy,
    done: :dz_done,
    result: :dz_result,
    rf_slot: :mb_rf_slot,
    rf_idx: :mb_rf_idx,
    rf_word: :mb_rf_word,
    h_req: :dz_h_req,
    h_cmd: :dz_h_cmd,
    h_pa: :dz_h_pa,
    h_pb: :dz_h_pb,
    h_i8: :dz_h_i8,
    h_grant: :dz_grant,
    h_rd_late: :hp_rd_late

  instance :lp, PicoBEAM.RTL.LitPool,
    clk: :clk,
    rd_addr: :lp_addr,
    rd_data: :lp_q,
    rd2_addr: :lp2_addr,
    rd2_data: :lp2_q,
    wr_en: :ld_pool_en,
    wr_addr: :ld_pool_addr,
    wr_data: :ld_pool_data

  instance :hp, PicoBEAM.RTL.Heap,
    clk: :clk,
    rst: :rst,
    cmd_en: :hp_en,
    cmd: :hp_cmd,
    pa: :hp_pa,
    pb: :hp_pb,
    i8: :hp_i8,
    rd_late: :hp_rd_late,
    fault: :hp_f,
    fault_reason: :hp_fr,
    hp_out: :hp_hp,
    heap_full: :hp_full,
    b_en: 1,
    b_addr: :hpb_addr,
    b_wr0: :hpb_wr0,
    b_wr1: :hpb_wr1,
    b_d0: :hpb_d0,
    b_d1: :hpb_d1,
    space_out: :hpb_space,
    b_q0: :hp_bq0,
    b_q1: :hp_bq1,
    flip_en: :hp_flip,
    flip_aptr: :hp_flip_ap,
    flip_space: :hp_flip_sp

  # ---- `notes/40`: the collector and the thing that feeds it. Neither
  # decides when to run — that is the FSM above — and neither knows about
  # the other's half of the job: `RootWalker` knows where roots live and
  # nothing about Cheney; `Collector` knows Cheney and nothing about
  # windows, frames or seats.
  instance :col, PicoBEAM.RTL.Collector,
    clk: :clk,
    rst: :rst,
    start: :gc_start,
    from_space: :gc_from,
    start_hp: :hp_hp,
    busy: :cx_busy,
    done: :cx_done,
    to_hp: :cx_to_hp,
    overflow: :cx_ovf,
    root_en: :rk_root_en,
    root_word: :rk_root_word,
    root_ack: :cx_ack,
    root_new: :cx_new,
    roots_done: :rk_roots_done,
    h_addr: :cx_haddr,
    h_wr0: :cx_wr0,
    h_wr1: :cx_wr1,
    h_d0: :cx_d0,
    h_d1: :cx_d1,
    h_q0: :hp_bq0,
    h_q1: :hp_bq1

  instance :walk, PicoBEAM.RTL.RootWalker,
    clk: :clk,
    rst: :rst,
    start: :gc_start,
    one_en: :rk_one_en,
    one_slot: :rk_one_slot,
    busy: :rk_busy,
    done: :rk_done,
    root_en: :rk_root_en,
    root_word: :rk_root_word,
    root_ack: :cx_ack,
    root_new: :cx_new,
    roots_done: :rk_roots_done,
    live_vec: :live_vec,
    seat_val: :seat_val,
    seat_slot0: :slot0,
    seat_slot1: :slot1,
    seat_slot2: :slot2,
    seat_slot3: :slot3,
    rw_ctx: :rk_ctx,
    rw_stg: :rk_stg,
    rw_addr: :rk_addr,
    rw_q: :rw_rd0,
    rw_we: :rk_we,
    rw_data: :rk_data,
    sv_en: :rk_sv_en,
    sv_slot: :rk_sv_slot,
    sv_idx: :rk_sv_idx,
    sv_wr: :rk_sv_wr,
    sv_data: :rk_sv_data,
    sv_q: :sv_gc_q,
    frm_en: :rk_fr_en,
    frm_slot: :rk_fr_slot,
    frm_depth: :rk_fr_depth,
    frm_idx: :rk_fr_idx,
    frm_wr: :rk_fr_wr,
    frm_data: :rk_fr_data,
    frm_q: :fr_gc_q,
    frm_qslot: :rk_fr_qslot,
    frm_qdepth: :x_depth

  instance :ser, PicoBEAM.RTL.SerUnit,
    clk: :clk,
    rst: :rst,
    start: :ser_start,
    term: :ser_term,
    busy: :ser_busy,
    done: :ser_done,
    fault: :ser_fault,
    fault_reason: :ser_freason,
    count: :ser_count,
    counted: :ser_counted,
    go_emit: :ser_go_emit,
    abort: :ser_abort,
    stall: :ser_stall,
    h_addr: :ser_haddr,
    h_q0: :hp_bq0,
    h_q1: :hp_bq1,
    emit: :ser_emit,
    emit_word: :ser_word,
    root_arity: :ser_arity,
    root_first: :ser_first

  instance :alu0, PicoBEAM.RTL.Alu,
    clk: :clk,
    sel: :c0_sel,
    a: :rw_rd0,
    b: :rw_rd1,
    tag_imm: :rb0,
    imm: :imm0,
    y: :alu0_y,
    fault: :alu0_f,
    fault_reason: :alu0_fr

  instance :alu1, PicoBEAM.RTL.Alu,
    clk: :clk,
    sel: :c1_sel,
    a: :rw_rd2,
    b: :rw_rd3,
    tag_imm: :rb1,
    imm: :imm1,
    y: :alu1_y,
    fault: :alu1_f,
    fault_reason: :alu1_fr

  instance :alu2, PicoBEAM.RTL.Alu,
    clk: :clk,
    sel: :c2_sel,
    a: :rw_rd4,
    b: :rw_rd5,
    tag_imm: :rb2,
    imm: :imm2,
    y: :alu2_y,
    fault: :alu2_f,
    fault_reason: :alu2_fr

  instance :frames, PicoBEAM.RTL.FrameRamProc,
    clk: :clk,
    rst: :rst,
    push_en: :call_commit,
    push_slot: :push_slot,
    push_pc: :link_pc,
    push_dest: :f_cd,
    spill_valid: :spill_valid,
    spill_idx: :spill_idx,
    spill_data: :spill_data,
    pop_en: :pop_en,
    pop_slot: :pop_slot,
    fill_en: :fill_en,
    fill_idx: :fill_idx,
    fill_slot: :fill_slot,
    fill_data: :fr_fill_d,
    ret_pc_out: :fr_ret_pc,
    ret_dest_out: :fr_ret_dest,
    overflow: :fr_ovf,
    underflow: :fr_unf,
    depth_out: :fr_depth,
    q_slot: :gw_q_slot,
    q_depth: :x_depth,
    pop_abs: :pop_abs,
    pop_to: :pop_to,
    gc_en: :rk_fr_en,
    gc_slot: :rk_fr_slot,
    gc_depth: :rk_fr_depth,
    gc_idx: :rk_fr_idx,
    gc_wr: :rk_fr_wr,
    gc_data: :rk_fr_data,
    gc_q: :fr_gc_q
end
