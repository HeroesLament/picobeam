// M3 pass 7 testbench — spawn and self, end to end.
//
//   cd _emit/m3 && iverilog -o tb7.vvp ../../scripts/tb_m3_pass7.v \
//     barrel_seq.v seat_unit.v proc_table.v run_queue.v reg_window_ctx.v \
//     && vvp tb7.vvp
//
// root (pc 200):  200 r1 = self
//                 201 arg r0 = <a value unique to this spawn>
//                 202 spawn r2, child        <- parks, commits at an F slot
//                 203 read r2 (the newborn's pid)
//                 204 jmp 201, or halt once it has spawned enough
//
// child (pc 300): 300 read r0   <- the staged arg, delivered through the
//                                  save area by the ordinary seat-in path
//                 301 self      <- must equal the pid the PARENT received
//                 302 halt
//
// The closing invariant is the good one: the pid handed to the parent by
// `spawn` is bit-for-bit the pid the child later reports for `self`, and
// the argument the parent staged is the argument the child wakes up with.
//
// Prints __M3_PASS7_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;
  reg boot = 1;

  localparam N_SPAWN = 8;

  // ---- BarrelSeq ----
  reg is_jump = 0, is_halt = 0, is_spawn = 0;
  reg [8:0] pc_target = 0;
  wire [1:0] f_seat, d_seat, x_seat, commit_seat, fill_seat, died_seat, spawn_seat;
  wire f_en, d_en, x_en, call_commit, pop_en, fill_en, dest_wr, wb2_en;
  wire died, died_fault, spawn_commit;
  wire [8:0] f_pc, x_pc, link_pc, f_tgt;
  wire [3:0] fill_idx;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;
  wire seat_wr, seat_clr; wire [1:0] seat_idx; wire [8:0] seat_pc;
  wire spawn_ready, spawn_full;

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
    .is_jump(is_jump), .pc_target(pc_target), .is_call(1'b0),
    .is_ret(1'b0), .is_halt(is_halt), .is_spawn(is_spawn),
    .fault_in(1'b0), .has_wb2(1'b0),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .ret_pc_in(9'd0),
    .is_rpeek(1'b0), .is_rwait_blk(1'b0),
    .is_rtake_long(1'b0), .deser_free(1'b1), .deser_done(1'b0),
    .is_send_long(1'b0), .ser_free(1'b1), .ser_done(1'b0), .ser_done_seat(2'd0),
    .deser_done_seat(2'd0), .take_go(), .take_seat(),
    .scan_free(1'b1), .scan_done(1'b0), .scan_done_seat(2'd0), .scan_hit(1'b0),
    .unblock_en(1'b0), .unblock_seat(2'd0), .kill_en(1'b0), .kill_seat(2'd0), .peek_go(), .peek_seat(), .f_blocked(),
    .spawn_ready(spawn_ready), .spawn_full(spawn_full),
    .f_seat(f_seat), .f_en(f_en), .f_pc(f_pc),
    .d_seat(d_seat), .d_en(d_en), .x_seat(x_seat), .x_en(x_en), .x_pc(x_pc),
    .call_commit(call_commit), .commit_seat(commit_seat), .link_pc(link_pc),
    .pop_en(pop_en), .fill_en(fill_en), .fill_idx(fill_idx), .fill_seat(fill_seat),
    .dest_wr(dest_wr), .wb2_en(wb2_en),
    .spawn_commit(spawn_commit), .spawn_seat(spawn_seat), .f_tgt(f_tgt),
    .died(died), .died_seat(died_seat), .died_fault(died_fault),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  // engine glue: the spawn's rd register, latched per seat at X
  reg [3:0] rdl [0:3];
  always @(posedge clk) if (x_en && is_spawn) rdl[x_seat] <= 4'd2;
  wire [3:0] spawn_rd_now = rdl[f_seat];

  // ---- SeatUnit ----
  wire [2:0] su_cmd; wire [4:0] su_slot; wire [8:0] su_pc;
  wire su_rq_push, su_rq_pop; wire [4:0] su_rq_data;
  wire op_swap, op_spawn; wire [1:0] swap_ctx, sp_ctx;
  wire sfill_en; wire [3:0] sfill_idx; wire [1:0] sfill_seat; wire [35:0] sfill_data;
  wire [4:0] slot0, slot1, slot2, slot3, x_slot, pt_rd_slot;
  wire [21:0] x_serial; wire [35:0] self_pid;
  wire pid_wr; wire [1:0] pid_seat; wire [3:0] pid_reg; wire [35:0] pid_data;
  wire [2:0] su_st; wire [7:0] su_swaps;
  wire su_rst = rst | boot;

  // the remote-creation port (`notes/49`): no ring here, so it is tied
  // off. An unconnected input floats to x and takes every branch that
  // reads it along.
  seat_unit su(.rsp_req(1'b0), .rsp_pc(9'd0), .rsp_arg_d(36'd0),
    .clk(clk), .rst(su_rst), .gc_en(1'b0), .gc_slot(5'd0), .gc_idx(4'd0), .gc_wr(1'b0), .gc_data(36'd0), .eng_id(4'd0), .budget(6'd24),
    .f_seat(f_seat), .f_pc(f_pc), .f_run(f_en), .f_blocked(1'b0), .d_seat(d_seat),
    .x_en(x_en), .x_seat(x_seat), .is_yield_x(1'b0),
    .died(died), .died_seat(died_seat), .death_reason(8'd0),
    .spawn_commit(spawn_commit), .spawn_seat(spawn_seat),
    .spawn_pc(f_tgt), .spawn_rd(spawn_rd_now),
    .spawn_ready(spawn_ready), .spawn_full(spawn_full),
    .op_spawn(op_spawn), .sp_ctx(sp_ctx),
    .pid_wr(pid_wr), .pid_seat(pid_seat), .pid_reg(pid_reg), .pid_data(pid_data),
    .seat_wr(seat_wr), .seat_clr(seat_clr), .seat_idx(seat_idx), .seat_pc(seat_pc),
    .pt_cmd(su_cmd), .pt_slot(su_slot), .pt_pc(su_pc), .pt_rd_slot(pt_rd_slot),
    .pt_rd_pc(pt_rd_pc), .pt_rd_serial(pt_rd_serial),
    .pt_alloc_slot(alloc_slot), .pt_alloc_serial(alloc_serial), .pt_occ(occ),
    .rq_push(su_rq_push), .rq_push_data(su_rq_data), .rq_pop(su_rq_pop),
    .rq_head(rq_head), .rq_empty(rq_empty),
    .op_swap(op_swap), .swap_ctx(swap_ctx), .drain_ready(drain_ready),
    .spill_valid(spill_valid), .spill_idx(spill_idx), .spill_data(spill_data),
    .sfill_en(sfill_en), .sfill_idx(sfill_idx), .sfill_seat(sfill_seat),
    .sfill_data(sfill_data),
    .slot0(slot0), .slot1(slot1), .slot2(slot2), .slot3(slot3),
    .x_slot(x_slot), .x_serial(x_serial), .self_pid(self_pid),
    .dbg_st(su_st), .dbg_swaps(su_swaps));

  // ---- ProcTable / RunQueue ----
  reg [2:0] tb_cmd = 0; reg [8:0] tb_pc = 0;
  wire [2:0] pt_cmd  = boot ? tb_cmd : su_cmd;
  wire [4:0] pt_slot = boot ? 5'd0   : su_slot;
  wire [8:0] pt_pc   = boot ? tb_pc  : su_pc;
  wire alloc_ok; wire [4:0] alloc_slot; wire [21:0] alloc_serial;
  wire [8:0] pt_rd_pc; wire [21:0] pt_rd_serial; wire [1:0] pt_rd_state; wire [5:0] occ;

  proc_table pt(.clk(clk), .rst(rst), .cmd(pt_cmd), .cmd_slot(pt_slot), .cmd_pc(pt_pc),
    .alloc_ok(alloc_ok), .alloc_slot(alloc_slot), .alloc_serial(alloc_serial),
    .rd_slot(pt_rd_slot), .rd_pc(pt_rd_pc), .rd_serial(pt_rd_serial),
    .rd_state(pt_rd_state), .occ(occ));

  reg tb_push = 0;
  wire rq_push       = boot ? tb_push   : su_rq_push;
  wire [4:0] rq_data = boot ? alloc_slot: su_rq_data;
  wire rq_pop        = boot ? 1'b0      : su_rq_pop;
  wire [4:0] rq_head; wire rq_empty, rq_full; wire [5:0] rq_count;

  run_queue rq(.clk(clk), .rst(rst), .push(rq_push), .push_data(rq_data),
    .pop(rq_pop), .q_head(rq_head), .empty(rq_empty), .full(rq_full), .count(rq_count));

  // ---- window ----
  reg [3:0] rd_addr0 = 0;
  reg w_en0_p = 0, w_stg0_p = 0; reg [3:0] w_addr0_p = 0; reg [35:0] w_data0_p = 0;
  wire [35:0] rd_data0;
  wire drain_ready, drain_done; wire [1:0] drain_done_seat, spill_seat;
  wire spill_valid; wire [3:0] spill_idx; wire [35:0] spill_data;

  reg sfw_en = 0; reg [3:0] sfw_idx = 0; reg [1:0] sfw_seat = 0;
  always @(posedge clk) begin
    sfw_en <= sfill_en; sfw_idx <= sfill_idx; sfw_seat <= sfill_seat;
  end

  // port 0: swap-in fill, then the spawn pid write-back, then the bundle
  wire [1:0] w_ctx_sel    = sfw_en ? sfw_seat : (pid_wr ? pid_seat : x_seat);
  wire w_en0_all          = sfw_en | pid_wr | w_en0_p;
  wire w_stg0_all         = (sfw_en | pid_wr) ? 1'b0 : w_stg0_p;
  wire [3:0] w_addr0_all  = sfw_en ? sfw_idx : (pid_wr ? pid_reg : w_addr0_p);
  wire [35:0] w_data0_all = sfw_en ? sfill_data : (pid_wr ? pid_data : w_data0_p);

  reg_window_ctx w(.clk(clk), .rst(rst), .rd_stg0(1'b0),
    .rd_ctx(d_seat), .rd_addr0(rd_addr0), .rd_addr1(4'd0), .rd_addr2(4'd0),
    .rd_addr3(4'd0), .rd_addr4(4'd0), .rd_addr5(4'd0),
    .rd_data0(rd_data0), .rd_data1(), .rd_data2(), .rd_data3(), .rd_data4(), .rd_data5(),
    .w_ctx(w_ctx_sel), .w_en0(w_en0_all), .w_stg0(w_stg0_all),
    .w_addr0(w_addr0_all), .w_data0(w_data0_all),
    .w_en1(1'b0), .w_stg1(1'b0), .w_addr1(4'd0), .w_data1(36'd0),
    .w_en2(1'b0), .w_stg2(1'b0), .w_addr2(4'd0), .w_data2(36'd0),
    .op_call(1'b0), .call_ctx(2'd0), .op_tail(1'b0), .tail_ctx(2'd0),
    .op_swap(op_swap), .swap_ctx(swap_ctx), .op_spawn(op_spawn), .spawn_ctx(sp_ctx),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .spill_valid(spill_valid),
    .spill_idx(spill_idx), .spill_data(spill_data), .spill_seat(spill_seat));

  // ---- the program ----
  reg [8:0] d_pc = 0;
  always @(posedge clk) d_pc <= f_pc;

  integer spawned = 0;

  always @(*) begin
    is_jump = 0; is_halt = 0; is_spawn = 0; pc_target = 0;
    case (x_pc)
      9'd202: begin is_spawn = 1; pc_target = 9'd300; end
      9'd204: if (spawned >= N_SPAWN) is_halt = 1;
              else begin is_jump = 1; pc_target = 9'd201; end
      9'd302: is_halt = 1;
    endcase
  end

  always @(*) begin
    rd_addr0 = 0;
    case (d_pc)
      9'd203: rd_addr0 = 4'd2;   // the pid spawn returned
      9'd300: rd_addr0 = 4'd0;   // the staged argument
    endcase
  end

  always @(*) begin
    w_en0_p = 0; w_stg0_p = 0; w_addr0_p = 0; w_data0_p = 0;
    if (x_en) begin
      case (x_pc)
        9'd200: begin w_en0_p = 1; w_addr0_p = 4'd1; w_data0_p = self_pid; end
        9'd201: begin w_en0_p = 1; w_stg0_p = 1; w_addr0_p = 4'd0;
                      w_data0_p = 36'h100 + spawned; end
        9'd301: begin w_en0_p = 1; w_addr0_p = 4'd3; w_data0_p = self_pid; end
      endcase
    end
  end

  // ---- monitors ----
  integer errors = 0, i;
  reg [35:0] exp_pid [0:31];
  reg [35:0] exp_arg [0:31];
  integer arg_ok = 0, pid_ok = 0, kids_done = 0, root_self_ok = 0;
  reg [35:0] last_pid = 0;

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  always @(posedge clk) if (!rst && !boot) begin
    // record what the parent was promised, keyed by the newborn's slot
    if (pid_wr) begin
      last_pid = pid_data;
      exp_pid[pid_data[27:22]] = pid_data;
      exp_arg[pid_data[27:22]] = 36'h100 + spawned;
      spawned = spawned + 1;
    end
    if (x_en) begin
      case (x_pc)
        9'd200: begin
          root_self_ok = root_self_ok + 1;
          check(self_pid[35:32] == 4'h5, "self carries the pid tag");
          check(self_pid[27:22] == x_slot, "self reports the running slot");
        end
        9'd203: begin
          check(rd_data0[35:32] == 4'h5, "spawn returned a pid-tagged word");
          check(rd_data0 == last_pid, "spawn's rd holds the newborn's pid");
        end
        9'd300: begin
          arg_ok = arg_ok + 1;
          check(rd_data0 == exp_arg[x_slot], "child woke with the arg its parent staged");
        end
        9'd301: begin
          pid_ok = pid_ok + 1;
          check(self_pid == exp_pid[x_slot], "child's self == the pid spawn handed the parent");
        end
      endcase
    end
    if (died && !died_fault) kids_done = kids_done + 1;
  end

  initial begin
    for (i = 0; i < 32; i = i + 1) begin exp_pid[i]=0; exp_arg[i]=0; end
    for (i = 0; i < 4; i = i + 1) rdl[i] = 0;
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

    // one root process, entering at pc 200
    @(negedge clk); tb_cmd = 3'd1; tb_pc = 9'd200; tb_push = 1;
    @(posedge clk); #1; tb_cmd = 0; tb_push = 0;
    check(occ == 1, "root allocated");

    @(negedge clk); boot = 0; @(posedge clk); #1;

    repeat (20000) @(posedge clk); #1;

    check(spawned == N_SPAWN, "all spawns committed");
    check(arg_ok == N_SPAWN, "every child checked its argument");
    check(pid_ok == N_SPAWN, "every child checked its identity");
    check(root_self_ok == 1, "root ran self once");
    check(kids_done >= N_SPAWN, "children reached halt");

    $display("spawned=%0d args_ok=%0d pids_ok=%0d deaths=%0d occ=%0d swaps=%0d",
      spawned, arg_ok, pid_ok, kids_done, occ, su_swaps);

    if (errors == 0) $display("__M3_PASS7_OK__");
    else $display("__M3_PASS7_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #3000000;
    $display("__M3_PASS7_TIMEOUT__ spawned=%0d st=%0d occ=%0d", spawned, su_st, occ);
    $finish;
  end
endmodule
