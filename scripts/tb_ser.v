// The serialiser against its Elixir oracle.
//
//   scripts/run_tbs.sh tb_ser
//
// `mk_ser_vectors.exs` lays terms out on a heap image exactly as
// `heap.ex` addresses it and writes, per term, the flit stream
// `PicoBEAM.Serial` says it flattens to. This loads that image into a
// real `heap` instance, points a real `ser_unit` at each root, and
// compares the emitted stream flit for flit. Same discipline as
// check_shape_hash.exs: the wire format is defined once and the
// netlist has to agree with it.
//
// Prints __SER_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg start = 0, go_emit = 0;
  reg [35:0] term = 0;

  wire busy, done, s_fault, emit, counted;
  wire [7:0] s_reason;
  wire [6:0] s_count;
  wire [35:0] emit_word;
  wire [7:0] h_addr;
  wire [7:0] root_arity;
  wire [35:0] root_first;
  wire [35:0] h_q0, h_q1;

  // a real heap, read through port B
  wire [35:0] hp_rd_late, hp_bq0, hp_bq1;
  wire hp_fault, hp_full;
  wire [7:0] hp_reason, hp_hp;

  heap hp(.clk(clk), .rst(rst),
    .cmd_en(1'b0), .cmd(4'd7), .pa(36'd0), .pb(36'd0), .i8(8'd0),
    .rd_late(hp_rd_late), .fault(hp_fault), .fault_reason(hp_reason),
    .hp_out(hp_hp), .heap_full(hp_full),
    .b_en(1'b1), .b_addr(h_addr), .b_wr0(1'b0), .b_wr1(1'b0), .b_d0(36'd0), .b_d1(36'd0),
    .b_q0(hp_bq0), .b_q1(hp_bq1), .flip_en(1'b0), .flip_aptr(8'd0));

  assign h_q0 = hp_bq0;
  assign h_q1 = hp_bq1;

  ser_unit su(.clk(clk), .rst(rst),
    .start(start), .term(term),
    .busy(busy), .done(done), .fault(s_fault), .fault_reason(s_reason),
    .count(s_count), .counted(counted), .go_emit(go_emit),
    .abort(1'b0), .stall(1'b0),
    .h_addr(h_addr), .h_q0(h_q0), .h_q1(h_q1),
    .emit(emit), .emit_word(emit_word),
    .root_arity(root_arity), .root_first(root_first));

  localparam NTERM = 11;
  reg [35:0] roots [0:15];
  reg [7:0]  lens  [0:15];
  reg [35:0] flits [0:127];
  reg [35:0] h0img [0:255];
  reg [35:0] h1img [0:255];

  // what came out
  reg [35:0] got [0:127];
  integer ngot = 0;

  always @(posedge clk) if (!rst && emit) begin
    if (ngot < 128) got[ngot] = emit_word;
    ngot = ngot + 1;
  end

  integer errors = 0, checks = 0, i, t, base, k;
  integer cycles;

  task check(input cond, input [255:0] name);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    for (i = 0; i < 256; i = i + 1) begin h0img[i] = 0; h1img[i] = 0; end
    for (i = 0; i < 16; i = i + 1) begin roots[i] = 0; lens[i] = 0; end
    for (i = 0; i < 128; i = i + 1) flits[i] = 0;
    $readmemh("ser_h0.hex", h0img);
    $readmemh("ser_h1.hex", h1img);
    $readmemh("ser_roots.hex", roots);
    $readmemh("ser_lens.hex", lens);
    $readmemh("ser_flits.hex", flits);
    for (i = 0; i < 256; i = i + 1) begin
      hp.h0[i] = h0img[i]; hp.h1[i] = h1img[i];
    end
    // the traversal stack, zeroed the way a DPR16X4 powers up. It has
    // to be: the one-hot-sum mux idiom this codebase uses everywhere
    // propagates X, because `0 * X` is X — so an unread stack entry
    // poisons `stk_data` through a term that is not even selected.
    for (i = 0; i < 8; i = i + 1) su.stk[i] = 0;

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    base = 0;
    for (t = 0; t < NTERM; t = t + 1) begin
      ngot = 0;
      @(negedge clk); start = 1; term = roots[t];
      @(posedge clk); #1; @(negedge clk); start = 0;

      // pass 0 counts, and stops to be asked whether the message fits
      cycles = 0;
      while (!counted && !s_fault && cycles < 2000) begin
        @(posedge clk); #1; cycles = cycles + 1;
      end
      check(!s_fault, "no fault while counting");
      if (s_count !== lens[t][6:0])
        $display("  term %0d: counted %0d, oracle says %0d", t, s_count, lens[t]);
      check(s_count == lens[t][6:0], "pass 0 counts what the oracle counts");
      check(ngot == 0, "pass 0 emits nothing");

      // now let it emit
      @(negedge clk); go_emit = 1;
      @(posedge clk); #1; @(negedge clk); go_emit = 0;

      cycles = 0;
      while (!done && !s_fault && cycles < 2000) begin
        @(posedge clk); #1; cycles = cycles + 1;
      end
      check(!s_fault, "no fault while emitting");
      check(ngot == lens[t], "pass 1 emits exactly `count` flits");

      for (k = 0; k < lens[t] && k < 128; k = k + 1) begin
        if (got[k] !== flits[base + k]) begin
          $display("  term %0d flit %0d: gates %09h, oracle %09h",
                   t, k, got[k], flits[base + k]);
          errors = errors + 1;
        end
        checks = checks + 1;
      end

      base = base + lens[t];
      @(posedge clk); #1;
    end

    $display("---- %0d checks, %0d failures ----", checks, errors);
    if (errors == 0) $display("__SER_OK__");
    else $display("__SER_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #2000000;
    $display("__SER_TIMEOUT__");
    $finish;
  end
endmodule
