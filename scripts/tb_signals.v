// The signal table: links, monitors, and the exit-signal fan-out.
//
//   scripts/run_tbs.sh tb_signals
//
// What is being asserted, in `notes/13`'s terms:
//   * links are symmetric, and unlink removes both sides
//   * a death signals every peer, ONE PER CYCLE, and each peer's bit
//     for the corpse is cleared as it is signalled — which is what
//     lets a bitmap hold links without carrying a PID serial
//   * the corpse's own row is zeroed, so a recycled slot inherits
//     nothing
//   * `normal` walks the links too — the delivery end filters it
//
// Prints __SIGNALS_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg [1:0] cmd = 0;
  reg [4:0] cmd_a = 0, cmd_b = 0;
  reg die_en = 0;
  reg [4:0] die_slot = 0;
  reg [7:0] die_reason = 0;
  reg [35:0] die_pid = 0;
  reg [4:0] rd_slot = 0;
  reg sig_ready = 1;
  reg [21:0] cmd_ref = 0;
  wire sig_kind, mon_full;
  wire [21:0] sig_ref;

  wire busy, sig_en, done;
  wire [4:0] sig_slot;
  wire [35:0] sig_from;
  wire [7:0] sig_reason;
  wire [31:0] rd_mask;

  signal_table lt(.clk(clk), .rst(rst), .cmd(cmd), .cmd_a(cmd_a), .cmd_b(cmd_b),
    .die_en(die_en), .die_slot(die_slot), .die_reason(die_reason),
    .die_pid(die_pid), .sig_ready(sig_ready), .cmd_ref(cmd_ref),
    .sig_kind(sig_kind), .sig_ref(sig_ref), .mon_full(mon_full),
    .busy(busy), .sig_en(sig_en), .sig_slot(sig_slot), .sig_from(sig_from),
    .sig_reason(sig_reason), .done(done), .rd_slot(rd_slot), .rd_mask(rd_mask));

  integer errors = 0, checks = 0, i, cyc;
  reg [31:0] signalled;
  integer n_sig, sig_cycles;
  reg [31:0] m;

  task check(input cond, input [255:0] name);
    begin
      checks = checks + 1;
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  task link_op(input [1:0] c, input [4:0] a, input [4:0] b);
    begin
      @(negedge clk); cmd = c; cmd_a = a; cmd_b = b;
      @(posedge clk); #1; cmd = 0;
      // the mirror half lands the next cycle
      @(posedge clk); #1;
    end
  endtask

  task mask_of(input [4:0] s);
    begin
      @(negedge clk); rd_slot = s; #1; m = rd_mask;
    end
  endtask

  // watch the fan-out
  always @(posedge clk) if (!rst && sig_en) begin
    signalled = signalled | (32'd1 << sig_slot);
    n_sig = n_sig + 1;
  end

  initial begin
    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---- symmetry ----
    link_op(2'd1, 5'd3, 5'd7);
    mask_of(5'd3); check(m == (32'd1 << 7), "link records A -> B");
    mask_of(5'd7); check(m == (32'd1 << 3), "and B -> A: links are symmetric");

    link_op(2'd2, 5'd3, 5'd7);
    mask_of(5'd3); check(m == 0, "unlink clears A -> B");
    mask_of(5'd7); check(m == 0, "and B -> A");

    // ---- a supervisor with four children ----
    link_op(2'd1, 5'd1, 5'd10);
    link_op(2'd1, 5'd1, 5'd11);
    link_op(2'd1, 5'd1, 5'd12);
    link_op(2'd1, 5'd1, 5'd13);
    mask_of(5'd1);
    check(m == ((32'd1<<10)|(32'd1<<11)|(32'd1<<12)|(32'd1<<13)),
          "the supervisor holds four links");

    // child 12 also links a peer of its own
    link_op(2'd1, 5'd12, 5'd20);
    mask_of(5'd12);
    check(m == ((32'd1<<1)|(32'd1<<20)), "a child links both up and sideways");

    // ---- child 12 dies: exactly its two peers hear about it ----
    signalled = 0; n_sig = 0;
    @(negedge clk);
    die_en = 1; die_slot = 5'd12; die_reason = 8'd3;   // badarith
    die_pid = 36'h5_00300_001;
    @(posedge clk); #1; die_en = 0;

    cyc = 0;
    while (!done && cyc < 200) begin @(posedge clk); #1; cyc = cyc + 1; end
    check(cyc < 200, "the fan-out finished");
    check(n_sig == 2, "exactly two signals, one per link");
    check(signalled == ((32'd1<<1)|(32'd1<<20)), "and to exactly those two peers");
    check(sig_reason == 8'd3, "carrying the death's reason");
    // one link per cycle, not one BIT per cycle: two links must not
    // cost 32 cycles just because the table is 32 wide
    check(cyc <= 6, "the walk is links-long, not slots-long");

    // ---- and both sides are clean afterwards ----
    mask_of(5'd12); check(m == 0, "the corpse's row is zeroed");
    mask_of(5'd1);
    check(m == ((32'd1<<10)|(32'd1<<11)|(32'd1<<13)),
          "the supervisor lost its link to the dead child, kept the others");
    mask_of(5'd20); check(m == 0, "and so did the peer");

    // ---- `normal` WALKS the links now (notes/54): the model always
    // delivered {'EXIT', _, normal} to a trapping partner, and the
    // source-side filter that used to live here was hiding those. The
    // table emits; the DELIVERY end decides (doom only if non-normal,
    // message only if trapping).
    signalled = 0; n_sig = 0;
    @(negedge clk);
    die_en = 1; die_slot = 5'd1; die_reason = 8'd0;    // normal
    die_pid = 36'h5_00040_001;
    @(posedge clk); #1; die_en = 0;
    cyc = 0;
    while (!done && cyc < 200) begin @(posedge clk); #1; cyc = cyc + 1; end
    check(n_sig == 3, "a normal exit signals every linked peer");
    check(sig_reason == 8'd0, "carrying `normal` for the far trap check");
    mask_of(5'd1); check(m == 0, "the row is still cleared");
    mask_of(5'd10);
    check(m == 0, "and the peers' rows are cleared by the same walk");

    // ---- a fully-linked process: the worst case is bounded ----
    for (i = 0; i < 32; i = i + 1)
      if (i != 5) link_op(2'd1, 5'd5, i[4:0]);
    mask_of(5'd5);
    signalled = 0; n_sig = 0;
    @(negedge clk);
    die_en = 1; die_slot = 5'd5; die_reason = 8'd1;
    die_pid = 36'h5_00140_001;
    @(posedge clk); #1; die_en = 0;
    cyc = 0;
    while (!done && cyc < 200) begin @(posedge clk); #1; cyc = cyc + 1; end
    check(n_sig == 31, "31 peers, 31 signals");
    check(cyc <= 35, "and 31 links cost ~31 cycles: the stated bound");

    // ---- backpressure: the walk stalls, it does not drop ----
    link_op(2'd1, 5'd8, 5'd9);
    link_op(2'd1, 5'd8, 5'd15);
    signalled = 0; n_sig = 0;
    sig_ready = 0;
    @(negedge clk);
    die_en = 1; die_slot = 5'd8; die_reason = 8'd1; die_pid = 36'h5_00200_001;
    @(posedge clk); #1; die_en = 0;
    repeat (20) @(posedge clk);
    #1;
    check(n_sig == 0, "a not-ready engine gets no signals");
    check(!done, "and the walk has not finished");
    mask_of(5'd9);
    check(m == (32'd1 << 8), "nor has it cleared anything it could not deliver");
    @(negedge clk); sig_ready = 1;
    cyc = 0;
    while (!done && cyc < 200) begin @(posedge clk); #1; cyc = cyc + 1; end
    check(n_sig == 2, "and when it can, both signals arrive");
    check(signalled == ((32'd1<<9)|(32'd1<<15)), "to the right peers");

    $display("---- %0d checks, %0d failures ----", checks, errors);
    if (errors == 0) $display("__SIGNALS_OK__");
    else $display("__SIGNALS_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #500000;
    $display("__SIGNALS_TIMEOUT__");
    $finish;
  end
endmodule
