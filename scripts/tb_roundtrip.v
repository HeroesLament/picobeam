// serialise -> deserialise -> serialise.
//
//   scripts/run_tbs.sh tb_roundtrip
//
// The strongest statement available without walking a heap in Verilog:
// flatten a term, rebuild it somewhere else on the heap, flatten THAT,
// and require the two flit streams to be identical — and equal to what
// `PicoBEAM.Serial` says the original flattens to.
//
// It works because a flit stream contains no pointers. The rebuilt
// term lives at different cells than the original, so anything that
// leaked an address would show up immediately as a mismatch.
//
// Prints __ROUNDTRIP_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- serialiser
  reg s_start = 0, s_go = 0;
  reg [35:0] s_term = 0;
  wire s_busy, s_done, s_fault, s_emit, s_counted;
  wire [7:0] s_reason, s_arity, h_addr;
  wire [6:0] s_count;
  wire [35:0] s_word, s_first;

  // ---- deserialiser
  reg d_start = 0;
  reg [5:0] d_len = 0;
  wire d_busy, d_done;
  wire [35:0] d_result;
  wire [4:0] d_rf_slot;
  wire [5:0] d_rf_idx;
  wire d_h_req;
  wire [2:0] d_h_cmd;
  wire [35:0] d_h_pa, d_h_pb;
  wire [7:0] d_h_i8;

  // ---- heap: port B feeds the serialiser, the command port the rebuild
  wire [35:0] hp_rd_late, hp_bq0, hp_bq1;
  wire hp_fault, hp_full;
  wire [7:0] hp_reason, hp_hp;
  wire hp_cmd_en = d_h_req;          // no contention here: always granted

  heap hp(.clk(clk), .rst(rst),
    .cmd_en(hp_cmd_en), .cmd(d_h_cmd), .pa(d_h_pa), .pb(d_h_pb), .i8(d_h_i8),
    .rd_late(hp_rd_late), .fault(hp_fault), .fault_reason(hp_reason),
    .hp_out(hp_hp), .heap_full(hp_full),
    .b_en(1'b1), .b_addr(h_addr), .b_wr0(1'b0), .b_wr1(1'b0), .b_d0(36'd0), .b_d1(36'd0),
    .b_q0(hp_bq0), .b_q1(hp_bq1), .flip_en(1'b0), .flip_aptr(8'd0));

  ser_unit su(.clk(clk), .rst(rst),
    .start(s_start), .term(s_term),
    .busy(s_busy), .done(s_done), .fault(s_fault), .fault_reason(s_reason),
    .count(s_count), .counted(s_counted), .go_emit(s_go),
    .abort(1'b0), .stall(1'b0),
    .h_addr(h_addr), .h_q0(hp_bq0), .h_q1(hp_bq1),
    .emit(s_emit), .emit_word(s_word),
    .root_arity(s_arity), .root_first(s_first));

  // the TB plays the mailbox: the flits the serialiser just produced
  reg [35:0] fifo [0:127];
  wire [35:0] d_rf_word = fifo[d_rf_idx];

  deser_unit du(.clk(clk), .rst(rst),
    .start(d_start), .slot(5'd0), .idx(6'd0), .len(d_len),
    .busy(d_busy), .done(d_done), .result(d_result),
    .rf_slot(d_rf_slot), .rf_idx(d_rf_idx), .rf_word(d_rf_word),
    .h_req(d_h_req), .h_cmd(d_h_cmd), .h_pa(d_h_pa), .h_pb(d_h_pb),
    .h_i8(d_h_i8), .h_grant(1'b1), .h_rd_late(hp_rd_late));

  localparam NTERM = 11;
  reg [35:0] roots [0:15];
  reg [7:0]  lens  [0:15];
  reg [35:0] oracle [0:127];
  reg [35:0] h0img [0:255];
  reg [35:0] h1img [0:255];
  reg [7:0]  meta [0:1];

  reg [35:0] a [0:127];
  reg [35:0] b [0:127];
  integer na = 0, nb = 0, capture = 0;

  always @(posedge clk) if (!rst && s_emit) begin
    if (capture == 0) begin if (na < 128) a[na] = s_word; na = na + 1; end
    else              begin if (nb < 128) b[nb] = s_word; nb = nb + 1; end
  end

  integer errors = 0, checks = 0, i, t, base, k, cyc;

  task check(input cond, input [255:0] name);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  // run one full serialisation of `term`, leaving the flits in a/b
  task serialise(input [35:0] term);
    begin
      @(negedge clk); s_start = 1; s_term = term;
      @(posedge clk); #1; @(negedge clk); s_start = 0;
      cyc = 0;
      while (!s_counted && !s_fault && cyc < 3000) begin @(posedge clk); #1; cyc = cyc + 1; end
      @(negedge clk); s_go = 1;
      @(posedge clk); #1; @(negedge clk); s_go = 0;
      cyc = 0;
      while (!s_done && !s_fault && cyc < 3000) begin @(posedge clk); #1; cyc = cyc + 1; end
    end
  endtask

  initial begin
    for (i = 0; i < 256; i = i + 1) begin h0img[i] = 0; h1img[i] = 0; end
    for (i = 0; i < 16; i = i + 1) begin roots[i] = 0; lens[i] = 0; end
    for (i = 0; i < 128; i = i + 1) begin oracle[i] = 0; fifo[i] = 0; end
    $readmemh("ser_h0.hex", h0img);
    $readmemh("ser_h1.hex", h1img);
    $readmemh("ser_roots.hex", roots);
    $readmemh("ser_lens.hex", lens);
    $readmemh("ser_flits.hex", oracle);
    $readmemh("ser_cells.hex", meta);
    for (i = 0; i < 256; i = i + 1) begin hp.h0[i] = h0img[i]; hp.h1[i] = h1img[i]; end
    for (i = 0; i < 8; i = i + 1) su.stk[i] = 0;
    for (i = 0; i < 64; i = i + 1) du.vstk[i] = 0;

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // the image was preloaded behind the allocator's back, so tell it
    // where the free cells start or the rebuild will land on top of it
    hp.aptr = meta[0];

    base = 0;
    for (t = 0; t < NTERM; t = t + 1) begin
      // ---- 1. flatten the original
      na = 0; capture = 0;
      serialise(roots[t]);
      check(!s_fault, "no fault flattening the original");
      check(na == lens[t], "flit count matches the oracle");
      for (k = 0; k < lens[t]; k = k + 1) begin
        checks = checks + 1;
        if (a[k] !== oracle[base + k]) begin
          $display("  term %0d flit %0d: gates %09h, oracle %09h",
                   t, k, a[k], oracle[base + k]);
          errors = errors + 1;
        end
      end

      // ---- 2. rebuild it somewhere else on the heap
      for (k = 0; k < 128; k = k + 1) fifo[k] = 36'd0;
      for (k = 0; k < lens[t]; k = k + 1) fifo[k] = a[k];
      @(negedge clk); d_start = 1; d_len = lens[t][5:0];
      @(posedge clk); #1; @(negedge clk); d_start = 0;
      cyc = 0;
      while (!d_done && cyc < 3000) begin @(posedge clk); #1; cyc = cyc + 1; end
      check(cyc < 3000, "the rebuild finished");
      check(!hp_fault, "the rebuild did not fault the heap");

      // ---- 3. flatten the rebuilt term
      nb = 0; capture = 1;
      serialise(d_result);
      check(!s_fault, "no fault flattening the rebuild");
      check(nb == lens[t], "the rebuild flattens to the same length");
      for (k = 0; k < lens[t]; k = k + 1) begin
        checks = checks + 1;
        if (b[k] !== a[k]) begin
          $display("  term %0d ROUND TRIP flit %0d: %09h -> %09h",
                   t, k, a[k], b[k]);
          errors = errors + 1;
        end
      end

      // a compound must land somewhere NEW: if the deserialiser handed
      // back the original pointer, the streams would match trivially
      if (lens[t] > 1)
        check(d_result !== roots[t], "the rebuild is a copy, not the original");

      base = base + lens[t];
      @(posedge clk); #1;
    end

    $display("---- %0d checks, %0d failures ---- (heap used %0d cells)",
             checks, errors, hp_hp);
    if (errors == 0) $display("__ROUNDTRIP_OK__");
    else $display("__ROUNDTRIP_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #4000000;
    $display("__ROUNDTRIP_TIMEOUT__");
    $finish;
  end
endmodule
