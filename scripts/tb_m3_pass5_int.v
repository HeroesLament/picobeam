// M3 pass 5 INTEGRATION testbench — BarrelSeq + RegWindowCtx +
// FrameRamProc wired together, with the TB playing the engine's
// datapath (bundle classification, ALU results, the fill/dest write
// muxing on window port 0).
//
//   cd _emit/m3 && iverilog -o tb5i.vvp ../../scripts/tb_m3_pass5_int.v \
//     barrel_seq.v reg_window_ctx.v frame_ram_proc.v && vvp tb5i.vvp
//
// Seat->slot binding is identity here (the seat file lands in pass 6).
//
// Program, run by ctx0:
//   0  r1 = 111            3  call 50, dest r5     51 ret r3
//   1  r2 = 222            50 r3 = 77; read r0     4  read r1 (=111)
//   2  arg r0 = 42            (must see 42)        5  read r2 (=222)
//                                                  6  read r5 (=77)
//                                                  7  halt
// ctx1 runs a plain non-interference loop the whole time.
//
// Prints __M3_PASS5_INT_OK__ on full success.

`timescale 1ns/1ps

module tb;
  // every declaration ahead of every use (newer iverilog rejects use-before-declaration)
  reg clk = 0, rst = 1;
  reg seat_wr = 0; reg [1:0] seat_idx = 0; reg [8:0] seat_pc = 0;
  reg is_jump = 0, is_call = 0, is_ret = 0, is_halt = 0, fault_in = 0, has_wb2 = 0;
  reg [8:0] pc_target = 0;
  wire [1:0] f_seat, d_seat, x_seat, commit_seat, fill_seat, died_seat;
  wire f_en, d_en, x_en, call_commit, pop_en, fill_en, dest_wr, wb2_en, died, died_fault;
  wire [8:0] f_pc, x_pc, link_pc;
  wire [3:0] fill_idx;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;
  wire drain_ready, drain_done;
  wire [1:0] drain_done_seat;
  wire [8:0] ret_pc_out;
  reg [3:0] rd_addr0 = 0;
  reg w_en0 = 0, w_stg0 = 0;
  reg [3:0] w_addr0 = 0;
  reg [35:0] w_data0 = 0;
  wire [35:0] rd_data0;
  wire spill_valid; wire [3:0] spill_idx; wire [35:0] spill_data; wire [1:0] spill_seat;
  wire [35:0] fill_data;
  wire [3:0] ret_dest_out, depth_out;
  wire overflow, underflow;
  reg [3:0] call_dest = 0;
  reg fillw_en = 0;
  reg [3:0] fillw_idx = 0;
  reg [1:0] fillw_seat = 0;
  reg [35:0] ret_val = 0;
  wire [1:0] w_ctx_sel;
  wire w_en0_all;
  wire w_stg0_all;
  wire [3:0] w_addr0_all;
  wire [35:0] w_data0_all;
  reg [8:0] d_pc = 0;
  reg d_live = 0;
  integer errors = 0;
  integer saw_arg = 0, saw_r1 = 0, saw_r2 = 0, saw_r5 = 0, saw_ctx1 = 0;
  reg [1:0] died_seat_l = 0;
  reg died_fault_l = 0;
  integer i;
  always #5 clk = ~clk;

  // ---- BarrelSeq ----


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
    .seat_wr(seat_wr), .seat_idx(seat_idx), .seat_pc(seat_pc), .seat_clr(1'b0),
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
    .drain_done_seat(drain_done_seat), .ret_pc_in(ret_pc_out),
    .f_seat(f_seat), .f_en(f_en), .f_pc(f_pc),
    .d_seat(d_seat), .d_en(d_en), .x_seat(x_seat), .x_en(x_en), .x_pc(x_pc),
    .call_commit(call_commit), .commit_seat(commit_seat), .link_pc(link_pc),
    .pop_en(pop_en), .fill_en(fill_en), .fill_idx(fill_idx),
    .fill_seat(fill_seat), .dest_wr(dest_wr), .wb2_en(wb2_en),
    .died(died), .died_seat(died_seat), .died_fault(died_fault),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  // ---- window ----

  reg_window_ctx w(.clk(clk), .rst(rst), .rd_stg0(1'b0),
    .rd_ctx(d_seat), .rd_addr0(rd_addr0), .rd_addr1(4'd0), .rd_addr2(4'd0),
    .rd_addr3(4'd0), .rd_addr4(4'd0), .rd_addr5(4'd0),
    .rd_data0(rd_data0), .rd_data1(), .rd_data2(), .rd_data3(), .rd_data4(), .rd_data5(),
    .w_ctx(w_ctx_sel),
    .w_en0(w_en0_all), .w_stg0(w_stg0_all), .w_addr0(w_addr0_all), .w_data0(w_data0_all),
    .w_en1(1'b0), .w_stg1(1'b0), .w_addr1(4'd0), .w_data1(36'd0),
    .w_en2(1'b0), .w_stg2(1'b0), .w_addr2(4'd0), .w_data2(36'd0),
    .op_call(call_commit), .call_ctx(commit_seat), .op_tail(1'b0), .tail_ctx(2'd0),
    .op_swap(1'b0), .swap_ctx(2'd0), .op_spawn(1'b0), .spawn_ctx(2'd0),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .spill_valid(spill_valid),
    .spill_idx(spill_idx), .spill_data(spill_data), .spill_seat(spill_seat));

  // ---- frames (seat->slot identity) ----

  frame_ram_proc fr(.clk(clk), .rst(rst),
    // notes/40: the collector's addressed port. Tied off here — these
    // passes predate the walker — but tied off EXPLICITLY, because an
    // unconnected `gc_wr` floats to x and takes the write mux with it.
    .gc_en(1'b0), .gc_slot(5'd0), .gc_depth(4'd0), .gc_idx(4'd0),
    .gc_wr(1'b0), .gc_data(36'd0), .gc_q(),
    // notes/32: the absolute pop a caught fault uses to discard several
    // frames at once. Tied off: these passes only ever pop one.
    .pop_abs(1'b0), .pop_to(4'd0), .q_slot(5'd0), .q_depth(),
    .push_en(call_commit), .push_slot({3'd0, commit_seat}),
    .push_pc(link_pc), .push_dest(call_dest),
    .spill_valid(spill_valid), .spill_idx(spill_idx), .spill_data(spill_data),
    .pop_en(pop_en), .pop_slot({3'd0, f_seat}),
    .fill_en(fill_en), .fill_idx(fill_idx), .fill_slot({3'd0, fill_seat}),
    .fill_data(fill_data), .ret_pc_out(ret_pc_out), .ret_dest_out(ret_dest_out),
    .overflow(overflow), .underflow(underflow), .depth_out(depth_out));

  // ---- engine glue: the fill write trails the read by one cycle ----
  // (this is M2's fillw_en/fillw_idx delay pair; the sync read lands the
  //  word exactly on the owner's X slot, where port 0 is free)
  always @(posedge clk) begin
    fillw_en <= fill_en;
    fillw_idx <= fill_idx;
    fillw_seat <= fill_seat;
  end

  // port 0 arbitration by phase (never contended: a filling context is
  // parked, so its X slots carry no bundle)
  assign w_ctx_sel = fillw_en ? fillw_seat : (dest_wr ? fill_seat : x_seat);
  assign w_en0_all = fillw_en | dest_wr | w_en0;
  assign w_stg0_all = (fillw_en | dest_wr) ? 1'b0 : w_stg0;
  assign w_addr0_all = fillw_en ? fillw_idx : (dest_wr ? ret_dest_out : w_addr0);
  assign w_data0_all = fillw_en ? fill_data : (dest_wr ? ret_val : w_data0);

  // ---- the program: F->D pc register, classification at X ----
  always @(posedge clk) begin
    d_pc <= f_pc;
    d_live <= f_en;
  end

  always @(*) begin
    is_jump = 0; is_call = 0; is_ret = 0; is_halt = 0;
    fault_in = 0; has_wb2 = 0; pc_target = 0;
    if (x_seat == 0) begin
      case (x_pc)
        9'd3:  begin is_call = 1; pc_target = 9'd50; end
        9'd51: is_ret = 1;
        9'd7:  is_halt = 1;
      endcase
    end else if (x_seat == 1) begin
      if (x_pc == 9'd102) begin is_jump = 1; pc_target = 9'd100; end
    end
  end

  // D stage: read addresses
  always @(*) begin
    rd_addr0 = 0;
    if (d_seat == 0) begin
      case (d_pc)
        9'd50: rd_addr0 = 4'd0;   // callee checks the staged arg
        9'd51: rd_addr0 = 4'd3;   // ret's source register
        9'd4:  rd_addr0 = 4'd1;
        9'd5:  rd_addr0 = 4'd2;
        9'd6:  rd_addr0 = 4'd5;
      endcase
    end else if (d_seat == 1) begin
      if (d_pc == 9'd101) rd_addr0 = 4'd1;
    end
  end

  // X stage: writes + checks
  // died_* are combinational (they track the X seat), so latch them
  always @(posedge clk) if (died) begin
    died_seat_l <= died_seat; died_fault_l <= died_fault;
  end

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  always @(*) begin
    w_en0 = 0; w_stg0 = 0; w_addr0 = 0; w_data0 = 0;
    if (x_en && x_seat == 0) begin
      case (x_pc)
        9'd0:  begin w_en0 = 1; w_addr0 = 4'd1; w_data0 = 36'd111; end
        9'd1:  begin w_en0 = 1; w_addr0 = 4'd2; w_data0 = 36'd222; end
        9'd2:  begin w_en0 = 1; w_stg0 = 1; w_addr0 = 4'd0; w_data0 = 36'd42; end
        9'd50: begin w_en0 = 1; w_addr0 = 4'd3; w_data0 = 36'd77; end
      endcase
    end else if (x_en && x_seat == 1) begin
      if (x_pc == 9'd100) begin w_en0 = 1; w_addr0 = 4'd1; w_data0 = 36'd999; end
    end
  end

  always @(posedge clk) if (!rst) begin
    if (x_en && x_seat == 0) begin
      case (x_pc)
        9'd3:  call_dest <= 4'd5;             // the call's dest register
        9'd50: begin
          saw_arg = saw_arg + 1;
          check(rd_data0 == 42, "callee sees staged arg r0 = 42");
        end
        9'd51: ret_val <= rd_data0;           // latch the ret value (77)
        9'd4:  begin saw_r1 = saw_r1 + 1; check(rd_data0 == 111, "r1 restored 111"); end
        9'd5:  begin saw_r2 = saw_r2 + 1; check(rd_data0 == 222, "r2 restored 222"); end
        9'd6:  begin saw_r5 = saw_r5 + 1; check(rd_data0 == 77,  "r5 = ret value 77"); end
      endcase
    end
    if (x_en && x_seat == 1 && x_pc == 9'd101) begin
      saw_ctx1 = saw_ctx1 + 1;
      check(rd_data0 == 999, "ctx1 r1 = 999 (untouched by ctx0's fill)");
    end
    if (overflow) check(0, "unexpected overflow");
    if (underflow) check(0, "unexpected underflow");
  end

  initial begin
    for (i = 0; i < 8192; i = i + 1) fr.frames[i] = 0;
    for (i = 0; i < 512; i = i + 1) fr.rets[i] = 0;
    for (i = 0; i < 256; i = i + 1) begin
      w.b0r0[i]=0; w.b0r1[i]=0; w.b0r2[i]=0; w.b0r3[i]=0; w.b0r4[i]=0; w.b0r5[i]=0; w.b0r6[i]=0;
      w.b1r0[i]=0; w.b1r1[i]=0; w.b1r2[i]=0; w.b1r3[i]=0; w.b1r4[i]=0; w.b1r5[i]=0; w.b1r6[i]=0;
      w.b2r0[i]=0; w.b2r1[i]=0; w.b2r2[i]=0; w.b2r3[i]=0; w.b2r4[i]=0; w.b2r5[i]=0; w.b2r6[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // seat ctx0 at pc 0 (ctx1 stays idle: this run isolates the data path)
    @(negedge clk); seat_wr = 1; seat_idx = 0; seat_pc = 0;
    @(posedge clk); #1;
    seat_idx = 1; seat_pc = 9'd100; @(posedge clk); #1; seat_wr = 0;

    wait (died); @(posedge clk); #1;
    check(died_seat_l == 0, "ctx0 died");
    check(died_fault_l == 0, "clean halt, no fault");
    check(saw_arg == 1, "callee bundle ran once");
    check(saw_r1 == 1, "r1 check ran");
    check(saw_r2 == 1, "r2 check ran");
    check(saw_r5 == 1, "r5 check ran");
    check(dbg_st0 == 6, "ctx0 halted");
    check(dbg_st1 == 1, "ctx1 still running");
    check(saw_ctx1 > 3, "ctx1 looped concurrently throughout");

    if (errors == 0) $display("__M3_PASS5_INT_OK__");
    else $display("__M3_PASS5_INT_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("__M3_PASS5_INT_TIMEOUT__ pc=%0d st0=%0d", x_pc, dbg_st0);
    $finish;
  end
endmodule
