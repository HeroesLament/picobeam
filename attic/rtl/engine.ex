defmodule PicoBEAM.RTL.Engine do
  @moduledoc """
  M2 scaffold — one engine, one context: the component tree, wired.

  This is the structural top. Every block of `notes/03-architecture.md`'s
  engine has a component and the plumbing between them is real; the logic
  *inside* several of them is skeletal, and the opcode table that turns
  `Decode`'s raw bytes into ALU micro-ops, register strobes and sequencer
  classification is deliberately absent (see below).

      Sequencer ──pc──▶ CodeMem ──bundle──▶ Decode ──fields──┐
          ▲                                                  ▼
          │ faults/class            ┌── ra/rb ──▶ RegWindow ──▶ Alu x3 ─┐
          └────────────────────────┴──── y/fault ◀──────────────────────┘
                     RegWindow ──spill──▶ FrameRam ──fill──▶ (wr port 0)
                     Heap (port A bump/rd/wr; port B tied off till M4/M5)
                     LitPool (ldc)

  ## Opcode-table pass (2026-08-22): the table is LIVE

  `PicoBEAM.Encoding` fixes the binary numbering; `Classify` (one per
  slot) mirrors it. Wired in this pass:

  * **Classification** — grp/sel nibble slices per slot; `is_call`/
    `is_ret`/`is_halt`/jump aggregation is an OR across slots (the
    bundle contract allows at most one system op, so the aggregate is
    one-hot by construction and the pc-target mux is a one-hot sum).
  * **Write-back** — per-slot `wr_en = wr_alu AND exec_en`, ALU `y`
    into the slot's write port, `rd` from f1. Covers ALU group + `ldi`
    + `ldn` (Alu sels 12/13).
  * **rs_in_f1 read-address mux** — `bift`/`biff`/`ret`/`out`/
    `recv_waitt` carry their register in f1 (imm12 covers f2..f4), so
    the slot's ra-port address muxes from f1 for those ops.
  * **Conditional branches** — `bift`/`biff` compare the slot's ra-port
    word against the reserved TRUE/FALSE atom words (indices 14/15).

  ## Call/ret data-flow pass (2026-08-22): calls and returns are wired

  * **arg staging** — per-slot `arg_en = is_arg AND exec_en`; index from
    f1, value from the slot's ra port (the encoding puts rs in f2).
  * **call** — dest register captured as a one-hot sum over the slots'
    f1 fields; the link (`link_pc` = call bundle + 1, dest) rides
    `call_commit` into FrameRam's `rets` store, lockstep with the frame.
  * **ret** — the return value is LATCHED at exec (`ret_val`, one-hot
    over the ra ports) before the fill overwrites the window; the fill
    stream writes through window port 0 one cycle behind the sequencer's
    indices (frame RAM reads are sync); the final `dest_wr` cycle writes
    `ret_val` to `FrameRam.ret_dest_out`. Port 0's three sources (ALU
    write-back, delayed fill, dest write) are phase-disjoint, so the mux
    is a one-hot sum.
  * **tailcall** — `op_tail` promotes staging without a push; to the
    sequencer it is just a jump.

  Contract note surfaced by this pass: an `arg` or register write in the
  SAME bundle as `tailcall` is suppressed by the window-reuse promote
  (the model declares them moot; the hardware makes them so). `Asm`
  should eventually reject `arg`+`call`/`tailcall` sharing a bundle —
  logged in `notes/15`.

  ## Heap-op pass (2026-08-22): the heap datapath is wired

  The (single, rule-2) heap slot's operands gather one-hot into the
  cell-addressed `Heap` unit — `cmd` is the op byte's low 3 bits
  verbatim; `pa`/`pb` are its ra/rb port words. Results, and `ldc`'s
  pool word, arrive one cycle late (sync reads) and land through window
  port 0 during the sequencer's `wb2` state, routed by exec-latched
  state (`hs_*`/`lc_*`). `lda` joined the ALU (sel 14). One late writer
  per bundle is the contract shape; the `lc_on` latch carries a
  not-heap guard so the port-0 sum stays one-hot regardless.

  ## Still deliberately missing

  * **`self`** — needs a process identity, which is M3's proc table.
  * **The image-loading path** into CodeMem/LitPool.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # -- loader side-door (drive while rst is held; notes/11's boot shape:
  # -- at M2 a top-level ROM streams in, at M8 the SD loader does)
  input :ld_code_en, 1
  input :ld_code_addr, 9
  input :ld_code_data, 72
  input :ld_pool_en, 1
  input :ld_pool_addr, 8
  input :ld_pool_data, 36

  # -- the observability port: `out rs` lands here (model's m.out)
  output :out_valid, 1
  output :out_data, 36

  output :halted, 1
  output :faulted, 1
  output :fault_reason, 8
  output :pc_dbg, 9
  # debug UART taps
  output :dbg_state, 4
  output :dbg_ready, 1
  output :dbg_fp, 6
  # the first two ret targets after reset, and a saturating ret count —
  # the surgical probe for "where did the ret actually jump?"
  output :dbg_rt1, 9
  output :dbg_rt2, 9
  output :dbg_rcnt, 4
  # the MOST RECENT ret target, and a saturating count of out pulses
  output :dbg_rtl, 9
  output :dbg_ocnt, 4
  # value-chain probes: the last ret_val byte written at dest_wr, and
  # saturating counts of NONZERO spill/fill data words — discriminates
  # "value lost in the ret chain" vs "spill/fill returns zeros"
  output :dbg_lrv, 8
  output :dbg_fnz, 4
  output :dbg_snz, 4
  # the FIRST ret's value (deepest return — fib's base case, expect 1)
  # and a saturating count of rets that carried a NONZERO value
  output :dbg_frv, 8
  output :dbg_rvnz, 4

  # ---- sequencer <-> code path
  wire :seq_pc, 9
  wire :seq_exec, 1
  wire :seq_callgo, 1
  wire :seq_fill_en, 1
  wire :seq_fill_idx, 4
  wire :seq_pop, 1
  wire :seq_target, 9
  wire :cm_bundle, 72

  # ---- decode fields
  wire :dc_op0, 8
  wire :dc_rd0, 4
  wire :dc_ra0, 4
  wire :dc_rb0, 4
  wire :dc_imm0, 12
  wire :dc_op1, 8
  wire :dc_rd1, 4
  wire :dc_ra1, 4
  wire :dc_rb1, 4
  wire :dc_imm1, 12
  wire :dc_op2, 8
  wire :dc_rd2, 4
  wire :dc_ra2, 4
  wire :dc_rb2, 4
  wire :dc_imm2, 12
  wire :dc_i80, 8
  wire :dc_i81, 8
  wire :dc_i82, 8

  # ---- register window
  wire :rw_rd0, 36
  wire :rw_rd1, 36
  wire :rw_rd2, 36
  wire :rw_rd3, 36
  wire :rw_rd4, 36
  wire :rw_rd5, 36
  wire :rw_ready, 1
  wire :rw_spill_v, 1
  wire :rw_spill_i, 4
  wire :rw_spill_d, 36

  # ---- ALUs
  wire :alu0_y, 36
  wire :alu0_f, 1
  wire :alu0_fr, 8
  wire :alu1_y, 36
  wire :alu1_f, 1
  wire :alu1_fr, 8
  wire :alu2_y, 36
  wire :alu2_f, 1
  wire :alu2_fr, 8
  wire :any_fault, 1
  wire :any_fault_r, 8

  # ---- frame RAM
  wire :fr_fill_d, 36
  wire :fr_fp, 6
  wire :fr_ovf, 1

  # ---- heap (cell-addressed micro-command unit)
  wire :hp_en, 1
  wire :hp_cmd, 3
  wire :hp_pa, 36
  wire :hp_pb, 36
  wire :hp_i8, 8
  wire :hp_late, 36
  wire :hp_f, 1
  wire :hp_fr, 8
  wire :hp_full, 1
  wire :hp_bq, 36
  wire :hp_hp, 8
  wire :any_heap, 1
  wire :any_ldc, 1
  wire :has_wb2w, 1
  wire :seq_wb2, 1
  wire :w2h, 1
  wire :w2l, 1
  wire :hs_wr_l, 1, init: 0
  wire :hs_rd_l, 4, init: 0
  wire :lc_on, 1, init: 0
  wire :lc_rd_l, 4, init: 0

  # ---- literal pool
  wire :lp_rd, 36
  wire :lp_addr, 8

  # ---- per-slot classification (mirrors PicoBEAM.Encoding)
  wire :cl0_grp, 4
  wire :cl0_sel, 4
  wire :cl0_wr, 1
  wire :cl0_wro, 1
  wire :cl0_rsf1, 1
  wire :cl0_jmp, 1
  wire :cl0_bift, 1
  wire :cl0_biff, 1
  wire :cl0_call, 1
  wire :cl0_tail, 1
  wire :cl0_ret, 1
  wire :cl0_arg, 1
  wire :cl0_halt, 1
  wire :cl0_sys, 1
  wire :cl0_heap, 1
  wire :cl0_ldc, 1
  wire :cl0_out, 1
  wire :cl1_grp, 4
  wire :cl1_sel, 4
  wire :cl1_wr, 1
  wire :cl1_wro, 1
  wire :cl1_rsf1, 1
  wire :cl1_jmp, 1
  wire :cl1_bift, 1
  wire :cl1_biff, 1
  wire :cl1_call, 1
  wire :cl1_tail, 1
  wire :cl1_ret, 1
  wire :cl1_arg, 1
  wire :cl1_halt, 1
  wire :cl1_sys, 1
  wire :cl1_heap, 1
  wire :cl1_ldc, 1
  wire :cl1_out, 1
  wire :cl2_grp, 4
  wire :cl2_sel, 4
  wire :cl2_wr, 1
  wire :cl2_wro, 1
  wire :cl2_rsf1, 1
  wire :cl2_jmp, 1
  wire :cl2_bift, 1
  wire :cl2_biff, 1
  wire :cl2_call, 1
  wire :cl2_tail, 1
  wire :cl2_ret, 1
  wire :cl2_arg, 1
  wire :cl2_halt, 1
  wire :cl2_sys, 1
  wire :cl2_heap, 1
  wire :cl2_ldc, 1
  wire :cl2_out, 1

  # ---- derived control / routing
  wire :ra_a0, 4
  wire :ra_a2, 4
  wire :ra_a4, 4
  wire :wb_en0, 1
  wire :wb_en1, 1
  wire :wb_en2, 1
  wire :br0_taken, 1
  wire :br1_taken, 1
  wire :br2_taken, 1
  wire :ctl0, 1
  wire :ctl1, 1
  wire :ctl2, 1
  wire :any_jump, 1
  wire :any_call, 1
  wire :any_ret, 1
  wire :any_halt, 1
  wire :any_tail, 1
  wire :tl_go, 1

  # ---- call/ret data flow
  wire :ag_en0, 1
  wire :ag_en1, 1
  wire :ag_en2, 1
  wire :call_dest, 4
  wire :ret_word, 36
  wire :ret_val, 36, init: 0
  wire :fillw_en, 1, init: 0
  wire :fillw_idx, 4, init: 0
  wire :seq_link, 9
  wire :seq_destwr, 1
  wire :fr_ret_pc, 9
  wire :fr_ret_dest, 4
  wire :w0_en, 1
  wire :w0_addr, 4
  wire :w0_data, 36
  wire :rt1, 9, init: 0
  wire :rt2, 9, init: 0
  wire :rcnt, 4, init: 0
  wire :rtl, 9, init: 0
  wire :ocnt, 4, init: 0
  wire :lrv, 8, init: 0
  wire :fnz, 4, init: 0
  wire :snz, 4, init: 0
  wire :frv, 8, init: 0
  wire :rvseen, 1, init: 0
  wire :rvnz, 4, init: 0
  wire :w1_en, 1
  wire :w1_data, 36
  wire :w2_en, 1
  wire :w2_data, 36

  comb do
    pc_dbg = seq_pc
    dbg_ready = rw_ready
    dbg_fp = fr_fp
    dbg_rt1 = rt1
    dbg_rt2 = rt2
    dbg_rcnt = rcnt
    dbg_rtl = rtl
    dbg_ocnt = ocnt
    dbg_lrv = lrv
    dbg_fnz = fnz
    dbg_snz = snz
    dbg_frv = frv
    dbg_rvnz = rvnz

    # heap / ldc presence and the wb2 handshake
    any_heap = bor(cl0_heap, bor(cl1_heap, cl2_heap))
    any_ldc = bor(cl0_ldc, bor(cl1_ldc, cl2_ldc))
    has_wb2w = bor(any_heap, any_ldc)

    # heap micro-command: operands one-hot over the (single) heap slot;
    # cmd is the op byte's low 3 bits verbatim (table construction)
    hp_en = band(any_heap, seq_exec)
    hp_cmd = cl0_heap * dc_op0[2..0] + cl1_heap * dc_op1[2..0] + cl2_heap * dc_op2[2..0]
    hp_pa = cl0_heap * rw_rd0 + cl1_heap * rw_rd2 + cl2_heap * rw_rd4
    hp_pb = cl0_heap * rw_rd1 + cl1_heap * rw_rd3 + cl2_heap * rw_rd5
    hp_i8 = cl0_heap * dc_i80 + cl1_heap * dc_i81 + cl2_heap * dc_i82

    # ldc: pool address from the (single) ldc slot's imm12 low byte
    lp_addr = cl0_ldc * dc_imm0[7..0] + cl1_ldc * dc_imm1[7..0] + cl2_ldc * dc_imm2[7..0]

    # out rs: rs rides f1 (rs_in_f1), so the value is on the ra port
    out_valid = band(bor(cl0_out, bor(cl1_out, cl2_out)), seq_exec)
    out_data = cl0_out * rw_rd0 + cl1_out * rw_rd2 + cl2_out * rw_rd4

    # fault priority: heap unit first, then slots in order
    any_fault = bor(bor(alu0_f, bor(alu1_f, alu2_f)), hp_f)
    any_fault_r =
      hp_f * hp_fr + band(bnot(hp_f), alu0_f) * alu0_fr +
        band(bnot(hp_f), band(bnot(alu0_f), alu1_f)) * alu1_fr +
        band(bnot(hp_f), band(bnot(alu0_f), band(bnot(alu1_f), alu2_f))) * alu2_fr

    # rs+imm shapes read through f1 (Classify.rs_in_f1); one 2:1 mux per
    # slot's ra port, only ever exercised by the bundle's one system op
    ra_a0 = cl0_rsf1 * dc_rd0 + bnot(cl0_rsf1) * dc_ra0
    ra_a2 = cl1_rsf1 * dc_rd1 + bnot(cl1_rsf1) * dc_ra1
    ra_a4 = cl2_rsf1 * dc_rd2 + bnot(cl2_rsf1) * dc_ra2

    # write-back only during the exec phase
    wb_en0 = band(cl0_wr, seq_exec)
    wb_en1 = band(cl1_wr, seq_exec)
    wb_en2 = band(cl2_wr, seq_exec)

    # bift/biff: the slot's ra-port word against the reserved TRUE (14)
    # and FALSE (15) atom words
    br0_taken = bor(band(cl0_bift, rw_rd0 == 0x10000000E), band(cl0_biff, rw_rd0 == 0x10000000F))
    br1_taken = bor(band(cl1_bift, rw_rd2 == 0x10000000E), band(cl1_biff, rw_rd2 == 0x10000000F))
    br2_taken = bor(band(cl2_bift, rw_rd4 == 0x10000000E), band(cl2_biff, rw_rd4 == 0x10000000F))

    # control aggregation — one-hot by the bundle contract (<=1 system op)
    ctl0 = bor(cl0_jmp, bor(br0_taken, cl0_call))
    ctl1 = bor(cl1_jmp, bor(br1_taken, cl1_call))
    ctl2 = bor(cl2_jmp, bor(br2_taken, cl2_call))
    any_jump = bor(bor(cl0_jmp, br0_taken), bor(bor(cl1_jmp, br1_taken), bor(cl2_jmp, br2_taken)))
    any_call = bor(cl0_call, bor(cl1_call, cl2_call))
    any_ret = bor(cl0_ret, bor(cl1_ret, cl2_ret))
    any_halt = bor(cl0_halt, bor(cl1_halt, cl2_halt))
    any_tail = bor(cl0_tail, bor(cl1_tail, cl2_tail))
    tl_go = band(any_tail, seq_exec)

    # pc target: one-hot sum across the slots' imm12[8:0]
    seq_target = ctl0 * dc_imm0[8..0] + ctl1 * dc_imm1[8..0] + ctl2 * dc_imm2[8..0]

    # arg staging: index from f1, value from the slot's ra port (rs is f2)
    ag_en0 = band(cl0_arg, seq_exec)
    ag_en1 = band(cl1_arg, seq_exec)
    ag_en2 = band(cl2_arg, seq_exec)

    # call dest register — one-hot over the slots' f1 fields
    call_dest = cl0_call * dc_rd0 + cl1_call * dc_rd1 + cl2_call * dc_rd2

    # ret's rs value, read through the rs_in_f1 mux on the slot's ra port
    ret_word = cl0_ret * rw_rd0 + cl1_ret * rw_rd2 + cl2_ret * rw_rd4

    # unified window write ports (RegWindowRam): each slot's op carries
    # at most one write — a result (to current) or an arg (to staging).
    # Port 0 additionally sums the phase-disjoint sources: the delayed
    # ret-fill stream, the dest write, and the two wb2 late writers
    # (heap result / pool word — one late writer per bundle by contract;
    # lc_on carries a not-heap guard so the sum stays one-hot anyway).
    w2h = band(seq_wb2, hs_wr_l)
    w2l = band(seq_wb2, lc_on)
    w0_en = bor(bor(wb_en0, ag_en0), bor(fillw_en, bor(seq_destwr, bor(w2h, w2l))))

    w0_addr =
      bor(wb_en0, ag_en0) * dc_rd0 + fillw_en * fillw_idx + seq_destwr * fr_ret_dest +
        w2h * hs_rd_l + w2l * lc_rd_l

    w0_data =
      wb_en0 * alu0_y + ag_en0 * rw_rd0 + fillw_en * fr_fill_d + seq_destwr * ret_val +
        w2h * hp_late + w2l * lp_rd

    w1_en = bor(wb_en1, ag_en1)
    w1_data = wb_en1 * alu1_y + ag_en1 * rw_rd2
    w2_en = bor(wb_en2, ag_en2)
    w2_data = wb_en2 * alu2_y + ag_en2 * rw_rd4
  end

  # the ret-value latch and the one-cycle fill-write delay (frame RAM
  # reads are sync: data for index N arrives while the sequencer already
  # presents N+1, so the window write trails the index by one cycle)
  on :clk do
    fillw_en = seq_fill_en
    fillw_idx = seq_fill_idx

    if band(any_ret, seq_exec) == 1 do
      ret_val = ret_word
    end

    # value-chain probes
    if seq_destwr == 1 do
      lrv = ret_val[7..0]

      if rvseen == 0 do
        frv = ret_val[7..0]
        rvseen = 1
      end

      if ret_val != 0 do
        if rvnz != 15 do
          rvnz = rvnz + 1
        end
      end
    end

    if band(fillw_en, fr_fill_d != 0) == 1 do
      if fnz != 15 do
        fnz = fnz + 1
      end
    end

    if band(rw_spill_v, rw_spill_d != 0) == 1 do
      if snz != 15 do
        snz = snz + 1
      end
    end

    # ret-target trace: latch the popped link on the dest-write cycle
    if seq_destwr == 1 do
      if rcnt == 0, do: rt1 = fr_ret_pc
      if rcnt == 1, do: rt2 = fr_ret_pc
      rtl = fr_ret_pc

      if rcnt != 15 do
        rcnt = rcnt + 1
      end
    end

    if band(bor(cl0_out, bor(cl1_out, cl2_out)), seq_exec) == 1 do
      if ocnt != 15 do
        ocnt = ocnt + 1
      end
    end

    if rst == 1 do
      rcnt = 0
      rt1 = 0
      rt2 = 0
      rtl = 0
      ocnt = 0
    end

    # wb2 routing state, latched at exec (every exec rewrites, so nothing
    # leaks across bundles). tset produces no register result.
    if seq_exec == 1 do
      hs_wr_l = band(any_heap, hp_cmd != 4)
      hs_rd_l = cl0_heap * dc_rd0 + cl1_heap * dc_rd1 + cl2_heap * dc_rd2
      lc_on = band(any_ldc, bnot(any_heap))
      lc_rd_l = cl0_ldc * dc_rd0 + cl1_ldc * dc_rd1 + cl2_ldc * dc_rd2
    end
  end

  instance :classify0, PicoBEAM.RTL.Classify,
    clk: :clk,
    op: :dc_op0,
    grp: :cl0_grp,
    alu_sel: :cl0_sel,
    wr_alu: :cl0_wr,
    wr_other: :cl0_wro,
    rs_in_f1: :cl0_rsf1,
    is_jmp: :cl0_jmp,
    is_bift: :cl0_bift,
    is_biff: :cl0_biff,
    is_call: :cl0_call,
    is_tail: :cl0_tail,
    is_ret: :cl0_ret,
    is_arg: :cl0_arg,
    is_halt: :cl0_halt,
    is_sys: :cl0_sys,
    is_heap: :cl0_heap,
    is_ldc: :cl0_ldc,
    is_out: :cl0_out

  instance :classify1, PicoBEAM.RTL.Classify,
    clk: :clk,
    op: :dc_op1,
    grp: :cl1_grp,
    alu_sel: :cl1_sel,
    wr_alu: :cl1_wr,
    wr_other: :cl1_wro,
    rs_in_f1: :cl1_rsf1,
    is_jmp: :cl1_jmp,
    is_bift: :cl1_bift,
    is_biff: :cl1_biff,
    is_call: :cl1_call,
    is_tail: :cl1_tail,
    is_ret: :cl1_ret,
    is_arg: :cl1_arg,
    is_halt: :cl1_halt,
    is_sys: :cl1_sys,
    is_heap: :cl1_heap,
    is_ldc: :cl1_ldc,
    is_out: :cl1_out

  instance :classify2, PicoBEAM.RTL.Classify,
    clk: :clk,
    op: :dc_op2,
    grp: :cl2_grp,
    alu_sel: :cl2_sel,
    wr_alu: :cl2_wr,
    wr_other: :cl2_wro,
    rs_in_f1: :cl2_rsf1,
    is_jmp: :cl2_jmp,
    is_bift: :cl2_bift,
    is_biff: :cl2_biff,
    is_call: :cl2_call,
    is_tail: :cl2_tail,
    is_ret: :cl2_ret,
    is_arg: :cl2_arg,
    is_halt: :cl2_halt,
    is_sys: :cl2_sys,
    is_heap: :cl2_heap,
    is_ldc: :cl2_ldc,
    is_out: :cl2_out

  instance :seq, PicoBEAM.RTL.Sequencer,
    clk: :clk,
    rst: :rst,
    is_jump: :any_jump,
    is_call: :any_call,
    is_ret: :any_ret,
    is_halt: :any_halt,
    fault_in: :any_fault,
    fault_reason_in: :any_fault_r,
    pc_target: :seq_target,
    has_wb2: :has_wb2w,
    window_ready: :rw_ready,
    ret_pc_in: :fr_ret_pc,
    pc: :seq_pc,
    exec_en: :seq_exec,
    call_commit: :seq_callgo,
    fill_en: :seq_fill_en,
    fill_idx: :seq_fill_idx,
    pop_en: :seq_pop,
    link_pc: :seq_link,
    dest_wr: :seq_destwr,
    wb2_en: :seq_wb2,
    sstate: :dbg_state,
    halted: :halted,
    faulted: :faulted,
    fault_reason: :fault_reason

  instance :code_mem, PicoBEAM.RTL.CodeMem,
    clk: :clk,
    rd_addr: :seq_pc,
    rd_bundle: :cm_bundle,
    wr_en: :ld_code_en,
    wr_addr: :ld_code_addr,
    wr_data: :ld_code_data

  instance :decode, PicoBEAM.RTL.Decode,
    clk: :clk,
    bundle: :cm_bundle,
    op0: :dc_op0,
    rd0: :dc_rd0,
    ra0: :dc_ra0,
    rb0: :dc_rb0,
    imm0: :dc_imm0,
    i8_0: :dc_i80,
    op1: :dc_op1,
    rd1: :dc_rd1,
    ra1: :dc_ra1,
    rb1: :dc_rb1,
    imm1: :dc_imm1,
    i8_1: :dc_i81,
    op2: :dc_op2,
    rd2: :dc_rd2,
    ra2: :dc_ra2,
    rb2: :dc_rb2,
    imm2: :dc_imm2,
    i8_2: :dc_i82

  instance :windows, PicoBEAM.RTL.RegWindowRam,
    clk: :clk,
    rst: :rst,
    ctx: 0,
    rd_addr0: :ra_a0,
    rd_addr1: :dc_rb0,
    rd_addr2: :ra_a2,
    rd_addr3: :dc_rb1,
    rd_addr4: :ra_a4,
    rd_addr5: :dc_rb2,
    rd_data0: :rw_rd0,
    rd_data1: :rw_rd1,
    rd_data2: :rw_rd2,
    rd_data3: :rw_rd3,
    rd_data4: :rw_rd4,
    rd_data5: :rw_rd5,
    w_en0: :w0_en,
    w_stg0: :ag_en0,
    w_addr0: :w0_addr,
    w_data0: :w0_data,
    w_en1: :w1_en,
    w_stg1: :ag_en1,
    w_addr1: :dc_rd1,
    w_data1: :w1_data,
    w_en2: :w2_en,
    w_stg2: :ag_en2,
    w_addr2: :dc_rd2,
    w_data2: :w2_data,
    op_call: :seq_callgo,
    op_tail: :tl_go,
    spill_valid: :rw_spill_v,
    spill_idx: :rw_spill_i,
    spill_data: :rw_spill_d,
    ready: :rw_ready

  instance :alu0, PicoBEAM.RTL.Alu,
    clk: :clk,
    sel: :cl0_sel,
    a: :rw_rd0,
    b: :rw_rd1,
    tag_imm: :dc_rb0,
    imm: :dc_imm0,
    y: :alu0_y,
    fault: :alu0_f,
    fault_reason: :alu0_fr

  instance :alu1, PicoBEAM.RTL.Alu,
    clk: :clk,
    sel: :cl1_sel,
    a: :rw_rd2,
    b: :rw_rd3,
    tag_imm: :dc_rb1,
    imm: :dc_imm1,
    y: :alu1_y,
    fault: :alu1_f,
    fault_reason: :alu1_fr

  instance :alu2, PicoBEAM.RTL.Alu,
    clk: :clk,
    sel: :cl2_sel,
    a: :rw_rd4,
    b: :rw_rd5,
    tag_imm: :dc_rb2,
    imm: :dc_imm2,
    y: :alu2_y,
    fault: :alu2_f,
    fault_reason: :alu2_fr

  instance :frame_ram, PicoBEAM.RTL.FrameRam,
    clk: :clk,
    rst: :rst,
    spill_valid: :rw_spill_v,
    spill_idx: :rw_spill_i,
    spill_data: :rw_spill_d,
    push_en: :seq_callgo,
    ret_pc_in: :seq_link,
    ret_dest_in: :call_dest,
    fill_en: :seq_fill_en,
    fill_idx: :seq_fill_idx,
    fill_data: :fr_fill_d,
    pop_en: :seq_pop,
    ret_pc_out: :fr_ret_pc,
    ret_dest_out: :fr_ret_dest,
    fp_out: :fr_fp,
    overflow: :fr_ovf

  instance :heap, PicoBEAM.RTL.Heap,
    clk: :clk,
    rst: :rst,
    cmd_en: :hp_en,
    cmd: :hp_cmd,
    pa: :hp_pa,
    pb: :hp_pb,
    i8: :hp_i8,
    rd_late: :hp_late,
    fault: :hp_f,
    fault_reason: :hp_fr,
    hp_out: :hp_hp,
    heap_full: :hp_full,
    b_en: 0,
    b_wr: 0,
    b_addr: 0,
    b_data: 0,
    b_q: :hp_bq,
    flip_en: 0

  instance :lit_pool, PicoBEAM.RTL.LitPool,
    clk: :clk,
    rd_addr: :lp_addr,
    rd_data: :lp_rd,
    wr_en: :ld_pool_en,
    wr_addr: :ld_pool_addr,
    wr_data: :ld_pool_data
end
