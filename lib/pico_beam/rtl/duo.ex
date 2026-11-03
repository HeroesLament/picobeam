defmodule PicoBEAM.RTL.Duo do
  @moduledoc """
  Two engines, one ring, one image — the harness cross-engine spawn is
  tested in (`notes/49`).

  `tb_ring2` cannot be that test. It boots two DIFFERENT images, because
  a message only needs the two ends to agree about a wire format. A
  spawn needs them to agree about CODE: engine 0 sends an entry pc and
  engine 1 jumps to it, so both engines have to be holding the same
  program at the same addresses. This harness loads one image into both.

  It exists as a component rather than as Verilog in the testbench for
  one reason: `N_ENG` is a `param`, and EHDL folds a param at
  elaboration into a `localparam` that Verilog cannot override. The
  engine count has to be chosen on the `instance`, which means it has
  to be chosen in EHDL — so the two-engine configuration is a module,
  and the testbench drives it.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # one image, both engines
  input :ld_code_en, 1
  input :ld_code_addr, 12
  input :ld_code_data, 72
  input :ld_pool_en, 1
  input :ld_pool_addr, 8
  input :ld_pool_data, 36

  input :boot0, 1
  input :boot_pc0, 12
  input :boot1, 1
  input :boot_pc1, 12

  output :ov0, 1
  output :od0, 36
  output :ov1, 1
  output :od1, 36
  output :idle0, 1
  output :idle1, 1
  output :flt0, 1
  output :flt1, 1
  output :fr0, 8
  output :fr1, 8
  output :fs0, 5
  output :fs1, 5
  output :sp0, 12
  output :sp1, 12
  output :dt0, 12
  output :dt1, 12
  output :occ0, 6
  output :occ1, 6
  output :halted, 1

  wire :a_en, 1
  wire :a_head, 1
  wire :a_kind, 4
  wire :a_deng, 4
  wire :a_word, 36
  wire :a_len, 7
  wire :a_ready, 1
  wire :a_valid, 1
  wire :a_rhead, 1
  wire :a_rkind, 4
  wire :a_rdeng, 4
  wire :a_rword, 36
  wire :a_rlen, 7
  wire :a_pop, 1

  wire :b_en, 1
  wire :b_head, 1
  wire :b_kind, 4
  wire :b_deng, 4
  wire :b_word, 36
  wire :b_len, 7
  wire :b_ready, 1
  wire :b_valid, 1
  wire :b_rhead, 1
  wire :b_rkind, 4
  wire :b_rdeng, 4
  wire :b_rword, 36
  wire :b_rlen, 7
  wire :b_pop, 1

  wire :nm0_qn, 16
  wire :nm0_qh, 1
  wire :nm0_qe, 4
  wire :nm0_qs, 5
  wire :nm0_qr, 22
  wire :nm0_we, 4
  wire :nm0_ws, 5
  wire :nm0_wr, 22
  wire :nm0_wen, 1
  wire :nm0_tk, 1
  wire :nm0_pt, 1
  wire :nm0_fl, 1
  wire :nm0_clr, 1
  wire :nm0_die, 1
  wire :nm0_dpid, 36
  wire :nm0_dslot, 5
  wire :nm0_dser, 22
  wire :nm0_ps, 5
  wire :nm0_pst, 2
  wire :nm0_pser, 22
  wire :nm1_qn, 16
  wire :nm1_qh, 1
  wire :nm1_qe, 4
  wire :nm1_qs, 5
  wire :nm1_qr, 22
  wire :nm1_we, 4
  wire :nm1_ws, 5
  wire :nm1_wr, 22
  wire :nm1_wen, 1
  wire :nm1_tk, 1
  wire :nm1_pt, 1
  wire :nm1_fl, 1
  wire :nm1_clr, 1
  wire :nm1_die, 1
  wire :nm1_dpid, 36
  wire :nm1_dslot, 5
  wire :nm1_dser, 22
  wire :nm1_ps, 5
  wire :nm1_pst, 2
  wire :nm1_pser, 22
  wire :h0, 1
  wire :h1, 1
  wire :vm_halt, 1

  comb do
    # `notes/33` — `erlang:halt/0` stops the RUNTIME, and the runtime is
    # both engines. A sideband, not a ring packet.
    vm_halt = bor(h0, h1)
    halted = vm_halt
    nm0_dslot = nm0_dpid[26..22]
    nm0_dser = nm0_dpid[21..0]
    nm1_dslot = nm1_dpid[26..22]
    nm1_dser = nm1_dpid[21..0]
  end

  # `notes/53` — the node registry: ONE dual-ported CAM, an interface
  # per engine, aliveness probes cross-wired engine-to-engine
  instance :names, PicoBEAM.RTL.NameTable,
    clk: :clk,
    rst: :rst,
    q_name: :nm0_qn,
    q_hit: :nm0_qh,
    q_eng: :nm0_qe,
    q_slot: :nm0_qs,
    q_serial: :nm0_qr,
    w_name: :nm0_qn,
    w_eng: :nm0_we,
    w_slot: :nm0_ws,
    w_serial: :nm0_wr,
    w_en: :nm0_wen,
    name_taken: :nm0_tk,
    pid_taken: :nm0_pt,
    table_full: :nm0_fl,
    clr_en: :nm0_clr,
    clr_name: :nm0_qn,
    die_en: :nm0_die,
    die_eng: 0,
    die_slot: :nm0_dslot,
    die_serial: :nm0_dser,
    q2_name: :nm1_qn,
    q2_hit: :nm1_qh,
    q2_eng: :nm1_qe,
    q2_slot: :nm1_qs,
    q2_serial: :nm1_qr,
    w2_name: :nm1_qn,
    w2_eng: :nm1_we,
    w2_slot: :nm1_ws,
    w2_serial: :nm1_wr,
    w2_en: :nm1_wen,
    name_taken2: :nm1_tk,
    pid_taken2: :nm1_pt,
    table_full2: :nm1_fl,
    clr2_en: :nm1_clr,
    clr2_name: :nm1_qn,
    die2_en: :nm1_die,
    die2_eng: 1,
    die2_slot: :nm1_dslot,
    die2_serial: :nm1_dser

  instance :link_ab, PicoBEAM.RTL.RingLink,
    clk: :clk,
    rst: :rst,
    w_en: :a_en,
    w_head: :a_head,
    w_kind: :a_kind,
    w_deng: :a_deng,
    w_word: :a_word,
    w_len: :a_len,
    w_ready: :a_ready,
    r_valid: :a_valid,
    r_head: :a_rhead,
    r_kind: :a_rkind,
    r_deng: :a_rdeng,
    r_word: :a_rword,
    r_len: :a_rlen,
    r_pop: :a_pop

  instance :link_ba, PicoBEAM.RTL.RingLink,
    clk: :clk,
    rst: :rst,
    w_en: :b_en,
    w_head: :b_head,
    w_kind: :b_kind,
    w_deng: :b_deng,
    w_word: :b_word,
    w_len: :b_len,
    w_ready: :b_ready,
    r_valid: :b_valid,
    r_head: :b_rhead,
    r_kind: :b_rkind,
    r_deng: :b_rdeng,
    r_word: :b_rword,
    r_len: :b_rlen,
    r_pop: :b_pop

  instance :eng0, PicoBEAM.RTL.BarrelEngine,
    N_ENG: 2,
    clk: :clk,
    rst: :rst,
    eng_id: 0,
    ld_code_en: :ld_code_en,
    ld_code_addr: :ld_code_addr,
    ld_code_data: :ld_code_data,
    ld_pool_en: :ld_pool_en,
    ld_pool_addr: :ld_pool_addr,
    ld_pool_data: :ld_pool_data,
    boot_en: :boot0,
    boot_pc: :boot_pc0,
    halt_in: :vm_halt,
    halt_req: :h0,
    ring_w_en: :a_en,
    ring_w_head: :a_head,
    ring_w_kind: :a_kind,
    ring_w_deng: :a_deng,
    ring_w_word: :a_word,
    ring_w_len: :a_len,
    ring_w_ready: :a_ready,
    ring_r_valid: :b_valid,
    ring_r_head: :b_rhead,
    ring_r_kind: :b_rkind,
    ring_r_deng: :b_rdeng,
    ring_r_word: :b_rword,
    ring_r_len: :b_rlen,
    ring_r_pop: :b_pop,
    nm_q_name: :nm0_qn,
    nm_q_hit: :nm0_qh,
    nm_q_eng: :nm0_qe,
    nm_q_slot: :nm0_qs,
    nm_q_serial: :nm0_qr,
    nm_name_taken: :nm0_tk,
    nm_pid_taken: :nm0_pt,
    nm_full: :nm0_fl,
    nm_w_en: :nm0_wen,
    nm_w_eng: :nm0_we,
    nm_w_slot: :nm0_ws,
    nm_w_serial: :nm0_wr,
    nm_clr_en: :nm0_clr,
    nm_die: :nm0_die,
    nm_die_pid: :nm0_dpid,
    nm_probe_slot: :nm0_ps,
    nm_probe_state: :nm0_pst,
    nm_probe_serial: :nm0_pser,
    peer_probe_slot: :nm1_ps,
    peer_probe_state: :nm1_pst,
    peer_probe_serial: :nm1_pser,
    out_valid: :ov0,
    out_data: :od0,
    idle: :idle0,
    faulted: :flt0,
    fault_reason: :fr0,
    fault_slot: :fs0,
    dbg_spawns: :sp0,
    dbg_deaths: :dt0,
    dbg_occ: :occ0

  instance :eng1, PicoBEAM.RTL.BarrelEngine,
    N_ENG: 2,
    clk: :clk,
    rst: :rst,
    eng_id: 1,
    ld_code_en: :ld_code_en,
    ld_code_addr: :ld_code_addr,
    ld_code_data: :ld_code_data,
    ld_pool_en: :ld_pool_en,
    ld_pool_addr: :ld_pool_addr,
    ld_pool_data: :ld_pool_data,
    boot_en: :boot1,
    boot_pc: :boot_pc1,
    halt_in: :vm_halt,
    halt_req: :h1,
    ring_w_en: :b_en,
    ring_w_head: :b_head,
    ring_w_kind: :b_kind,
    ring_w_deng: :b_deng,
    ring_w_word: :b_word,
    ring_w_len: :b_len,
    ring_w_ready: :b_ready,
    ring_r_valid: :a_valid,
    ring_r_head: :a_rhead,
    ring_r_kind: :a_rkind,
    ring_r_deng: :a_rdeng,
    ring_r_word: :a_rword,
    ring_r_len: :a_rlen,
    ring_r_pop: :a_pop,
    nm_q_name: :nm1_qn,
    nm_q_hit: :nm1_qh,
    nm_q_eng: :nm1_qe,
    nm_q_slot: :nm1_qs,
    nm_q_serial: :nm1_qr,
    nm_name_taken: :nm1_tk,
    nm_pid_taken: :nm1_pt,
    nm_full: :nm1_fl,
    nm_w_en: :nm1_wen,
    nm_w_eng: :nm1_we,
    nm_w_slot: :nm1_ws,
    nm_w_serial: :nm1_wr,
    nm_clr_en: :nm1_clr,
    nm_die: :nm1_die,
    nm_die_pid: :nm1_dpid,
    nm_probe_slot: :nm1_ps,
    nm_probe_state: :nm1_pst,
    nm_probe_serial: :nm1_pser,
    peer_probe_slot: :nm0_ps,
    peer_probe_state: :nm0_pst,
    peer_probe_serial: :nm0_pser,
    out_valid: :ov1,
    out_data: :od1,
    idle: :idle1,
    faulted: :flt1,
    fault_reason: :fr1,
    fault_slot: :fs1,
    dbg_spawns: :sp1,
    dbg_deaths: :dt1,
    dbg_occ: :occ1
end
