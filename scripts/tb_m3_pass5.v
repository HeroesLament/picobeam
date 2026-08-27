// M3 pass 5 testbench — FrameRamProc under iverilog.
//
//   cd _emit/m3 && iverilog -o tb5.vvp ../../scripts/tb_m3_pass5.v \
//     frame_ram_proc.v && vvp tb5.vvp
//
// Checks: push/spill/pop/fill round-trip, link lockstep, LIFO nesting
// to depth 2, per-slot isolation, the depth-8 overflow fault, and
// pop underflow on an empty slot.
//
// Prints __M3_PASS5_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg push_en = 0, pop_en = 0, spill_valid = 0, fill_en = 0;
  reg [4:0] push_slot = 0, pop_slot = 0, fill_slot = 0;
  reg [8:0] push_pc = 0;
  reg [3:0] push_dest = 0, spill_idx = 0, fill_idx = 0;
  reg [35:0] spill_data = 0;

  wire [35:0] fill_data;
  wire [8:0] ret_pc_out;
  wire [3:0] ret_dest_out, depth_out;
  wire overflow, underflow;

  frame_ram_proc fr(.clk(clk), .rst(rst),
    // notes/40: the collector's addressed port. Tied off here — these
    // passes predate the walker — but tied off EXPLICITLY, because an
    // unconnected `gc_wr` floats to x and takes the write mux with it.
    .gc_en(1'b0), .gc_slot(5'd0), .gc_depth(4'd0), .gc_idx(4'd0),
    .gc_wr(1'b0), .gc_data(36'd0), .gc_q(),
    // notes/32: the absolute pop a caught fault uses to discard several
    // frames at once. Tied off: these passes only ever pop one.
    .pop_abs(1'b0), .pop_to(4'd0), .q_slot(5'd0), .q_depth(),
    .push_en(push_en), .push_slot(push_slot), .push_pc(push_pc),
    .push_dest(push_dest),
    .spill_valid(spill_valid), .spill_idx(spill_idx), .spill_data(spill_data),
    .pop_en(pop_en), .pop_slot(pop_slot),
    .fill_en(fill_en), .fill_idx(fill_idx), .fill_slot(fill_slot),
    .fill_data(fill_data), .ret_pc_out(ret_pc_out), .ret_dest_out(ret_dest_out),
    .overflow(overflow), .underflow(underflow), .depth_out(depth_out));

  integer errors = 0;
  integer i;
  reg [35:0] got [0:15];

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  task do_push(input [4:0] s, input [8:0] pc, input [3:0] d);
    begin
      @(negedge clk);
      push_en = 1; push_slot = s; push_pc = pc; push_dest = d;
      @(posedge clk); #1;
      push_en = 0;
    end
  endtask

  task do_pop(input [4:0] s);
    begin
      @(negedge clk);
      pop_en = 1; pop_slot = s;
      @(posedge clk); #1;
      pop_en = 0;
    end
  endtask

  // drain a 16-word frame in (base + idx as the payload)
  task do_spill(input [35:0] base);
    begin
      for (i = 0; i < 16; i = i + 1) begin
        @(negedge clk);
        spill_valid = 1; spill_idx = i[3:0]; spill_data = base + i;
        @(posedge clk); #1;
      end
      spill_valid = 0;
    end
  endtask

  // read a frame back the way the barrel paces it (sync read: present
  // the index, sample the NEXT cycle)
  task do_fill(input [4:0] s);
    begin
      for (i = 0; i < 16; i = i + 1) begin
        @(negedge clk);
        fill_en = 1; fill_slot = s; fill_idx = i[3:0];
        @(posedge clk); #1;
        got[i] = fill_data;
      end
      fill_en = 0;
    end
  endtask

  initial begin
    for (i = 0; i < 8192; i = i + 1) fr.frames[i] = 0;
    for (i = 0; i < 512; i = i + 1) fr.rets[i] = 0;

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---- 1. single frame round-trip on slot 3 ----
    fill_slot = 3; #1;
    check(depth_out == 0, "slot3 depth starts 0");
    do_push(5'd3, 9'd100, 4'd5);
    fill_slot = 3; #1;
    check(depth_out == 1, "slot3 depth 1 after push");
    check(overflow == 0, "no overflow");
    do_spill(36'd1000);

    do_pop(5'd3);
    fill_slot = 3; #1;
    check(depth_out == 0, "slot3 depth 0 after pop");
    check(ret_pc_out == 100, "link pc 100");
    check(ret_dest_out == 5, "link dest 5");
    do_fill(5'd3);
    check(got[0] == 1000, "fill word 0");
    check(got[7] == 1007, "fill word 7");
    check(got[15] == 1015, "fill word 15");

    // ---- 2. LIFO nesting to depth 2 on slot 3 ----
    do_push(5'd3, 9'd200, 4'd6); do_spill(36'd2000);
    do_push(5'd3, 9'd300, 4'd7); do_spill(36'd3000);
    fill_slot = 3; #1;
    check(depth_out == 2, "slot3 depth 2 nested");

    do_pop(5'd3);
    fill_slot = 3; #1;
    check(ret_pc_out == 300, "inner link pc 300");
    check(ret_dest_out == 7, "inner link dest 7");
    do_fill(5'd3);
    check(got[3] == 3003, "inner frame word 3");

    do_pop(5'd3);
    fill_slot = 3; #1;
    check(ret_pc_out == 200, "outer link pc 200");
    check(ret_dest_out == 6, "outer link dest 6");
    do_fill(5'd3);
    check(got[3] == 2003, "outer frame word 3");
    check(depth_out == 0, "slot3 drained to 0");

    // ---- 3. per-slot isolation ----
    do_push(5'd7, 9'd400, 4'd1); do_spill(36'd4000);
    do_push(5'd31, 9'd500, 4'd2); do_spill(36'd5000);
    fill_slot = 7;  #1; check(depth_out == 1, "slot7 depth 1");
    fill_slot = 31; #1; check(depth_out == 1, "slot31 depth 1");
    fill_slot = 3;  #1; check(depth_out == 0, "slot3 still 0");

    do_pop(5'd7);
    do_fill(5'd7);
    check(got[2] == 4002, "slot7 frame intact");
    do_pop(5'd31);
    fill_slot = 31; #1;
    check(ret_pc_out == 500, "slot31 link 500");
    do_fill(5'd31);
    check(got[2] == 5002, "slot31 frame intact (top of memory)");

    // ---- 4. overflow at depth 8 ----
    for (i = 0; i < 15; i = i + 1) do_push(5'd9, 9'd10 + i[8:0], 4'd3);
    fill_slot = 9; #1;
    check(depth_out == 15, "slot9 depth 15");
    @(negedge clk); push_en = 1; push_slot = 5'd9; push_pc = 9'd99; #1;
    check(overflow == 1, "overflow asserted at depth 15");
    @(posedge clk); #1; push_en = 0;
    fill_slot = 9; #1;
    check(depth_out == 15, "depth unchanged after refused push");
    do_pop(5'd9);
    fill_slot = 9; #1;
    check(ret_pc_out == 24, "deepest link intact (10+14)");

    // ---- 5. underflow on an empty slot ----
    @(negedge clk); pop_en = 1; pop_slot = 5'd20; #1;
    check(underflow == 1, "underflow on empty slot");
    @(posedge clk); #1; pop_en = 0;
    fill_slot = 20; #1;
    check(depth_out == 0, "empty slot stays 0");

    if (errors == 0) $display("__M3_PASS5_OK__");
    else $display("__M3_PASS5_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #200000;
    $display("__M3_PASS5_TIMEOUT__");
    $finish;
  end
endmodule
