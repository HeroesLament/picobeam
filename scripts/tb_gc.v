// The collector against the serialiser.
//
//   scripts/run_tbs.sh tb_gc
//
// `mk_gc_vectors.exs` builds a from-space heap containing live objects,
// GARBAGE between them, and one object named by TWO roots. This loads
// that image into a real `heap`, runs a real `collector` over a real
// root stream, and then — the oracle — points a real `ser_unit` at each
// REWRITTEN root and compares the flit stream against what
// `PicoBEAM.Serial` says the ORIGINAL term flattens to.
//
// Comparing serialisations rather than to-space bit-for-bit is
// deliberate: where an object lands after a copy is an implementation
// detail, and the property that matters is that the graph reachable
// from every root is unchanged. Three things are asserted on top of
// that, because a serialisation comparison alone would miss them:
//
//   * `to_hp` equals the live cell count, so garbage was NOT copied;
//   * the two roots naming one object come back EQUAL, so it was copied
//     once — the failure forwarding pointers exist to prevent;
//   * an immediate root passes through untouched.
//
// Prints __GC_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  localparam NROOT = 4;
  localparam FROM  = 1'b0;
  localparam TO_BASE = FROM ? 9'd0 : 9'd128;

  // ---- collector
  reg  c_start = 0, c_root_en = 0, c_roots_done = 0;
  reg  [35:0] c_root_word = 0;
  wire c_busy, c_done, c_ack, c_ovf;
  wire [35:0] c_new;
  wire [8:0]  c_to_hp;
  wire [7:0]  c_addr;
  wire c_wr0, c_wr1;
  wire [35:0] c_d0, c_d1;

  // ---- serialiser (the oracle, used after the collection)
  reg  s_start = 0, s_go = 0;
  reg  [35:0] s_term = 0;
  wire s_busy, s_done, s_fault, s_emit, s_counted;
  wire [7:0] s_reason, s_addr, s_arity;
  wire [6:0] s_count;
  wire [35:0] s_word, s_first;

  // ---- heap port B, shared: the collector owns it during a
  // collection, the serialiser afterwards. They are never both live.
  wire [35:0] hp_bq0, hp_bq1, hp_rd_late;
  wire hp_fault, hp_full;
  wire [7:0] hp_reason, hp_hp;
  wire hp_space;

  wire [7:0] b_addr = c_busy ? c_addr : {~FROM, s_addr[6:0]};
  wire       b_wr0  = c_busy & c_wr0;
  wire       b_wr1  = c_busy & c_wr1;

  heap hp(.clk(clk), .rst(rst),
    .cmd_en(1'b0), .cmd(4'd7), .pa(36'd0), .pb(36'd0), .i8(8'd0),
    .rd_late(hp_rd_late), .fault(hp_fault), .fault_reason(hp_reason),
    .hp_out(hp_hp), .heap_full(hp_full), .space_out(hp_space),
    .b_en(1'b1), .b_addr(b_addr),
    .b_wr0(b_wr0), .b_wr1(b_wr1), .b_d0(c_d0), .b_d1(c_d1),
    .b_q0(hp_bq0), .b_q1(hp_bq1),
    .flip_en(1'b0), .flip_aptr(9'd0), .flip_space(1'b0));

  collector col(.clk(clk), .rst(rst),
    .start(c_start), .from_space(FROM),
    // `notes/46` — the cursor starts where to-space's bump pointer is,
    // not at the bottom of the space. Here nothing else has allocated,
    // so that IS the bottom: 128 cells past FROM.
    .start_hp(TO_BASE),
    .busy(c_busy), .done(c_done), .to_hp(c_to_hp), .overflow(c_ovf),
    .root_en(c_root_en), .root_word(c_root_word),
    .root_ack(c_ack), .root_new(c_new), .roots_done(c_roots_done),
    .h_addr(c_addr), .h_wr0(c_wr0), .h_wr1(c_wr1),
    .h_d0(c_d0), .h_d1(c_d1), .h_q0(hp_bq0), .h_q1(hp_bq1));

  ser_unit su(.clk(clk), .rst(rst),
    .start(s_start), .term(s_term),
    .busy(s_busy), .done(s_done), .fault(s_fault), .fault_reason(s_reason),
    .count(s_count), .counted(s_counted), .go_emit(s_go),
    .abort(1'b0), .stall(1'b0),
    .h_addr(s_addr), .h_q0(hp_bq0), .h_q1(hp_bq1),
    .emit(s_emit), .emit_word(s_word),
    .root_arity(s_arity), .root_first(s_first));

  reg [35:0] roots [0:15];
  reg [7:0]  lens  [0:15];
  reg [35:0] flits [0:127];
  reg [35:0] h0img [0:255];
  reg [35:0] h1img [0:255];
  reg [7:0]  livec [0:0];

  reg [35:0] newroot [0:15];
  reg [35:0] got [0:127];
  integer ngot = 0;

  always @(posedge clk) if (!rst && s_emit) begin
    if (ngot < 128) got[ngot] = s_word;
    ngot = ngot + 1;
  end

  integer errors = 0, checks = 0, i, t, base, k, cycles;

`ifdef TRACE
  always @(posedge clk) if (!rst && c_busy)
    $display("T=%0t st=%0d thp=%0d scan=%0d ev_word=%09h ev_cells=%0d ev_i=%0d ev_src=%0d ev_dst=%0d addr=%0d q0=%09h q1=%09h wr=%0b%0b ack=%0b new=%09h",
      $time, col.st, col.thp, col.scan, col.ev_word, col.ev_cells, col.ev_i,
      col.ev_src, col.ev_dst, col.addr, hp_bq0, hp_bq1, c_wr0, c_wr1, c_ack, c_new);
`endif

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
    $readmemh("gc_h0.hex", h0img);
    $readmemh("gc_h1.hex", h1img);
    $readmemh("gc_roots.hex", roots);
    $readmemh("gc_lens.hex", lens);
    $readmemh("gc_flits.hex", flits);
    $readmemh("gc_live.hex", livec);

    for (i = 0; i < 256; i = i + 1) begin
      hp.h0[i] = h0img[i];
      hp.h1[i] = h1img[i];
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---- phase 1: stream the roots in
    @(negedge clk); c_start = 1;
    @(posedge clk); #1; c_start = 0;

    for (t = 0; t < NROOT; t = t + 1) begin
      @(negedge clk);
      c_root_word = roots[t];
      c_root_en = 1;
      // hold until the collector answers
      cycles = 0;
      while (!c_ack && cycles < 400) begin
        @(posedge clk); #1;
        cycles = cycles + 1;
      end
      newroot[t] = c_new;
      @(negedge clk); c_root_en = 0;
      @(posedge clk); #1;
    end

    // ---- phase 2: the scan
    @(negedge clk); c_roots_done = 1;
    cycles = 0;
    while (!c_done && cycles < 4000) begin
      @(posedge clk); #1;
      cycles = cycles + 1;
    end
    @(negedge clk); c_roots_done = 0;
    @(posedge clk); #1;

    check(c_done || cycles < 4000, "the collection terminated");
    check(!c_ovf, "the live set fitted");

    // `notes/46` — the cursor is an ABSOLUTE cell address and it started
    // at the bottom of to-space, so the live cell count is how far past
    // that it got, not the value itself.
    if ((c_to_hp - TO_BASE) !== livec[0])
      $display("  to_hp=%0d (base %0d), live cells should be %0d",
        c_to_hp, TO_BASE, livec[0]);
    check((c_to_hp - TO_BASE) == livec[0], "only the live cells were copied");

    if (newroot[1] !== newroot[2])
      $display("  shared object copied twice: %09h vs %09h", newroot[1], newroot[2]);
    check(newroot[1] == newroot[2],
          "one object named by two roots was copied ONCE");

    check(newroot[3] == roots[3], "an immediate root passed through untouched");

    // ---- phase 3: serialise each survivor and compare
    base = 0;
    for (t = 0; t < NROOT; t = t + 1) begin
      ngot = 0;
      @(negedge clk); s_term = newroot[t]; s_start = 1;
      @(posedge clk); #1; s_start = 0;

      cycles = 0;
      while (!s_counted && cycles < 600) begin @(posedge clk); #1; cycles = cycles + 1; end
      @(negedge clk); s_go = 1;
      @(posedge clk); #1; s_go = 0;

      cycles = 0;
      while (!s_done && cycles < 600) begin @(posedge clk); #1; cycles = cycles + 1; end
      #1;

      if (ngot !== lens[t])
        $display("  root %0d: %0d flits after collection, oracle says %0d",
                 t, ngot, lens[t]);
      check(ngot == lens[t], "the survivor flattens to the same length");

      for (k = 0; k < lens[t]; k = k + 1) begin
        if (got[k] !== flits[base + k]) begin
          $display("FAIL root %0d flit %0d: got %09h, oracle %09h",
                   t, k, got[k], flits[base + k]);
          errors = errors + 1;
        end
      end
      base = base + lens[t];
      @(posedge clk); #1;
    end

    $display("  %0d checks, from-space had garbage, live=%0d", checks, c_to_hp - TO_BASE);
    if (errors == 0) $display("__GC_OK__");
    else $display("__GC_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #40000000;
    $display("__GC_TIMEOUT__");
    $finish;
  end
endmodule
