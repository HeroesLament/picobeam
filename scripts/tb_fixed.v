// Fixed-point testbench — the integrated BarrelEngine running the
// cubic Hermite kernel from notes/20, gates against the reference
// model.
//
//   scripts/run_tbs.sh tb_fixed
//
//   cd _emit/m3 && iverilog -o tbfx.vvp ../../scripts/tb_fixed.v \
//     barrel_engine.v barrel_seq.v seat_unit.v proc_table.v run_queue.v \
//     reg_window_ctx.v frame_ram_proc.v code_mem.v decode.v classify.v alu.v \
//     && vvp tb8.vvp
//
// The expectation is not written here. `mk_fixed.exs` runs the same
// program on `machine.ex` and writes ITS outputs to fixed_expect.hex,
// so this compares gates against the model rather than against anyone's
// arithmetic. Five ticks of a Q12 Hermite segment: signed mul building
// constants past ldi's 12-bit immediate, mulsr at Q12 with both signs,
// signed add/sub crossing zero, and a call/ret with five staged args.
//
// Prints __FIXED_OK__ on full success.

`timescale 1ns/1ps

// The image and its model-derived expectation are macros so the same
// harness serves any straight-line `out` program: -DIMG/-DEXP.
`ifndef IMG
  `define IMG "fixed.hex"
`endif
`ifndef EXP
  `define EXP "fixed_expect.hex"
`endif
// -DPOOL="...hex" loads a literal pool through the engine's side-door.
// -DWANT_FAULT=n expects the process to DIE with reserved reason n
// (`fail` is an exit the program asked for, so "no faults" is the
// wrong assertion for an image that ends in one).
// -DCYCLES=n raises the run cap. 40,000 covers every program that was
// written before there was a collector; `gcloop` runs four hundred
// iterations through twelve collections and needs more.
`ifndef CYCLES
  `define CYCLES 40000
`endif
`ifndef WANT_FAULT
  `define WANT_FAULT -1
`endif
// -DWANT_FAULT_COUNT=n asserts HOW MANY processes died abnormally.
// `faulted` alone is sticky and machine-wide, so it cannot tell one
// supervised child dying from a crash loop; the count can, and it is
// the assertion that makes `WANT_FAULT` mean something in a program
// that is SUPPOSED to have a death in it.
`ifndef WANT_FAULT_COUNT
  `define WANT_FAULT_COUNT -1
`endif
// -DWANT_DEATHS / -DWANT_OCC assert the population afterwards, which
// is how a LINK is observed: nothing the surviving processes print can
// tell you that a peer was taken down by a signal rather than by
// running off its own end.
`ifndef WANT_DEATHS
  `define WANT_DEATHS -1
`endif
`ifndef WANT_OCC
  `define WANT_OCC -1
`endif
// -DWANT_PT_REASON/-DWANT_PT_SLOT read the reason ProcTable RECORDED
// for a slot. A process killed by a signal did not fault at X, so the
// engine's `fault_reason` — which reports the X stage — has nothing to
// say about it; the reason it died of is the one written into its
// table entry when it was freed.
`ifndef WANT_PT_REASON
  `define WANT_PT_REASON -1
`endif
`ifndef WANT_PT_SLOT
  `define WANT_PT_SLOT 0
`endif
// -DWANT_MB_HASH/-DWANT_MB_LEN inspect the message a signal LEFT in a
// mailbox. Until the deserialiser is in the engine a program can be
// woken by an {'EXIT', ...} or {'DOWN', ...} but cannot read it, so
// "the right message arrived" has to be asserted from outside: the
// head entry's shape hash and flit count say which shape it is and
// that all of it landed.
`ifndef WANT_MB_HASH
  `define WANT_MB_HASH -1
`endif
`ifndef WANT_MB_LEN
  `define WANT_MB_LEN 0
`endif
`ifndef WANT_MB_SLOT
  `define WANT_MB_SLOT 0
