// M3 pass 3 testbench — BarrelSeq under iverilog.
//
//   cd _emit/m3 && iverilog -o tb3.vvp ../../scripts/tb_m3_pass3.v \
//     barrel_seq.v && vvp tb3.vvp
//
// The TB plays the engine: it serves a scripted "program" (bundle
// classification as a function of x_pc), models the drain unit
// (16-cycle busy after each commit) and the per-seat link stacks
// (FrameRam's rets), and checks:
//
//   1. solo context: pc walk, jump, call (park + commit + link),
//      callee, ret (pop, 16 fill presentations, gap, dest, resume),
//      halt — the full M2 semantics, one seat.
//   2. four contexts: exact 1/T interleave (X slots rotate), deaths
//      land per seat, a wb2 turn strobes with no fetch, a pended
//      call dispatches after wb2, and two rets serialize on the fill
//      stream without overlap.
//
// Program map (by pc, same image for every context):
//   0 plain · 1 plain · 2 jmp 7 · 7 call 50 · 8 halt
//   50 plain · 51 ret
//   100 plain · 101 halt
//   200 wb2(plain) · 201 wb2+call 50 · (ret at 51 returns to 202) · 202 halt
//   300 fault
//
// Prints __M3_PASS3_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg seat_wr = 0;
  reg [1:0] seat_idx = 0;
  reg [8:0] seat_pc = 0;

  reg is_jump = 0, is_call = 0, is_ret = 0, is_halt = 0, fault_in = 0, has_wb2 = 0;
  reg [8:0] pc_target = 0;
  reg drain_ready = 1, drain_done = 0;
  reg [1:0] drain_done_seat = 0;
  reg [8:0] ret_pc_in = 0;

  wire [1:0] f_seat, d_seat, x_seat, commit_seat, fill_seat, died_seat;
  wire f_en, d_en, x_en, call_commit, pop_en, fill_en, dest_wr, wb2_en, died, died_fault;
  wire [8:0] f_pc, x_pc, link_pc;
  wire [3:0] fill_idx;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;

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
    .is_ret(is_ret), .is_halt(is_halt), .fault_in(fault_in),
    .has_wb2(has_wb2), .is_spawn(1'b0),
    .is_rpeek(1'b0), .is_rwait_blk(1'b0),
    .is_rtake_long(1'b0), .deser_free(1'b1), .deser_done(1'b0),
    .is_send_long(1'b0), .ser_free(1'b1), .ser_done(1'b0), .ser_done_seat(2'd0),
    .deser_done_seat(2'd0), .take_go(), .take_seat(),
    .scan_free(1'b1), .scan_done(1'b0), .scan_done_seat(2'd0), .scan_hit(1'b0),
    .unblock_en(1'b0), .unblock_seat(2'd0), .kill_en(1'b0), .kill_seat(2'd0), .peek_go(), .peek_seat(), .f_blocked(),
    .spawn_ready(1'b0), .spawn_full(1'b0), .spawn_commit(), .spawn_seat(), .f_tgt(),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .ret_pc_in(ret_pc_in),
    .f_seat(f_seat), .f_en(f_en), .f_pc(f_pc),
    .d_seat(d_seat), .d_en(d_en),
    .x_seat(x_seat), .x_en(x_en), .x_pc(x_pc),
    .call_commit(call_commit), .commit_seat(commit_seat), .link_pc(link_pc),
    .pop_en(pop_en), .fill_en(fill_en), .fill_idx(fill_idx),
    .fill_seat(fill_seat), .dest_wr(dest_wr), .wb2_en(wb2_en),
    .died(died), .died_seat(died_seat), .died_fault(died_fault),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  // ---- the scripted program: classification from x_pc ----
  always @(*) begin
    is_jump = 0; is_call = 0; is_ret = 0; is_halt = 0;
    fault_in = 0; has_wb2 = 0; pc_target = 0;
    case (x_pc)
      9'd2:   begin is_jump = 1; pc_target = 9'd7; end
      9'd7:   begin is_call = 1; pc_target = 9'd50; end
      9'd8:   is_halt = 1;
      9'd51:  is_ret = 1;
      9'd101: is_halt = 1;
      9'd200: has_wb2 = 1;
      9'd201: begin has_wb2 = 1; is_call = 1; pc_target = 9'd50; end
      9'd202: is_halt = 1;
      9'd300: fault_in = 1;
      default: ;
    endcase
  end

  // ---- drain unit model: busy 16 cycles after each commit ----
  reg [4:0] drain_cnt = 16;
  reg [1:0] drain_seat_r = 0;
  always @(posedge clk) begin
    drain_done <= 0;
    if (call_commit) begin
      drain_cnt <= 0; drain_seat_r <= commit_seat;
    end else if (drain_cnt < 16) begin
      drain_cnt <= drain_cnt + 1;
      if (drain_cnt == 15) begin
        drain_done <= 1; drain_done_seat <= drain_seat_r;
      end
    end
  end
  always @(*) drain_ready = (drain_cnt == 16);

  // ---- per-seat link stacks (FrameRam's rets, modeled) ----
  reg [8:0] lstack [0:3][0:3];
  integer lsp [0:3];
  always @(posedge clk) begin
    if (call_commit) begin
      lstack[commit_seat][lsp[commit_seat]] <= link_pc;
      lsp[commit_seat] <= lsp[commit_seat] + 1;
    end
    if (pop_en) begin
      lsp[f_seat] <= lsp[f_seat] - 1;
      ret_pc_in <= lstack[f_seat][lsp[f_seat] - 1];
    end
  end

  // ---- monitors ----
  integer errors = 0;
  integer commits = 0, pops = 0, fills = 0, dests = 0, wb2s = 0, deaths = 0;
  integer fault_deaths = 0;
  reg [8:0] last_link = 0;
  reg [1:0] last_died_seat = 0;
  integer xcount [0:3];
  integer fill_owner_locked;
  reg [1:0] fill_owner_seen = 0;
  integer expected_idx = 0;

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  integer warm = 0;
  always @(posedge clk) if (!rst) begin
    warm = warm + 1;
    if (call_commit) begin commits = commits + 1; last_link = link_pc; end
    if (pop_en) pops = pops + 1;
    if (fill_en) begin
      // fill indices must present 0..15 in order, one owner at a time
      check(fill_idx == expected_idx[3:0], "fill idx in order");
      if (fills == 0 || expected_idx == 0) fill_owner_seen = fill_seat;
      check(fill_seat == fill_owner_seen, "fill owner stable");
      fills = fills + 1;
      expected_idx = (expected_idx == 15) ? 0 : expected_idx + 1;
    end
    if (dest_wr) dests = dests + 1;
    if (wb2_en) begin
      wb2s = wb2s + 1;
      check(x_en == 0, "wb2 turn has no live bundle");
    end
    if (died) begin
      deaths = deaths + 1;
      last_died_seat = died_seat;
      if (died_fault) fault_deaths = fault_deaths + 1;
    end
    if (x_en) xcount[x_seat] = xcount[x_seat] + 1;
    // the structural invariant: stages carry seat-2 alignment
    // (skip the 2-cycle pipeline warm-up after reset)
    if (warm > 2) check(x_seat == f_seat - 2'd2, "x_seat = f_seat - 2");
  end

  integer i;
  initial begin
    for (i = 0; i < 4; i = i + 1) begin xcount[i] = 0; lsp[i] = 0; end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---------- run 1: solo ctx0 through the whole program ----------
    // wait for ctx0's F slot, then activate at pc 0
    wait (f_seat == 0); @(negedge clk);
    seat_wr = 1; seat_idx = 0; seat_pc = 0; @(posedge clk); #1; seat_wr = 0;

    // program: 0,1,jmp->7, call 50 (link 8), 50, ret -> fill -> 8, halt
    wait (died); @(posedge clk); #1;
    check(last_died_seat == 0, "solo: ctx0 died");
    check(commits == 1, "solo: one commit");
    check(last_link == 8, "solo: link pc 8");
    check(pops == 1, "solo: one pop");
    check(fills == 16, "solo: 16 fill presentations");
    check(dests == 1, "solo: one dest write");
    check(dbg_st0 == 6, "solo: ctx0 halted");
    check(fault_deaths == 0, "solo: no fault");
    @(posedge clk); #1;

    // ---------- run 2: four contexts ----------
    // ctx0: full call/ret program again (re-seat at 0)
    // ctx1: 100,101 halt   ctx2: 300 fault   ctx3: 200 wb2, 201 wb2+call,
    //       callee 50,51 ret -> 202 halt
    commits = 0; pops = 0; fills = 0; dests = 0; deaths = 0; wb2s = 0;
    fault_deaths = 0; expected_idx = 0;
    for (i = 0; i < 4; i = i + 1) xcount[i] = 0;

    @(negedge clk); seat_wr = 1; seat_idx = 0; seat_pc = 0; @(posedge clk); #1;
    seat_idx = 1; seat_pc = 9'd100; @(posedge clk); #1;
    seat_idx = 2; seat_pc = 9'd300; @(posedge clk); #1;
    seat_idx = 3; seat_pc = 9'd200; @(posedge clk); #1;
    seat_wr = 0;

    // let everything run to completion
    repeat (400) @(posedge clk);
    #1;
    check(deaths == 4, "quad: four deaths");
    check(fault_deaths == 1, "quad: exactly one fault death");
    check(dbg_st0 == 6, "quad: ctx0 halted");
    check(dbg_st1 == 6, "quad: ctx1 halted");
    check(dbg_st2 == 7, "quad: ctx2 faulted");
    check(dbg_st3 == 6, "quad: ctx3 halted");
    check(commits == 2, "quad: two commits (ctx0 + ctx3 pended)");
    check(pops == 2, "quad: two pops");
    check(fills == 32, "quad: two full fill streams");
    check(dests == 2, "quad: two dest writes");
    check(wb2s == 2, "quad: two wb2 turns");
    // 1/T fairness in the active window: ctx1 executed exactly its two
    // bundles; ctx2 exactly one
    check(xcount[1] == 2, "quad: ctx1 issued 2");
    check(xcount[2] == 1, "quad: ctx2 issued 1");

    if (errors == 0) $display("__M3_PASS3_OK__");
    else $display("__M3_PASS3_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("__M3_PASS3_TIMEOUT__");
    $finish;
  end
endmodule
