// M3 pass 4 testbench — RegWindowCtx under iverilog.
//
//   cd _emit/m3 && iverilog -o tb4.vvp ../../scripts/tb_m3_pass4.v \
//     reg_window_ctx.v && vvp tb4.vvp
//
// Checks: per-context isolation, LVT bank selection per context, the
// call rename + background drain (data + handshake), staged args
// arriving in the callee's window, writes during another context's
// drain, ret-fill-style port-0 restore, and the tail swap.
//
// Prints __M3_PASS4_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg [1:0] rd_ctx = 0, w_ctx = 0, call_ctx = 0, tail_ctx = 0;
  reg [3:0] rd_addr0 = 0, rd_addr1 = 0, rd_addr2 = 0, rd_addr3 = 0, rd_addr4 = 0, rd_addr5 = 0;
  reg w_en0 = 0, w_stg0 = 0, w_en1 = 0, w_stg1 = 0, w_en2 = 0, w_stg2 = 0;
  reg [3:0] w_addr0 = 0, w_addr1 = 0, w_addr2 = 0;
  reg [35:0] w_data0 = 0, w_data1 = 0, w_data2 = 0;
  reg op_call = 0, op_tail = 0, op_swap = 0;

  wire [35:0] rd_data0, rd_data1, rd_data2, rd_data3, rd_data4, rd_data5, spill_data;
  wire drain_ready, drain_done, spill_valid;
  wire [1:0] drain_done_seat, spill_seat;
  wire [3:0] spill_idx;

  reg_window_ctx w(.clk(clk), .rst(rst), .rd_stg0(1'b0),
    .rd_ctx(rd_ctx), .rd_addr0(rd_addr0), .rd_addr1(rd_addr1),
    .rd_addr2(rd_addr2), .rd_addr3(rd_addr3), .rd_addr4(rd_addr4),
    .rd_addr5(rd_addr5),
    .rd_data0(rd_data0), .rd_data1(rd_data1), .rd_data2(rd_data2),
    .rd_data3(rd_data3), .rd_data4(rd_data4), .rd_data5(rd_data5),
    .w_ctx(w_ctx),
    .w_en0(w_en0), .w_stg0(w_stg0), .w_addr0(w_addr0), .w_data0(w_data0),
    .w_en1(w_en1), .w_stg1(w_stg1), .w_addr1(w_addr1), .w_data1(w_data1),
    .w_en2(w_en2), .w_stg2(w_stg2), .w_addr2(w_addr2), .w_data2(w_data2),
    .op_call(op_call), .call_ctx(call_ctx), .op_tail(op_tail), .tail_ctx(tail_ctx),
    .op_swap(op_swap), .swap_ctx(call_ctx), .op_spawn(1'b0), .spawn_ctx(2'd0),
    .drain_ready(drain_ready), .drain_done(drain_done),
    .drain_done_seat(drain_done_seat), .spill_valid(spill_valid),
    .spill_idx(spill_idx), .spill_data(spill_data), .spill_seat(spill_seat));

  integer errors = 0;
  integer i;
  reg [35:0] spilled [0:15];

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  // write one register via port p in ctx c (cur or stg)
  task wr(input [1:0] c, input integer port, input stg, input [3:0] a, input [35:0] d);
    begin
      @(negedge clk);
      w_ctx = c;
      case (port)
        0: begin w_en0 = 1; w_stg0 = stg; w_addr0 = a; w_data0 = d; end
        1: begin w_en1 = 1; w_stg1 = stg; w_addr1 = a; w_data1 = d; end
        2: begin w_en2 = 1; w_stg2 = stg; w_addr2 = a; w_data2 = d; end
      endcase
      @(posedge clk); #1;
      w_en0 = 0; w_en1 = 0; w_en2 = 0;
    end
  endtask

  // sync-read: present the address, let the EBR register it, sample
  task rd(input [1:0] c, input [3:0] a);
    begin
      @(negedge clk);
      rd_ctx = c; rd_addr0 = a;
      @(posedge clk); #1;
    end
  endtask

  // capture a full drain into spilled[]
  always @(posedge clk) if (spill_valid) spilled[spill_idx] <= spill_data;

  initial begin
    for (i = 0; i < 256; i = i + 1) begin
      w.b0r0[i]=0; w.b0r1[i]=0; w.b0r2[i]=0; w.b0r3[i]=0; w.b0r4[i]=0; w.b0r5[i]=0; w.b0r6[i]=0;
      w.b1r0[i]=0; w.b1r1[i]=0; w.b1r2[i]=0; w.b1r3[i]=0; w.b1r4[i]=0; w.b1r5[i]=0; w.b1r6[i]=0;
      w.b2r0[i]=0; w.b2r1[i]=0; w.b2r2[i]=0; w.b2r3[i]=0; w.b2r4[i]=0; w.b2r5[i]=0; w.b2r6[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---- 1. isolation + LVT bank selection ----
    wr(0, 0, 0, 4'd3, 36'd111);      // ctx0 r3 via port0 (bank0)
    wr(1, 1, 0, 4'd3, 36'd222);      // ctx1 r3 via port1 (bank1)
    wr(2, 2, 0, 4'd3, 36'd333);      // ctx2 r3 via port2 (bank2)
    rd(0, 4'd3); check(rd_data0 == 111, "ctx0 r3 = 111");
    rd(1, 4'd3); check(rd_data0 == 222, "ctx1 r3 = 222 (bank1)");
    rd(2, 4'd3); check(rd_data0 == 333, "ctx2 r3 = 333 (bank2)");
    rd(3, 4'd3); check(rd_data0 == 0,   "ctx3 r3 untouched");

    // last-writer-wins within one ctx: rewrite ctx1 r3 via port0
    wr(1, 0, 0, 4'd3, 36'd223);
    rd(1, 4'd3); check(rd_data0 == 223, "ctx1 r3 rewrite via bank0");
    rd(0, 4'd3); check(rd_data0 == 111, "ctx0 r3 unaffected");

    // ---- 2. call rename + drain, staged arg reaches the callee ----
    // ctx0: fill some cur regs, stage an arg, then commit a call
    wr(0, 0, 0, 4'd0, 36'd10);       // caller r0 = 10
    wr(0, 1, 0, 4'd5, 36'd55);       // caller r5 = 55 (bank1)
    wr(0, 0, 1, 4'd0, 36'd9);        // arg 0 -> staging r0 = 9
    check(drain_ready == 1, "drain idle before call");
    @(negedge clk); op_call = 1; call_ctx = 0; @(posedge clk); #1; op_call = 0;
    check(drain_ready == 0, "drain busy after commit");

    // callee window: staged arg visible in new cur
    rd(0, 4'd0); check(rd_data0 == 9, "callee sees staged arg r0=9");

    // drain completes with the caller's frame
    wait (drain_done); #1;
    check(drain_done_seat == 0, "drain done seat 0");
    @(posedge clk); #1;
    check(drain_ready == 1, "drain idle after done");
    check(spilled[0] == 10, "spill r0 = 10");
    check(spilled[5] == 55, "spill r5 = 55 (via bank1 lvt)");
    check(spilled[3] == 111, "spill r3 = 111");

    // ---- 3. writes in ctx2 during a ctx1 drain ----
    wr(1, 0, 0, 4'd7, 36'd77);
    @(negedge clk); op_call = 1; call_ctx = 1; @(posedge clk); #1; op_call = 0;
    wr(2, 0, 0, 4'd8, 36'd88);       // mid-drain write, other ctx
    rd(2, 4'd8); check(rd_data0 == 88, "ctx2 write lands mid-drain");
    wait (drain_done); #1;
    check(drain_done_seat == 1, "drain done seat 1");
    check(spilled[7] == 77, "ctx1 spill r7 = 77");
    @(posedge clk); #1;

    // ---- 4. ret-fill-style restore through port 0 into ctx0 cur ----
    wr(0, 0, 0, 4'd0, 36'd10);       // restore r0
    wr(0, 0, 0, 4'd5, 36'd55);       // restore r5 (now bank0 -> LVT retarget)
    rd(0, 4'd0); check(rd_data0 == 10, "restored r0");
    rd(0, 4'd5); check(rd_data0 == 55, "restored r5 via bank0");

    // ---- 5. tail swap: stage then promote ----
    wr(3, 0, 1, 4'd0, 36'd42);       // ctx3 staging r0 = 42
    @(negedge clk); op_tail = 1; tail_ctx = 3; @(posedge clk); #1; op_tail = 0;
    rd(3, 4'd0); check(rd_data0 == 42, "tail promoted staging r0=42");
    rd(0, 4'd0); check(rd_data0 == 10, "ctx0 unaffected by ctx3 tail");

    // ---- 6. swap-out drains CUR (not spl) with no rename ----
    wr(1, 0, 0, 4'd2, 36'd1234);     // ctx1 cur r2
    @(negedge clk); op_swap = 1; call_ctx = 1; @(posedge clk); #1; op_swap = 0;
    wait (drain_done); #1;
    check(drain_done_seat == 1, "swap drain seat 1");
    check(spilled[2] == 1234, "swap-out drained CUR r2 = 1234");
    @(posedge clk); #1;
    rd(1, 4'd2); check(rd_data0 == 1234, "ctx1 window unrenamed after swap-out");

    if (errors == 0) $display("__M3_PASS4_OK__");
    else $display("__M3_PASS4_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #50000;
    $display("__M3_PASS4_TIMEOUT__");
    $finish;
  end
endmodule
