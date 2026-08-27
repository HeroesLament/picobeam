// M4 mailbox testbench: FIFO order, selective receive by shape hash,
// take/skip cursor discipline, tombstones, per-process isolation,
// overflow, and the scan-distance measurement.
//
//   cd _emit/m4 && iverilog -o tbm.vvp ../../scripts/tb_m4_mailbox.v \
//     mailbox.v && vvp tbm.vvp

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg [2:0] cmd = 0;
  reg [4:0] cmd_slot = 0;
  reg [35:0] cmd_word = 0;
  reg [7:0] cmd_hash = 0, cmd_filter = 0;
  reg cmd_filtered = 0;
  // multi-flit support: every message in this testbench is one flit, so
  // head is always 1 and len always 1 — which is exactly the invariant
  // the immediate path relies on and therefore worth pinning here.
  reg cmd_head = 1;
  reg [5:0] cmd_len = 1;
  reg [4:0] rf_slot = 0;
  reg [5:0] rf_idx = 0;
  wire [35:0] rf_word;
  wire [5:0] hit_idx, hit_len;
  wire [6:0] free;

  wire full, busy, done, hit;
  wire [35:0] hit_word;
  wire [5:0] scan_len;
  wire [6:0] count;
  wire unseen;

  mailbox mb(.clk(clk), .rst(rst), .cmd(cmd), .cmd_slot(cmd_slot), .q_slot(cmd_slot),
    .cmd_word(cmd_word), .cmd_hash(cmd_hash), .cmd_filter(cmd_filter),
    .cmd_head(cmd_head), .cmd_len(cmd_len),
    .rf_slot(rf_slot), .rf_idx(rf_idx), .rf_word(rf_word),
    .hit_idx(hit_idx), .hit_len(hit_len), .free(free),
    .cmd_filtered(cmd_filtered), .full(full), .busy(busy), .done(done),
    .hit(hit), .hit_word(hit_word), .scan_len(scan_len),
    .count(count), .unseen(unseen));

  integer errors = 0, i;
  reg [35:0] got;
  reg got_hit;
  integer got_len;

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  task op(input [2:0] c, input [4:0] s, input [35:0] w, input [7:0] h);
    begin
      @(negedge clk);
      cmd = c; cmd_slot = s; cmd_word = w; cmd_hash = h;
      @(posedge clk); #1;
      cmd = 0;
    end
  endtask

  // enqueue one flit of a multi-flit message
  task enqf(input [4:0] s, input [35:0] w, input [7:0] h,
            input hd, input [5:0] ln);
    begin
      cmd_head = hd; cmd_len = ln;
      op(3'd1, s, w, h);
      cmd_head = 1; cmd_len = 1;
    end
  endtask

  // read a flit through the dedicated rebuild port
  task rdf(input [4:0] s, input [5:0] idx);
    begin
      @(negedge clk); rf_slot = s; rf_idx = idx;
      @(posedge clk); #1;
      got = rf_word;
    end
  endtask

  // run a scan to completion and capture its result
  task peek(input [4:0] s, input filt, input [7:0] f);
    begin
      @(negedge clk);
      cmd = 3; cmd_slot = s; cmd_filtered = filt; cmd_filter = f;
      @(posedge clk); #1;
      cmd = 0;
      while (!done) @(posedge clk);
      #1;
      got_hit = hit; got = hit_word; got_len = scan_len;
      @(posedge clk); #1;
    end
  endtask

  task query(input [4:0] s);
    begin
      @(negedge clk); cmd = 0; cmd_slot = s; #1;
    end
  endtask

  initial begin
    for (i = 0; i < 2048; i = i + 1) begin mb.words[i] = 0; mb.hv[i] = 0; end
    for (i = 0; i < 32; i = i + 1) begin
      mb.heads[i] = 0; mb.tails[i] = 0; mb.cnts[i] = 0; mb.curs[i] = 0;
      mb.heads2[i] = 0; mb.tails2[i] = 0; mb.curs2[i] = 0; mb.cnts2[i] = 0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // ---- 1. FIFO order, unfiltered ----
    query(5'd3); check(count == 0, "slot 3 starts empty");
    op(1, 5'd3, 36'd100, 8'h41);
    op(1, 5'd3, 36'd200, 8'h42);
    op(1, 5'd3, 36'd300, 8'h41);
    query(5'd3); check(count == 3, "three messages queued");
    check(unseen == 1, "unseen messages present");

    op(2, 5'd3, 0, 0);                 // recv_start
    peek(5'd3, 0, 0);                  // unfiltered peek
    check(got_hit == 1, "unfiltered peek hits");
    check(got == 100, "FIFO: first message first");
    check(got_len == 0, "scan distance 0 for the head");
    op(4, 5'd3, 0, 0);                 // take
    query(5'd3); check(count == 2, "count fell after take");

    op(2, 5'd3, 0, 0);
    peek(5'd3, 0, 0);
    check(got == 200, "second message next");
    op(4, 5'd3, 0, 0);

    // ---- 2. selective receive: skip past a non-match ----
    op(1, 5'd3, 36'd400, 8'h55);
    op(1, 5'd3, 36'd500, 8'h99);
    // mailbox now holds 300(h41), 400(h55), 500(h99)
    op(2, 5'd3, 0, 0);
    peek(5'd3, 1, 8'h99);              // want only h99
    check(got_hit == 1, "filtered peek finds the deep match");
    check(got == 500, "selective receive skipped two non-matches");
    check(got_len == 2, "scan distance measured (2 entries walked)");
    op(4, 5'd3, 0, 0);                 // take it out of the middle
    query(5'd3); check(count == 2, "middle take decremented the count");

    // the two skipped messages are still there, in order
    op(2, 5'd3, 0, 0);
    peek(5'd3, 0, 0);
    check(got == 300, "skipped messages survive a middle take");
    op(4, 5'd3, 0, 0);
    op(2, 5'd3, 0, 0);
    peek(5'd3, 0, 0);
    check(got == 400, "and stay in order");
    op(4, 5'd3, 0, 0);
    query(5'd3); check(count == 0, "mailbox drained");

    // ---- 3. a filter that matches nothing ----
    op(1, 5'd3, 36'd600, 8'h41);
    op(2, 5'd3, 0, 0);
    peek(5'd3, 1, 8'hFE);
    check(got_hit == 0, "no match reports a miss");
    // after a miss the cursor sits at the tail: nothing unseen
    query(5'd3); check(unseen == 0, "a completed miss leaves nothing unseen");
    // ...and a later arrival becomes unseen again
    op(1, 5'd3, 36'd700, 8'hFE);
    query(5'd3); check(unseen == 1, "a new arrival is unseen");
    op(2, 5'd3, 0, 0);
    peek(5'd3, 1, 8'hFE);
    check(got_hit == 1 && got == 700, "the new arrival matches");
    op(4, 5'd3, 0, 0);

    // ---- 4. per-process isolation ----
    op(1, 5'd9, 36'd900, 8'h11);
    op(1, 5'd31, 36'd999, 8'h22);
    query(5'd9);  check(count == 1, "slot 9 has its own mailbox");
    query(5'd31); check(count == 1, "slot 31 too (top of memory)");
    query(5'd3);  check(count == 1, "slot 3 unaffected");
    op(2, 5'd31, 0, 0);
    peek(5'd31, 0, 0);
    check(got == 999, "slot 31 reads its own message");

    // ---- 5. overflow ----
    for (i = 0; i < 62; i = i + 1) op(1, 5'd9, 36'd1000 + i, 8'h11);
    query(5'd9); check(count == 63, "63 queued");
    @(negedge clk); cmd = 1; cmd_slot = 5'd9; cmd_word = 36'd1; cmd_hash = 8'h11; #1;
    check(full == 1, "full asserted at the ring limit");
    @(posedge clk); #1; cmd = 0;

    // ---------- multi-flit messages ----------
    // slot 25: a 3-flit message (hash 0xAA), then a 1-flit one (0xBB).
    // The 3-flit message's continuations carry hash 0xBB DELIBERATELY:
    // without the head bit the matcher would match one of them and hand
    // the receiver the inside of somebody else's message.
    enqf(5'd25, {4'h4, 32'd300}, 8'hAA, 1'b1, 6'd3);
    enqf(5'd25, {4'h0, 32'd301}, 8'hBB, 1'b0, 6'd0);
    enqf(5'd25, {4'h0, 32'd302}, 8'hBB, 1'b0, 6'd0);
    enqf(5'd25, {4'h0, 32'd999}, 8'hBB, 1'b1, 6'd1);

    query(5'd25);
    check(count == 4, "multi-flit: four entries, two messages");

    op(3'd2, 5'd25, 36'd0, 8'd0);          // start
    peek(5'd25, 1'b1, 8'hBB);
    check(got_hit, "a filtered scan finds the one-flit message");
    check(got == {4'h0, 32'd999},
          "and it is the MESSAGE, not a continuation that shares its hash");
    check(hit_len == 6'd1, "its length is one");
    check(got_len == 3, "the scan stepped over the three-flit message");

    // the rebuild port reads the long message's flits in place
    rdf(5'd25, 6'd0);
    check(got == {4'h4, 32'd300}, "flit 0 through the rebuild port");
    rdf(5'd25, 6'd1);
    check(got == {4'h0, 32'd301}, "flit 1");
    rdf(5'd25, 6'd2);
    check(got == {4'h0, 32'd302}, "flit 2");

    // take the one-flit message, then find and take the three-flit one
    cmd_len = 6'd1; op(3'd4, 5'd25, 36'd0, 8'd0); cmd_len = 6'd1;
    query(5'd25);
    check(count == 3, "taking the short message left three entries");

    op(3'd2, 5'd25, 36'd0, 8'd0);
    peek(5'd25, 1'b1, 8'hAA);
    check(got_hit && got == {4'h4, 32'd300}, "the long message still matches");
    check(hit_len == 6'd3, "and reports its full length");
    check(hit_idx == 6'd0, "starting at its first flit");

    cmd_len = 6'd3; op(3'd4, 5'd25, 36'd0, 8'd0); cmd_len = 6'd1;
    query(5'd25);
    check(count == 0, "taking it reclaimed all three entries at once");
    // The short message was taken OUT OF ORDER, from index 3, so its
    // entry stays tombstoned below the tail until head sweeps past it.
    // head reached 3 by reclaiming the long message and stops there.
    // That is the documented conservative policy — the ring can report
    // itself fuller than it is, never emptier — and pinning it here
    // means the idle-time compaction pass the moduledoc names as a
    // later win will have to come back and change this number on
    // purpose rather than by accident.
    check(count == 0, "no live messages remain");
    check(free == 62, "and one out-of-order tombstone is still held back");

    if (errors == 0) $display("__M4_MAILBOX_OK__");
    else $display("__M4_MAILBOX_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #400000;
    $display("__M4_MAILBOX_TIMEOUT__ busy=%b", busy);
    $finish;
  end
endmodule
