// The engine heap, asked directly.
//
//   scripts/run_tbs.sh tb_heap
//
// `heap.ex` was written at M2 and has never been instantiated, so
// nothing has ever exercised it. It is also full of 36-bit tag
// literals — 0x300000000 for CONS, 0x400000000 for TUPLE,
// 0x900000000 for the tuple header — every one of which the ehdl
// const-width bug (notes/21) was truncating to ZERO. Before that fix
// every pointer this unit produced was tagged INT. So this testbench
// is asking two questions at once: does the heap work, and did it
// ever.
//
// Cells, not words: `notes/03` specified a uniform two-word cell and
// the RTL addresses cells while `machine.ex` addresses words. Pointer
// PAYLOADS therefore differ between model and gates by design (logged
// in notes/15) — so everything checked here is either a tag, a
// structural relationship, or an immediate that came back out.
//
// Prints __HEAP_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg cmd_en = 0;
  reg [3:0] cmd = 7;
  reg [35:0] pa = 0, pb = 0;
  reg [7:0] i8 = 0;
  reg flip_en = 0;

  wire [35:0] rd_late;
  wire fault;
  wire [7:0] fault_reason;
  wire [7:0] hp_out;
  wire heap_full;
  wire [35:0] b_q0, b_q1;

  heap u(.clk(clk), .rst(rst),
    .cmd_en(cmd_en), .cmd(cmd), .pa(pa), .pb(pb), .i8(i8),
    .rd_late(rd_late), .fault(fault), .fault_reason(fault_reason),
    .hp_out(hp_out), .heap_full(heap_full),
    .b_en(1'b0), .b_addr(8'd0), .b_wr0(1'b0), .b_wr1(1'b0), .b_d0(36'd0), .b_d1(36'd0),
    .b_q0(b_q0), .b_q1(b_q1),
    .flip_en(flip_en), .flip_aptr(8'd0));

  integer errors = 0, checks = 0;

  // term constructors, matching PicoBEAM.Term
  function [35:0] iw(input signed [31:0] v); iw = {4'h0, v}; endfunction
  function [35:0] aw(input [31:0] v); aw = {4'h1, v}; endfunction
  localparam [35:0] NILW = {4'h2, 32'd0};

  task check(input cond, input [255:0] name);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  // issue one heap command; the result lands on rd_late the NEXT cycle
  reg [35:0] got;
  reg gfault;
  reg [7:0] greason;
  // `fault` is combinational on cmd_en, so it is sampled while the
  // command is still presented. `rd_late` is valid in the cycle AFTER
  // the command edge — cmd_d, bank_d and the sync reads q0/q1 all land
  // on that same edge — so it is sampled immediately after it, not a
  // cycle later. Sampling late reads the NEXT address's data, which is
  // invisible for hd/tl and tget 0 (whose read address happens to equal
  // the idle one) and wrong for every other tget.
  task op(input [2:0] c, input [35:0] a, input [35:0] b, input [7:0] i);
    begin
      @(negedge clk);
      cmd_en = 1; cmd = c; pa = a; pb = b; i8 = i;
      #1; gfault = fault; greason = fault_reason;
      @(posedge clk); #1;
      got = rd_late;
      @(negedge clk); cmd_en = 0; cmd = 7;
      @(posedge clk); #1;
    end
  endtask

  reg [35:0] l0, l1, t0, t1;
  integer k;

  initial begin
    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    check(hp_out == 0, "heap starts empty");

    // ---- cons: one cycle, pointer bump ----
    op(3'd0, iw(7), NILW, 8'd0);          // cons(7, [])
    l0 = got;
    check(l0[35:32] == 4'h3, "cons returns a CONS-tagged pointer");
    check(gfault == 0, "cons does not fault");
    check(hp_out == 1, "cons bumped one cell");

    op(3'd0, iw(8), l0, 8'd0);            // cons(8, l0)
    l1 = got;
    check(l1[35:32] == 4'h3, "second cons is CONS-tagged");
    check(l1[31:0] == 32'd1, "second cons took the next cell");
    check(hp_out == 2, "two cells used");

    // ---- hd / tl walk the list back ----
    op(3'd1, l1, 36'd0, 8'd0);
    check(got == iw(8), "hd([8,7]) is 8");
    op(3'd2, l1, 36'd0, 8'd0);
    check(got == l0, "tl([8,7]) is the tail pointer, unchanged");
    op(3'd1, l0, 36'd0, 8'd0);
    check(got == iw(7), "hd([7]) is 7");
    op(3'd2, l0, 36'd0, 8'd0);
    check(got == NILW, "tl([7]) is NIL");

    // ---- mktup / tset / tget / tarity ----
    op(3'd3, 36'd0, 36'd0, 8'd3);         // mktup arity 3
    t0 = got;
    check(t0[35:32] == 4'h4, "mktup returns a TUPLE-tagged pointer");
    check(hp_out == 4, "a 3-tuple costs two cells (header + 3 words)");

    op(3'd4, t0, iw(100), 8'd0);          // tset 0 <- 100
    op(3'd4, t0, aw(32'd14), 8'd1);       // tset 1 <- 'true'
    op(3'd4, t0, iw(-5), 8'd2);           // tset 2 <- -5

    op(3'd5, t0, 36'd0, 8'd0);
    check(got == iw(100), "tget 0 is 100");
    op(3'd5, t0, 36'd0, 8'd1);
    check(got == aw(32'd14), "tget 1 is the atom, tag intact");
    op(3'd5, t0, 36'd0, 8'd2);
    check(got == iw(-5), "tget 2 is -5, sign intact");

    op(3'd6, t0, 36'd0, 8'd0);
    check(got == iw(3), "tarity is 3, as an INT");

    // index 15 is the encodable ceiling for tset, and the boundary
    // where a four-bit index add would wrap onto the tuple header
    op(3'd3, 36'd0, 36'd0, 8'd16);
    t1 = got;
    op(3'd4, t1, iw(1515), 8'd15);
    op(3'd5, t1, 36'd0, 8'd15);
    check(got == iw(1515), "tset/tget at index 15 round-trips");
    op(3'd6, t1, 36'd0, 8'd0);
    check(got == iw(16), "and did not overwrite the header");

    // ---- a tuple element may be a pointer: nesting works ----
    op(3'd4, t0, l1, 8'd0);
    op(3'd5, t0, 36'd0, 8'd0);
    check(got == l1, "a tuple can hold a cons pointer");
    op(3'd1, got, 36'd0, 8'd0);
    check(got == iw(8), "and it is still walkable");

    // ---- wrong tag traps, and traps as bad_tag (reason 4) ----
    op(3'd1, t0, 36'd0, 8'd0);
    check(gfault == 1 && greason == 8'd4, "hd of a TUPLE is bad_tag");
    op(3'd5, l1, 36'd0, 8'd0);
    check(gfault == 1 && greason == 8'd5-1, "tget of a CONS is bad_tag");
    op(3'd0, iw(1), NILW, 8'd0);
    check(gfault == 0, "the heap still works after a trapped op");

    // ---- heap_full traps rather than wrapping (reason 6) ----
    // 128 cells per semispace; fill whatever is left.
    while (hp_out < 128) op(3'd0, iw(0), NILW, 8'd0);
    check(hp_out == 128, "the semispace is exactly full");
    op(3'd0, iw(0), NILW, 8'd0);
    check(gfault == 1 && greason == 8'd6, "one cons past the end is heap_full");
    check(hp_out == 128, "a full heap does not bump the pointer");

    // the arity that would make aptr + alloc_cells wrap an 8-bit sum
    op(3'd3, 36'd0, 36'd0, 8'd255);
    check(gfault == 1 && greason == 8'd6,
          "a 255-arity tuple on a full heap is heap_full, not a wrap");

    // ---- flip resets the allocation pointer into the other semispace
    @(negedge clk); flip_en = 1; @(posedge clk); #1; flip_en = 0;
    @(posedge clk); #1;
    check(hp_out == 0, "flip empties the allocation pointer");
    op(3'd0, iw(42), NILW, 8'd0);
    check(gfault == 0 && got[35:32] == 4'h3, "and the other semispace allocates");
    op(3'd1, got, 36'd0, 8'd0);
    check(got == iw(42), "and reads back");

    $display("---- %0d checks, %0d failures ----", checks, errors);
    if (errors == 0) $display("__HEAP_OK__");
    else $display("__HEAP_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #500000;
    $display("__HEAP_TIMEOUT__");
    $finish;
  end
endmodule