`endif
// -DWANT_IDLE asserts the machine STOPPED, which is not the same as
// every process having finished. `erlang:halt/0` freezes the whole VM
// (notes/33), so `idle` goes high with a live process still sitting
// there — and a machine that only exited a single process would still
// be running its children here.
`ifndef WANT_IDLE
  `define WANT_IDLE 0
`endif

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg ld_en = 0; reg [8:0] ld_addr = 0; reg [71:0] ld_data = 0;
  reg ld_pen = 0; reg [7:0] ld_paddr = 0; reg [35:0] ld_pdata = 0;
  reg [35:0] poolimg [0:255];
  reg boot_en = 0; reg [8:0] boot_pc = 0;

  wire out_valid; wire [35:0] out_data;
  wire idle, faulted; wire [7:0] fault_reason;
  wire [4:0] fault_slot; wire [7:0] fault_count;
  wire [11:0] dbg_sends, dbg_recvs;
  wire [5:0] dbg_scan;
  wire [5:0] dbg_occ, dbg_qcount;
  wire [7:0] dbg_swaps, dbg_spawns, dbg_deaths;
  wire [1:0] dbg_x_seat; wire dbg_x_en; wire [8:0] dbg_pc;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;

  // notes/53: the registry is a NODE unit now — the single-engine
  // harness supplies one, interface A wired, interface B tied off.
  wire [15:0] nm_qn;
  wire nm_qh; wire [3:0] nm_qe; wire [4:0] nm_qs; wire [21:0] nm_qr;
  wire [3:0] nm_we; wire [4:0] nm_ws; wire [21:0] nm_wr;
  wire nm_wen, nm_tk, nm_pt, nm_fl, nm_clr, nm_die;
  wire [35:0] nm_dpid;
  wire [4:0] nm_ps;

  name_table names(.clk(clk), .rst(rst),
    .q_name(nm_qn), .q_hit(nm_qh), .q_eng(nm_qe), .q_slot(nm_qs), .q_serial(nm_qr),
    .w_name(nm_qn), .w_eng(nm_we), .w_slot(nm_ws), .w_serial(nm_wr), .w_en(nm_wen),
    .name_taken(nm_tk), .pid_taken(nm_pt), .table_full(nm_fl),
    .clr_en(nm_clr), .clr_name(nm_qn),
    .die_en(nm_die), .die_eng(4'd0), .die_slot(nm_dpid[26:22]), .die_serial(nm_dpid[21:0]),
    .q2_name(16'd0), .w2_name(16'd0), .w2_eng(4'd0), .w2_slot(5'd0),
    .w2_serial(22'd0), .w2_en(1'b0), .clr2_en(1'b0), .clr2_name(16'd0),
    .die2_en(1'b0), .die2_eng(4'd0), .die2_slot(5'd0), .die2_serial(22'd0));

  barrel_engine eng(.clk(clk), .rst(rst),
    .nm_q_name(nm_qn), .nm_q_hit(nm_qh), .nm_q_eng(nm_qe), .nm_q_slot(nm_qs),
    .nm_q_serial(nm_qr), .nm_name_taken(nm_tk), .nm_pid_taken(nm_pt), .nm_full(nm_fl),
    .nm_w_en(nm_wen), .nm_w_eng(nm_we), .nm_w_slot(nm_ws), .nm_w_serial(nm_wr),
    .nm_clr_en(nm_clr), .nm_die(nm_die), .nm_die_pid(nm_dpid),
    .nm_probe_slot(nm_ps), .nm_probe_state(2'd0), .nm_probe_serial(22'd0),
    .peer_probe_slot(5'd0),
    // notes/33: one engine here, so the VM-wide halt has nobody to tell
    .halt_in(1'b0), .halt_req(),
    .eng_id(4'd0),
    .ring_w_en(), .ring_w_head(), .ring_w_kind(), .ring_w_deng(),
    .ring_w_word(), .ring_w_len(), .ring_w_ready(1'b1),
    .ring_r_valid(1'b0), .ring_r_head(1'b0), .ring_r_kind(4'd0),
    .ring_r_deng(4'd0), .ring_r_word(36'd0),
    .ring_r_len(7'd0), .ring_r_pop(),
    .ld_code_en(ld_en), .ld_code_addr(ld_addr), .ld_code_data(ld_data),
    .ld_pool_en(ld_pen), .ld_pool_addr(ld_paddr), .ld_pool_data(ld_pdata),
    .boot_en(boot_en), .boot_pc(boot_pc),
    .out_valid(out_valid), .out_data(out_data),
    .idle(idle), .faulted(faulted), .fault_reason(fault_reason),
    .fault_slot(fault_slot), .fault_count(fault_count),
    .dbg_sends(dbg_sends), .dbg_recvs(dbg_recvs), .dbg_scan(dbg_scan),
    .dbg_occ(dbg_occ), .dbg_qcount(dbg_qcount), .dbg_swaps(dbg_swaps),
    .dbg_spawns(dbg_spawns), .dbg_deaths(dbg_deaths),
    .dbg_x_seat(dbg_x_seat), .dbg_x_en(dbg_x_en), .dbg_pc(dbg_pc),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  reg [71:0] image [0:511];
  integer errors = 0, i, n_out = 0;
  reg [35:0] outs [0:31];
  integer seen [0:15];

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

`ifdef TRACE_SND
  always @(posedge clk) if (!rst) begin
    if (eng.snd_en) $display("T=%0t SND pid=%09h res=%09h atom=%0b hit=%0b msg=%09h del=%0b rem=%0b long=%0b bad=%0b",
      $time, eng.snd_pid, eng.snd_pid_res, eng.snd_atom, eng.nt_q_hit, eng.snd_msg,
      eng.delivered, eng.snd_remote, eng.is_send_long, eng.bad_pid);
    if (eng.send_go) $display("T=%0t SENDGO seat=%0d pid=%09h slot=%0d rem=%0b", $time,
      eng.send_seat, eng.sr_seat, eng.sr_slot, eng.sr_rem);
    if (eng.ser_go_emit) $display("T=%0t GOEMIT cnt=%0d fits=%0b free=%0d", $time,
      eng.ser_count, eng.sr_fits, eng.mb_free);
    if (eng.ser_abort) $display("T=%0t ABORT", $time);
    if (eng.ser_done) $display("T=%0t SERDONE", $time);
    if (eng.mb_rg | eng.mb_ser) $display("T=%0t MBENQ", $time);
    if (eng.any_fault) $display("T=%0t FAULT r=%0d", $time, eng.any_fault_r);
    if (eng.mb_cmd != 0) $display("T=%0t MB cmd=%0d slot=%0d len=%0d head=%0b unseen=%0b", $time, eng.mb_cmd, eng.mb_slot, eng.mb_len, eng.mb_head, eng.mb_unseen);
    if (eng.mb_done) $display("T=%0t MBSCAN hit=%0b idx=%0d mlen=%0d word=%09h", $time, eng.mb_hit, eng.mb_hit_idx, eng.mb_hit_len, eng.mb_hit_word);
    if (eng.gc_st != 0) $display("T=%0t GC st=%0d slot=%0d pend=%b busy=%0b quiet=%0b wait=%0d rkbusy=%0b cxbusy=%0b hp=%0d",
      $time, eng.gc_st, eng.gc_slot, eng.gc_pend, eng.gc_busy, eng.gc_quiet, eng.gc_wait, eng.rk_busy, eng.cx_busy, eng.hp_hp);
    if (eng.ser_done) $display("T=%0t SERWAKE sw=%0b slot=%0d wake_en=%0b wake_slot=%0d wk=%b%b%b%b st=%0d/%0d/%0d/%0d slots=%0d,%0d,%0d,%0d rd6st=%0d wq=%0b",
      $time, eng.ser_wake, eng.sr_slot, eng.wake_en, eng.wake_slot,
      eng.wk0, eng.wk1, eng.wk2, eng.wk3,
      eng.dbg_st0, eng.dbg_st1, eng.dbg_st2, eng.dbg_st3,
      eng.slot0, eng.slot1, eng.slot2, eng.slot3, eng.pt_rd6_state, eng.wake_queued);
  end
`endif

`ifdef TRACE2
  always @(posedge clk) if (!rst && $time > 5400000 && $time < 5800000)
    $display("T=%0t xen=%0b xs=%0d pc=%0d st0=%0d flt=%0b fr=%0d out=%0b outd=%09h",
             $time, dbg_x_en, dbg_x_seat, dbg_pc, dbg_st0, faulted, fault_reason,
             out_valid, out_data);
`endif
// -DTRACE_PC prints every bundle the X stage retires, between -DT0 and
// -DT1 picoseconds. `TRACE2` above answers the same question but with
// the window hard-coded to one past investigation, which is fine for
// that investigation and useless for the next one.
`ifndef T0
  `define T0 0
`endif
`ifndef T1
  `define T1 1000000000
`endif
`ifdef TRACE_PC
  always @(posedge clk) if (!rst && dbg_x_en && $time >= `T0 && $time <= `T1)
    $display("T=%0t X seat=%0d slot=%0d pc=%0d occ=%0d out=%0b outd=%09h",
             $time, dbg_x_seat, eng.x_slot, dbg_pc, dbg_occ, out_valid, out_data);
`endif
`ifdef TRACE_SUP
  always @(posedge clk) if (!rst) begin
    if (eng.any_trap) $display("T=%0t trapexit slot=%0d flag=%0b", $time, eng.x_slot, eng.trap_flag);
    if (eng.pt_trap_go) $display("T=%0t settrap issued slot=%0d flag=%0b", $time, eng.tp_slot, eng.tp_flag);
    if (eng.any_link) $display("T=%0t link caller=%0d target=%0d alive=%0b bad=%0b", $time, eng.x_slot, eng.sup_slot, eng.sup_alive, eng.sup_bad);
    if ($time > 5240000 && $time < 5460000) $display("T=%0t xen=%0b xseat=%0d pc=%0d st0=%0d rtake=%0b long=%0b dzbusy=%0b tgo=%0b", $time, dbg_x_en, dbg_x_seat, dbg_pc, dbg_st0, eng.any_rtake, eng.is_rtake_long, eng.dz_busy, eng.take_go);
    if (eng.any_rtake) $display("T=%0t RTAKE long=%0b rlen=%0d ridx=%0d seat=%0d", $time, eng.is_rtake_long, eng.x_rlen, eng.x_ridx, dbg_x_seat);
    if (eng.take_go) $display("T=%0t TAKEGO seat=%0d slot=%0d idx=%0d len=%0d", $time, eng.take_seat, eng.dz_slot, eng.dz_idx, eng.dz_len);
    if (eng.dz_done) $display("T=%0t DZDONE result=%09h seat=%0d rd=%0d", $time, eng.dz_result, eng.dz_seat, eng.dz_rd);
    if (eng.pt_cmd != 0) $display("T=%0t ptcmd=%0d slot=%0d pc=%0d occ=%0d", $time, eng.pt_cmd, eng.pt_slot, eng.pt_pc, dbg_occ);
    if ($time > 44400000 && $time < 44800000) $display("T=%0t xen=%0b seat=%0d pc=%0d st0=%0d ub=%0b ubs=%0d ubj=%0b ubpc=%0d", $time, dbg_x_en, dbg_x_seat, dbg_pc, dbg_st0, eng.unblock_en, eng.unblock_seat, eng.unblock_jump, eng.unblock_pc);
    if (eng.tm_fire) $display("T=%0t TFIRE slot=%0d pc=%0d resident=%0b", $time, eng.tm_fire_slot, eng.tm_fire_pc, eng.tm_resident);
    if (eng.any_exit2) $display("T=%0t EXIT2 target=%0d alive=%0b bad=%0b reason=%0d rb=%09h traps=%0b", $time, eng.sup_slot, eng.sup_alive, eng.sup_bad, eng.ex_reason, eng.rw_rd1, eng.pt_rd3_trap);
    if (eng.lt_die) $display("T=%0t DIE slot=%0d reason=%0d", $time, eng.lt_die_slot, eng.lt_die_reason);
    if (eng.lt_st == 1) $display("T=%0t walk rest=%08h next=%0d nv=%0b rd3=%0d trap=%0b ready=%0b anysup=%0b", $time, eng.lt_rest, eng.lt_next, eng.lt_nextv, eng.pt_rd3_slot, eng.pt_rd3_trap, eng.lt_ready, eng.any_sup);
    if (eng.lt_sig) $display("T=%0t SIG to=%0d traps_d=%0b reason=%0d", $time, eng.lt_sig_slot, eng.sig_traps_d, eng.lt_sig_reason);
    if (eng.pt_doom_go) $display("T=%0t DOOM slot=%0d reason=%0d", $time, eng.dm_slot, eng.dm_reason);
  end
`endif

  always @(posedge clk) if (!rst && out_valid) begin
    if (n_out < 32) outs[n_out] = out_data;
    n_out = n_out + 1;
  end

  reg [35:0] expect [0:15];
  integer n_exp = 0;

  initial begin
    for (i = 0; i < 512; i = i + 1) image[i] = 0;
    for (i = 0; i < 16; i = i + 1) expect[i] = 36'hFFFFFFFFF;
    $readmemh(`IMG, image);
    $readmemh(`EXP, expect);
`ifdef POOL
    for (i = 0; i < 256; i = i + 1) poolimg[i] = 0;
    $readmemh(`POOL, poolimg);
`endif
    // zero the RAMs the way ECP5 primitives power up
    for (i = 0; i < 8192; i = i + 1) eng.frames_frames[i] = 0;
    for (i = 0; i < 512; i = i + 1) eng.frames_rets[i] = 0;
    for (i = 0; i < 512; i = i + 1) begin eng.seats_save[i] = 0; eng.code_mem_code[i] = 0; end
    for (i = 0; i < 32; i = i + 1) begin
      eng.procs_serials[i]=0; eng.procs_states[i]=0;
      eng.procs_pcs[i]=0; eng.procs_reasons[i]=0; eng.runq_q[i]=0;
      eng.procs_flist[i]=i;
    end
    for (i = 0; i < 256; i = i + 1) begin
      eng.windows_b0r0[i]=0; eng.windows_b0r1[i]=0; eng.windows_b0r2[i]=0;
      eng.windows_b0r3[i]=0; eng.windows_b0r4[i]=0; eng.windows_b0r5[i]=0;
      eng.windows_b0r6[i]=0;
      eng.windows_b1r0[i]=0; eng.windows_b1r1[i]=0; eng.windows_b1r2[i]=0;
      eng.windows_b1r3[i]=0; eng.windows_b1r4[i]=0; eng.windows_b1r5[i]=0;
      eng.windows_b1r6[i]=0;
      eng.windows_b2r0[i]=0; eng.windows_b2r1[i]=0; eng.windows_b2r2[i]=0;
      eng.windows_b2r3[i]=0; eng.windows_b2r4[i]=0; eng.windows_b2r5[i]=0;
      eng.windows_b2r6[i]=0;
    end

    for (i = 0; i < 2048; i = i + 1) begin
      eng.mbox_words[i] = 0; eng.mbox_hv[i] = 0;
    end
    for (i = 0; i < 256; i = i + 1) begin
      eng.hp_h0[i] = 0; eng.hp_h1[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      eng.mbox_heads[i]=0; eng.mbox_tails[i]=0; eng.mbox_cnts[i]=0; eng.mbox_curs[i]=0;
      eng.mbox_heads2[i]=0; eng.mbox_tails2[i]=0; eng.mbox_cnts2[i]=0; eng.mbox_curs2[i]=0;
      eng.procs_serials2[i]=0; eng.procs_states2[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // stream the image into CodeMem through the loader side-door.
    //
    // 512 — the whole store — and not a number chosen to be big enough
    // for today's programs. It was 128, then 256, and each time a
    // program outgrew it the tail stayed zeros: bundle zero is
    // `add r0, r0, r0`, so the process ran off the end of its code,
    // added a register to itself and died of `overflow` several
    // hundred cycles later. `mapelixir` is 358 bundles and that is
    // exactly what it did.
    for (i = 0; i < 512; i = i + 1) begin
      @(negedge clk);
      ld_en = 1; ld_addr = i[8:0]; ld_data = image[i];
      @(posedge clk); #1;
    end
    ld_en = 0;
    @(posedge clk); #1;

`ifdef POOL
    // the literal pool goes in through its own side-door, the way the
    // .pbi loader will fill it before releasing the engines
    for (i = 0; i < 256; i = i + 1) begin
      @(negedge clk);
      ld_pen = 1; ld_paddr = i[7:0]; ld_pdata = poolimg[i];
      @(posedge clk); #1;
    end
    ld_pen = 0;
    @(posedge clk); #1;
`endif

    @(negedge clk); boot_en = 1; boot_pc = 9'd0;
    @(posedge clk); #1; boot_en = 0;

    for (i = 0; i < `CYCLES; i = i + 1) begin
      @(posedge clk);
      if (idle && dbg_deaths > 0) i = `CYCLES;
    end
    if (i > `CYCLES + 1) $display("  (hit the cycle cap: pc=%0d st0=%0d occ=%0d deaths=%0d)",
                  dbg_pc, dbg_st0, dbg_occ, dbg_deaths);
    #1;

    for (i = 0; i < 16; i = i + 1)
      if (expect[i] !== 36'hFFFFFFFFF) n_exp = n_exp + 1;

    if (`WANT_DEATHS >= 0) begin
      if (dbg_deaths !== `WANT_DEATHS)
        $display("  deaths=%0d, wanted %0d", dbg_deaths, `WANT_DEATHS);
      check(dbg_deaths == `WANT_DEATHS, "the right number of processes died");
    end
    if (`WANT_PT_REASON >= 0) begin
      if (eng.procs_reasons[`WANT_PT_SLOT] !== `WANT_PT_REASON)
        $display("  slot %0d died of %0d, wanted %0d", `WANT_PT_SLOT,
                 eng.procs_reasons[`WANT_PT_SLOT], `WANT_PT_REASON);
      check(eng.procs_reasons[`WANT_PT_SLOT] == `WANT_PT_REASON,
            "the killed process's recorded reason is the one the signal named");
    end
    if (`WANT_MB_HASH >= 0) begin
      if (eng.mbox_hv[`WANT_MB_SLOT * 64][7:0] !== `WANT_MB_HASH)
        $display("  mailbox head hash %0d, wanted %0d",
                 eng.mbox_hv[`WANT_MB_SLOT * 64][7:0], `WANT_MB_HASH);
      check(eng.mbox_hv[`WANT_MB_SLOT * 64][7:0] == `WANT_MB_HASH,
            "the signal left a message of the right SHAPE");
      check(eng.mbox_hv[`WANT_MB_SLOT * 64][14] == 1'b1,
            "marked as a message head, not a continuation");
      if (eng.mbox_hv[`WANT_MB_SLOT * 64][13:8] !== `WANT_MB_LEN)
        $display("  mailbox head len %0d, wanted %0d",
                 eng.mbox_hv[`WANT_MB_SLOT * 64][13:8], `WANT_MB_LEN);
      check(eng.mbox_hv[`WANT_MB_SLOT * 64][13:8] == `WANT_MB_LEN,
            "and every flit of it landed");
    end
    if (`WANT_IDLE) begin
      if (!idle) $display("  still running: occ=%0d qcount=%0d pc=%0d",
                          dbg_occ, dbg_qcount, dbg_pc);
      check(idle == 1'b1, "the machine halted, not just one process");
    end
    if (`WANT_OCC >= 0) begin
      if (dbg_occ !== `WANT_OCC)
        $display("  occ=%0d, wanted %0d", dbg_occ, `WANT_OCC);
      check(dbg_occ == `WANT_OCC, "the right number survived");
    end

    if (`WANT_FAULT < 0) begin
      if (faulted) $display("  FAULTED reason=%0d count=%0d slot=%0d",
                            fault_reason, fault_count, fault_slot);
      check(faulted == 0, "no faults");
    end else begin
      check(faulted == 1, "a process died abnormally");
      if (fault_reason !== `WANT_FAULT)
        $display("  reason %0d, wanted %0d", fault_reason, `WANT_FAULT);
      check(fault_reason == `WANT_FAULT,
            "and the port names the reason it ACTUALLY died of");
    end

    if (`WANT_FAULT_COUNT >= 0) begin
      if (fault_count !== `WANT_FAULT_COUNT)
        $display("  %0d abnormal deaths, wanted %0d",
                 fault_count, `WANT_FAULT_COUNT);
      check(fault_count == `WANT_FAULT_COUNT,
            "and that many processes died abnormally, not more");
    end
    check(n_out == n_exp, "one out per model out");

    for (i = 0; i < n_exp; i = i + 1) begin
      if (outs[i] !== expect[i]) begin
        $display("FAIL tick %0d: gates %09h, model %09h", i, outs[i], expect[i]);
        errors = errors + 1;
      end
    end

    $display("%0s outs=%0d/%0d  [%0d %0d %0d %0d %0d]",
      `IMG, n_out, n_exp, outs[0], outs[1], outs[2], outs[3], outs[4]);

    if (errors == 0) $display("__FIXED_OK__");
    else $display("__FIXED_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #6000000;
    $display("__FIXED_TIMEOUT__");
    $finish;
  end
endmodule
