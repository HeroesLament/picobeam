// A pure instrumentation harness: run an image and dump every X-stage
// retirement as (time, seat, slot, pc). Nothing is asserted here — the
// point is a transcript to diff against the model's, which is how a
// divergence gets bracketed to a single bundle.
//
//   iverilog -DIMG=\"erlsup.hex\" -DPOOL=\"erlsup_pool.hex\" -o t.vvp \
//     scripts/tb_trace.v <netlists> && vvp t.vvp
`timescale 1ns/1ps
`ifndef IMG
  `define IMG "erlsup.hex"
`endif
`ifndef NCYC
  `define NCYC 40000
`endif
`ifndef FROM
  `define FROM 0
`endif
`ifndef TO
  `define TO 100000
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
  wire [5:0] dbg_scan, dbg_occ, dbg_qcount;
  wire [7:0] dbg_swaps, dbg_spawns, dbg_deaths;
  wire [1:0] dbg_x_seat; wire dbg_x_en; wire [8:0] dbg_pc;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;

  barrel_engine eng(.clk(clk), .rst(rst),
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
  integer i, cyc = 0, n_out = 0;

  // the transcript
  always @(posedge clk) if (!rst) begin
    cyc = cyc + 1;
    if (cyc >= `FROM && cyc <= `TO) begin
      if (dbg_x_en)
        $display("X %0d seat=%0d slot=%0d pc=%0d", cyc, dbg_x_seat,
                 eng.x_slot, dbg_pc);
      if (out_valid) $display("  OUT %0d %09h", cyc, out_data);
      if (eng.pt_cmd != 0)
        $display("  PT %0d cmd=%0d slot=%0d pc=%0d occ=%0d", cyc,
                 eng.pt_cmd, eng.pt_slot, eng.pt_pc, dbg_occ);
      if (eng.unblock_en)
        $display("  UNBLOCK %0d seat=%0d jump=%0b pc=%0d", cyc,
                 eng.unblock_seat, eng.unblock_jump, eng.unblock_pc);
      if (eng.lt_die) $display("  DIE %0d slot=%0d reason=%0d", cyc, eng.lt_die_slot, eng.lt_die_reason);
      if (eng.lt_sig) $display("  SIG %0d to=%0d kind=%0d ref=%0d from=%09h reason=%0d traps_d=%0b", cyc, eng.lt_sig_slot, eng.lt_sig_kind, eng.lt_sig_ref, eng.lt_sig_from, eng.lt_sig_reason, eng.sig_traps_d);
      if (eng.sd_en) $display("  SD %0d st=%0d kind=%0d slot=%0d head=%0b len=%0d w=%09h", cyc, eng.sd_st, eng.sd_kind, eng.sd_slot, eng.sd_head, eng.sd_len, eng.sd_word);
      if (eng.any_link) $display("  LINK %0d caller=%0d target=%0d alive=%0b bad=%0b", cyc, eng.x_slot, eng.sup_slot, eng.sup_alive, eng.sup_bad);
      if (eng.pt_trap_go) $display("  SETTRAP %0d slot=%0d flag=%0b", cyc, eng.tp_slot, eng.tp_flag);
      if (eng.take_go) $display("  TAKEGO %0d seat=%0d slot=%0d idx=%0d len=%0d rd=%0d", cyc, eng.take_seat, eng.dz_slot, eng.dz_idx, eng.dz_len, eng.dz_rd);
      if (eng.any_tail) $display("  TAIL %0d seat=%0d slot=%0d", cyc, dbg_x_seat, eng.x_slot);
      if (eng.any_rtake && eng.dbg_x_en) $display("  RTAKE %0d slot=%0d len=%0d idx=%0d", cyc, eng.x_slot, eng.x_rlen, eng.x_ridx);
      if (eng.mb_done && eng.mb_hit) $display("  HIT %0d seat=%0d slot=%0d idx=%0d len=%0d", cyc, eng.scan_done_seat_w, eng.peek_slot, eng.mb_hit_idx, eng.mb_hit_len);
      if (eng.mb_cmd != 0) $display("  MBCMD %0d cmd=%0d slot=%0d head=%0b len=%0d w=%09h | q_head=%0d q_cur=%0d q_cnt=%0d q_tail=%0d curwe=%0b curdat=%0d hvwe=%0b hvaddr=%0d", cyc, eng.mb_cmd, eng.mb_slot, eng.mb_head, eng.mb_len, eng.mb_word_w, eng.mbox_q_head, eng.mbox_q_cur, eng.mbox_q_cnt, eng.mbox_q_tail, eng.mbox_cur_we, eng.mbox_cur_data, eng.mbox_hv_we, eng.mbox_hv_addr);
      if (eng.dbg_x_en && dbg_pc == 9'd146) $display("  N-AT-146 %0d N=%09h", cyc, eng.rw_rd0);
      if (eng.dbg_x_en && dbg_pc == 9'd153) $display("  N-AT-153 %0d N=%09h (add 13,0,12)", cyc, eng.rw_rd0);
      if (eng.dbg_x_en && dbg_pc == 9'd144) $display("  TAKE-144 %0d", cyc);
      if (eng.dz_done) $display("  DZDONE %0d result=%09h seat=%0d rd=%0d", cyc, eng.dz_result, eng.dz_seat, eng.dz_rd);
    end
  end

  initial begin
    for (i = 0; i < 512; i = i + 1) image[i] = 0;
    $readmemh(`IMG, image);
`ifdef POOL
    for (i = 0; i < 256; i = i + 1) poolimg[i] = 0;
    $readmemh(`POOL, poolimg);
`endif
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
    for (i = 0; i < 2048; i = i + 1) begin eng.mbox_words[i] = 0; eng.mbox_hv[i] = 0; end
    for (i = 0; i < 256; i = i + 1) begin eng.hp_h0[i] = 0; eng.hp_h1[i] = 0; end
    for (i = 0; i < 32; i = i + 1) begin
      eng.mbox_heads[i]=0; eng.mbox_tails[i]=0; eng.mbox_cnts[i]=0; eng.mbox_curs[i]=0;
      eng.mbox_heads2[i]=0; eng.mbox_tails2[i]=0; eng.mbox_cnts2[i]=0; eng.mbox_curs2[i]=0;
      eng.procs_serials2[i]=0; eng.procs_states2[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;
    for (i = 0; i < 256; i = i + 1) begin
      @(negedge clk); ld_en = 1; ld_addr = i[8:0]; ld_data = image[i];
      @(posedge clk); #1;
    end
    ld_en = 0; @(posedge clk); #1;
`ifdef POOL
    for (i = 0; i < 256; i = i + 1) begin
      @(negedge clk); ld_pen = 1; ld_paddr = i[7:0]; ld_pdata = poolimg[i];
      @(posedge clk); #1;
    end
    ld_pen = 0; @(posedge clk); #1;
`endif
    @(negedge clk); boot_en = 1; boot_pc = 9'd0;
    @(posedge clk); #1; boot_en = 0;

    for (i = 0; i < `NCYC; i = i + 1) begin
      @(posedge clk);
      if (idle && dbg_deaths > 0) i = `NCYC;
    end
    $display("__TRACE_END__ cyc=%0d occ=%0d deaths=%0d faulted=%0b reason=%0d",
             cyc, dbg_occ, dbg_deaths, faulted, fault_reason);
    $finish;
  end
endmodule
