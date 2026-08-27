// M3 pass 6 testbench — the scheduling loop, five components wired:
// BarrelSeq + SeatUnit + ProcTable + RunQueue + RegWindowCtx.
//
//   cd _emit/m3 && iverilog -o tb6.vvp ../../scripts/tb_m3_pass6.v \
//     barrel_seq.v seat_unit.v proc_table.v run_queue.v reg_window_ctx.v \
//     && vvp tb6.vvp
//
// Six processes, four seats, BUDGET = 8. Each process runs
//
//     100: r1 = <my slot>      101: check r1 == <my slot>    102: jmp 101
//
// so any swap that restores the wrong window, or loses one, is caught
// by value on the very next turn the process runs. Checks: all six
// procs get seated and run, swaps happen, the queue keeps exactly two
// waiters, register state survives every swap, and no proc's r1 ever
// belongs to another proc.
//
// Prints __M3_PASS6_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg boot = 1;

  // ---- BarrelSeq ----
  reg is_jump = 0, is_call = 0, is_ret = 0, is_halt = 0, fault_in = 0, has_wb2 = 0;
  reg [8:0] pc_target = 0;
  wire [1:0] f_seat, d_seat, x_seat, commit_seat, fill_seat, died_seat;
  wire f_en, d_en, x_en, call_commit, pop_en, fill_en, dest_wr, wb2_en, died, died_fault;
  wire [8:0] f_pc, x_pc, link_pc;
  wire [3:0] fill_idx;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;
  wire seat_wr, seat_clr;
  wire [1:0] seat_idx;
  wire [8:0] seat_pc;

  barrel_seq bs(.clk(clk), .rst(rst), .gc_park(1'b0), .gc_res4(4'b0),
    // Phase 4/entry 38 grew the seq new inputs; this test predates them
    .is_sup_rem(1'b0), .sup_done(1'b0), .sup_done_seat(2'd0), .pkw_done(1'b0), .pkw_done_seat(2'd0),
        .is_cfun(1'b0), .ftgt_en(1'b0), .ftgt_seat(2'd0), .ftgt_pc(9'd0),
    .bad_en(1'b0), .bad_seat(2'd0),
    // notes/32: the catch ports. Tied off here — these passes predate
    // `try`/`catch` and none of their programs opens one — but tied off
    // EXPLICITLY, because an unconnected input floats to x and `dest_mode`
    // at x makes every ret hang.
    .catch_go(1'b0), .catch_deep(1'b0), .catch_pc(9'd0), .dest_mode(1'b0),
    .frozen(1'b0),
    .cwb_en(), .cwb_seat(),
    .seat_wr(seat_wr), .seat_idx(seat_idx), .seat_pc(seat_pc), .seat_clr(seat_clr),
    .is_jump(is_jump), .pc_target(pc_target), .is_call(is_call),
    .is_ret(is_ret), .is_halt(is_halt), .fault_in(fault_in), .has_wb2(has_wb2), .is_spawn(1'b0),
    .is_rpeek(1'b0), .is_rwait_blk(1'b0),
    .is_rtake_long(1'b0), .deser_free(1'b1), .deser_done(1'b0),
    .is_send_long(1'b0), .ser_free(1'b1), .ser_done(1'b0), .ser_done_seat(2'd0),
    .deser_done_seat(2'd0), .take_go(), .take_seat(),
    .scan_free(1'b1), .scan_done(1'b0), .scan_done_seat(2'd0), .scan_hit(1'b0),
    .unblock_en(1'b0), .unblock_seat(2'd0), .kill_en(1'b0), .kill_seat(2'd0), .peek_go(), .peek_seat(), .f_blocked(),
    .spawn_ready(1'b0), .spawn_full(1'b0), .spawn_commit(), .spawn_seat(), .f_tgt(),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .ret_pc_in(9'd0),
    .f_seat(f_seat), .f_en(f_en), .f_pc(f_pc),
    .d_seat(d_seat), .d_en(d_en), .x_seat(x_seat), .x_en(x_en), .x_pc(x_pc),
    .call_commit(call_commit), .commit_seat(commit_seat), .link_pc(link_pc),
    .pop_en(pop_en), .fill_en(fill_en), .fill_idx(fill_idx), .fill_seat(fill_seat),
    .dest_wr(dest_wr), .wb2_en(wb2_en),
    .died(died), .died_seat(died_seat), .died_fault(died_fault),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  // ---- SeatUnit ----
  wire [2:0] su_cmd; wire [4:0] su_slot; wire [8:0] su_pc;
  wire su_rq_push, su_rq_pop; wire [4:0] su_rq_data;
  wire op_swap; wire [1:0] swap_ctx;
  wire sfill_en; wire [3:0] sfill_idx; wire [1:0] sfill_seat; wire [35:0] sfill_data;
  wire [4:0] slot0, slot1, slot2, slot3, x_slot, pt_rd_slot;
  wire [21:0] x_serial;
  wire [2:0] su_st;
  wire [7:0] su_swaps;
  wire su_rst = rst | boot;

  // the remote-creation port (`notes/49`): no ring here, so it is tied
  // off. An unconnected input floats to x and takes every branch that
  // reads it along.
  seat_unit su(.rsp_req(1'b0), .rsp_pc(9'd0), .rsp_arg_d(36'd0),
    .clk(clk), .rst(su_rst), .gc_en(1'b0), .gc_slot(5'd0), .gc_idx(4'd0), .gc_wr(1'b0), .gc_data(36'd0), .eng_id(4'd0), .budget(6'd8),
    .f_seat(f_seat), .f_pc(f_pc), .f_run(f_en), .f_blocked(1'b0), .d_seat(d_seat),
    .x_en(x_en), .x_seat(x_seat), .is_yield_x(1'b0),
    .died(died), .died_seat(died_seat), .death_reason(8'd0),
    .seat_wr(seat_wr), .seat_clr(seat_clr), .seat_idx(seat_idx), .seat_pc(seat_pc),
    .pt_cmd(su_cmd), .pt_slot(su_slot), .pt_pc(su_pc), .pt_rd_slot(pt_rd_slot),
    .pt_rd_pc(pt_rd_pc), .pt_rd_serial(pt_rd_serial),
    .pt_alloc_slot(alloc_slot), .pt_alloc_serial(alloc_serial), .pt_occ(occ),
    .spawn_commit(1'b0), .spawn_seat(2'd0), .spawn_pc(9'd0), .spawn_rd(4'd0),
    .spawn_ready(), .spawn_full(), .op_spawn(), .sp_ctx(),
    .pid_wr(), .pid_seat(), .pid_reg(), .pid_data(), .self_pid(),
    .rq_push(su_rq_push), .rq_push_data(su_rq_data), .rq_pop(su_rq_pop),
    .rq_head(rq_head), .rq_empty(rq_empty),
    .op_swap(op_swap), .swap_ctx(swap_ctx), .drain_ready(drain_ready),
    .spill_valid(spill_valid), .spill_idx(spill_idx), .spill_data(spill_data),
    .sfill_en(sfill_en), .sfill_idx(sfill_idx), .sfill_seat(sfill_seat),
    .sfill_data(sfill_data),
    .slot0(slot0), .slot1(slot1), .slot2(slot2), .slot3(slot3),
    .x_slot(x_slot), .x_serial(x_serial), .dbg_st(su_st), .dbg_swaps(su_swaps));

  // ---- ProcTable (TB drives it during boot, SeatUnit after) ----
  reg [2:0] tb_cmd = 0; reg [4:0] tb_slot = 0; reg [8:0] tb_pc = 0;
  wire [2:0] pt_cmd   = boot ? tb_cmd  : su_cmd;
  wire [4:0] pt_slot  = boot ? tb_slot : su_slot;
  wire [8:0] pt_pc    = boot ? tb_pc   : su_pc;
  wire alloc_ok; wire [4:0] alloc_slot; wire [21:0] alloc_serial;
  wire [8:0] pt_rd_pc; wire [21:0] pt_rd_serial; wire [1:0] pt_rd_state;
  wire [5:0] occ;

  proc_table pt(.clk(clk), .rst(rst), .cmd(pt_cmd), .cmd_slot(pt_slot), .cmd_pc(pt_pc),
    .alloc_ok(alloc_ok), .alloc_slot(alloc_slot), .alloc_serial(alloc_serial),
    .rd_slot(pt_rd_slot), .rd_pc(pt_rd_pc), .rd_serial(pt_rd_serial),
    .rd_state(pt_rd_state), .occ(occ));

  // ---- RunQueue ----
  reg tb_push = 0; reg [4:0] tb_push_data = 0;
  wire rq_push      = boot ? tb_push      : su_rq_push;
  wire [4:0] rq_data= boot ? tb_push_data : su_rq_data;
  wire rq_pop       = boot ? 1'b0         : su_rq_pop;
  wire [4:0] rq_head; wire rq_empty, rq_full; wire [5:0] rq_count;

  run_queue rq(.clk(clk), .rst(rst), .push(rq_push), .push_data(rq_data),
    .pop(rq_pop), .q_head(rq_head), .empty(rq_empty), .full(rq_full), .count(rq_count));

  // ---- register window ----
  reg [3:0] rd_addr0 = 0;
  reg w_en0_p = 0; reg [3:0] w_addr0_p = 0; reg [35:0] w_data0_p = 0;
  wire [35:0] rd_data0;
  wire drain_ready, drain_done; wire [1:0] drain_done_seat, spill_seat;
  wire spill_valid; wire [3:0] spill_idx; wire [35:0] spill_data;

  // swap-in write trails its read by one cycle (lands on the owner's X)
  reg sfw_en = 0; reg [3:0] sfw_idx = 0; reg [1:0] sfw_seat = 0;
  always @(posedge clk) begin
    sfw_en <= sfill_en; sfw_idx <= sfill_idx; sfw_seat <= sfill_seat;
  end

  wire [1:0] w_ctx_sel    = sfw_en ? sfw_seat : x_seat;
  wire w_en0_all          = sfw_en | w_en0_p;
  wire [3:0] w_addr0_all  = sfw_en ? sfw_idx : w_addr0_p;
  wire [35:0] w_data0_all = sfw_en ? sfill_data : w_data0_p;

  reg_window_ctx w(.clk(clk), .rst(rst), .rd_stg0(1'b0),
    .rd_ctx(d_seat), .rd_addr0(rd_addr0), .rd_addr1(4'd0), .rd_addr2(4'd0),
    .rd_addr3(4'd0), .rd_addr4(4'd0), .rd_addr5(4'd0),
    .rd_data0(rd_data0), .rd_data1(), .rd_data2(), .rd_data3(), .rd_data4(), .rd_data5(),
    .w_ctx(w_ctx_sel), .w_en0(w_en0_all), .w_stg0(1'b0),
    .w_addr0(w_addr0_all), .w_data0(w_data0_all),
    .w_en1(1'b0), .w_stg1(1'b0), .w_addr1(4'd0), .w_data1(36'd0),
    .w_en2(1'b0), .w_stg2(1'b0), .w_addr2(4'd0), .w_data2(36'd0),
    .op_call(call_commit), .call_ctx(commit_seat), .op_tail(1'b0), .tail_ctx(2'd0),
    .op_swap(op_swap), .swap_ctx(swap_ctx), .op_spawn(1'b0), .spawn_ctx(2'd0),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .spill_valid(spill_valid),
    .spill_idx(spill_idx), .spill_data(spill_data), .spill_seat(spill_seat));

  // ---- the program ----
  reg [8:0] d_pc = 0;
  always @(posedge clk) d_pc <= f_pc;

  always @(*) begin
    is_jump = 0; pc_target = 0;
    if (x_pc == 9'd102) begin is_jump = 1; pc_target = 9'd101; end
  end

  always @(*) begin
    rd_addr0 = 0;
    if (d_pc == 9'd101) rd_addr0 = 4'd1;
  end

  always @(*) begin
    w_en0_p = 0; w_addr0_p = 0; w_data0_p = 0;
    if (x_en && x_pc == 9'd100) begin
      w_en0_p = 1; w_addr0_p = 4'd1; w_data0_p = {31'd0, x_slot};
    end
  end

  // ---- monitors ----
  integer errors = 0, i;
  integer ran [0:31];
  integer checks = 0;
  integer seen_slots = 0;

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  always @(posedge clk) if (!rst && !boot) begin
    if (x_en) begin
      ran[x_slot] = ran[x_slot] + 1;
      if (x_pc == 9'd101) begin
        checks = checks + 1;
        // the crown-jewel invariant: the window a process wakes up in
        // is ITS window, with the value it wrote before being swapped
        check(rd_data0 == {31'd0, x_slot}, "restored r1 belongs to the running proc");
      end
    end
    // a seated slot must never be sitting in the run queue too
    if (seat_wr) begin
      check(pt_rd_state != 2'd2, "seating a proc that is not already resident");
    end
  end

  initial begin
    for (i = 0; i < 32; i = i + 1) ran[i] = 0;
    for (i = 0; i < 512; i = i + 1) su.save[i] = 0;
    for (i = 0; i < 32; i = i + 1) begin
      pt.serials[i]=0; pt.states[i]=0; pt.pcs[i]=0; pt.reasons[i]=0; rq.q[i]=0;
    end
    for (i = 0; i < 256; i = i + 1) begin
      w.b0r0[i]=0; w.b0r1[i]=0; w.b0r2[i]=0; w.b0r3[i]=0; w.b0r4[i]=0; w.b0r5[i]=0; w.b0r6[i]=0;
      w.b1r0[i]=0; w.b1r1[i]=0; w.b1r2[i]=0; w.b1r3[i]=0; w.b1r4[i]=0; w.b1r5[i]=0; w.b1r6[i]=0;
      w.b2r0[i]=0; w.b2r1[i]=0; w.b2r2[i]=0; w.b2r3[i]=0; w.b2r4[i]=0; w.b2r5[i]=0; w.b2r6[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---- bootstrap: six processes, all entering at pc 100 ----
    for (i = 0; i < 6; i = i + 1) begin
      @(negedge clk);
      tb_cmd = 3'd1; tb_pc = 9'd100;
      tb_push = 1; tb_push_data = alloc_slot;
      @(posedge clk); #1;
      tb_cmd = 0; tb_push = 0;
    end
    check(rq_count == 6, "six procs queued");
    check(occ == 6, "six slots allocated");

    // ---- release the scheduler ----
    @(negedge clk); boot = 0; @(posedge clk); #1;

    // let it run long enough for many swap rounds
    repeat (6000) @(posedge clk);
    #1;

    // every process must have executed
    seen_slots = 0;
    for (i = 0; i < 32; i = i + 1) if (ran[i] > 0) seen_slots = seen_slots + 1;
    check(seen_slots == 6, "all six processes ran");

    // fairness: no process starved (each got a real share)
    for (i = 0; i < 6; i = i + 1)
      check(ran[i] > 40, "process got a fair share of turns");

    check(su_swaps > 10, "many swaps completed");
    check(rq_count == 2, "queue holds exactly the two unseated procs");
    check(checks > 100, "the restored-window invariant was exercised often");

    $display("swaps=%0d checks=%0d ran=[%0d %0d %0d %0d %0d %0d]",
      su_swaps, checks, ran[0], ran[1], ran[2], ran[3], ran[4], ran[5]);

    if (errors == 0) $display("__M3_PASS6_OK__");
    else $display("__M3_PASS6_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #900000;
    $display("__M3_PASS6_TIMEOUT__ st=%0d swaps=%0d", su_st, su_swaps);
    $finish;
  end
endmodule
