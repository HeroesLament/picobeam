// tb_rootwalk — `RootWalker` against a modelled machine.
//
//   iverilog -o /tmp/tb.vvp scripts/tb_rootwalk.v _emit/all/p/root_walker.v
//
// The walker's whole job is to visit EXACTLY the live roots: every
// resident window and its staging bank, the save area of live processes
// that are NOT resident, and frames 0..depth-1 of every live process.
// Visiting less loses data; visiting more resurrects it.
//
// So the three memories here are stand-ins with one property that makes
// the walk observable: every word the walker presents comes back
// rewritten with bit 23 set. "Was this location walked?" is then a
// question the testbench can ask of every location in the machine,
// including the ones that must NOT have been.
//
// Pass 1 fills every location with a POINTER, so walked == presented
// and the visited set is checked exactly.
// Pass 2 makes three words in four immediates, which must never reach
// the collector at all — the filter that makes the walk affordable.
`timescale 1ns/1ps
module tb_rootwalk;
  // declared before first use (newer iverilog rejects use-before-declaration)
  integer fails = 0;
  reg clk = 0, rst = 1, start = 0;
  always #5 clk = ~clk;

  wire busy, done;
  wire root_en, roots_done;
  wire [35:0] root_word;
  reg root_ack = 0;
  reg [35:0] root_new = 0;

  reg [31:0] live_vec;
  reg [3:0]  seat_val;
  reg [4:0]  seat_slot0, seat_slot1, seat_slot2, seat_slot3;

  wire [1:0] rw_ctx; wire rw_stg; wire [3:0] rw_addr;
  wire rw_we; wire [35:0] rw_data; reg [35:0] rw_q;

  wire sv_en; wire [4:0] sv_slot; wire [3:0] sv_idx;
  wire sv_wr; wire [35:0] sv_data; reg [35:0] sv_q;

  wire frm_en; wire [4:0] frm_slot; wire [3:0] frm_depth, frm_idx;
  wire frm_wr; wire [35:0] frm_data; reg [35:0] frm_q;
  wire [4:0] frm_qslot; wire [3:0] frm_qdepth;

  root_walker dut(.clk(clk), .rst(rst), .start(start),
    // the FULL sweep, which is what this testbench is about.
    // `notes/46` added a one-process mode beside it; an unconnected
    // input floats to x and takes every branch that reads it with it.
    .one_en(1'b0), .one_slot(5'd0),
    .busy(busy), .done(done),
    .root_en(root_en), .root_word(root_word),
    .root_ack(root_ack), .root_new(root_new), .roots_done(roots_done),
    .live_vec(live_vec), .seat_val(seat_val),
    .seat_slot0(seat_slot0), .seat_slot1(seat_slot1),
    .seat_slot2(seat_slot2), .seat_slot3(seat_slot3),
    .rw_ctx(rw_ctx), .rw_stg(rw_stg), .rw_addr(rw_addr), .rw_q(rw_q),
    .rw_we(rw_we), .rw_data(rw_data),
    .sv_en(sv_en), .sv_slot(sv_slot), .sv_idx(sv_idx),
    .sv_wr(sv_wr), .sv_data(sv_data), .sv_q(sv_q),
    .frm_en(frm_en), .frm_slot(frm_slot), .frm_depth(frm_depth), .frm_idx(frm_idx),
    .frm_wr(frm_wr), .frm_data(frm_data), .frm_q(frm_q),
    .frm_qslot(frm_qslot), .frm_qdepth(frm_qdepth));

  // ---- the modelled memories. Sync read, one cycle, like the real ones
  reg [35:0] rw_mem [0:127];    // {ctx:2, stg:1, reg:4}
  reg [35:0] sv_mem [0:511];    // {slot:5, idx:4}
  reg [35:0] fr_mem [0:8191];   // {slot:5, depth:4, idx:4}
  reg [3:0]  depth_of [0:31];

  wire [6:0]  rw_a = {rw_ctx, rw_stg, rw_addr};
  wire [8:0]  sv_a = {sv_slot, sv_idx};
  wire [12:0] fr_a = {frm_slot, frm_depth, frm_idx};

  assign frm_qdepth = depth_of[frm_qslot];

  always @(posedge clk) begin
    rw_q <= rw_mem[rw_a];
    sv_q <= sv_mem[sv_a];
    frm_q <= fr_mem[fr_a];
    if (rw_we) rw_mem[rw_a] <= rw_data;
    if (sv_wr) sv_mem[sv_a] <= sv_data;
    if (frm_wr) fr_mem[fr_a] <= frm_data;
  end

  // ---- the modelled collector: three cycles, then an answer with
  // bit 23 set. It accepts one word at a time and acks in the cycle it
  // would be back in its own state 1, exactly as `Collector` does.
  integer npres = 0;
  reg [1:0] cst = 0;
  reg [35:0] cw = 0;
  always @(posedge clk) begin
    root_ack <= 0;
    if (rst) begin cst <= 0; end
    else case (cst)
      0: if (root_en) begin cw <= root_word; cst <= 1; npres = npres + 1;
           if (root_word[35:32] != 4'd3 && root_word[35:32] != 4'd4 &&
               root_word[35:32] != 4'd7) begin
             $display("FAIL immediate presented: %h", root_word);
             fails = fails + 1;
           end
         end
      1: cst <= 2;
      2: begin root_ack <= 1;
               root_new <= {cw[35:32], cw[31:24], 1'b1, cw[22:0]};
               cst <= 0; end
    endcase
  end

  integer i, s, d, c, g, r;

  // is location (region, ...) one the walker MUST visit?
  function want_rw; input [1:0] cx; begin
    want_rw = seat_val[cx];
  end endfunction

  function resident; input [4:0] sl; begin
    resident = (seat_val[0] && seat_slot0 == sl) ||
               (seat_val[1] && seat_slot1 == sl) ||
               (seat_val[2] && seat_slot2 == sl) ||
               (seat_val[3] && seat_slot3 == sl);
  end endfunction

  function want_sv; input [4:0] sl; begin
    want_sv = live_vec[sl] && !resident(sl);
  end endfunction

  function want_fr; input [4:0] sl; input [3:0] dp; begin
    want_fr = live_vec[sl] && (dp < depth_of[sl]);
  end endfunction

  task fill; input ptr_every_word; begin
    for (i = 0; i < 128; i = i + 1)
      rw_mem[i] = {(ptr_every_word || (i[1:0] == 2'd0)) ? 4'd3 : 4'd0,
                   4'd0, 28'h0000000 + i[27:0]};
    for (i = 0; i < 512; i = i + 1)
      sv_mem[i] = {(ptr_every_word || (i[1:0] == 2'd0)) ? 4'd3 : 4'd0,
                   4'd0, 28'h0100000 + i[27:0]};
    for (i = 0; i < 8192; i = i + 1)
      fr_mem[i] = {(ptr_every_word || (i[1:0] == 2'd0)) ? 4'd3 : 4'd0,
                   4'd0, 28'h0200000 + i[27:0]};
  end endtask

  // bit 23 of the payload is the collector's mark
  function marked; input [35:0] w; begin marked = w[23]; end endfunction

  integer nwalk;
  task check; input ptr_every_word; begin
    nwalk = 0;
    for (c = 0; c < 4; c = c + 1)
      for (g = 0; g < 2; g = g + 1)
        for (r = 0; r < 16; r = r + 1) begin
          i = c*32 + g*16 + r;
          if (want_rw(c[1:0]) && (ptr_every_word || (i[1:0] == 2'd0))) begin
            nwalk = nwalk + 1;
            if (!marked(rw_mem[i])) begin
              $display("FAIL window ctx%0d stg%0d r%0d not walked (%h)",
                       c, g, r, rw_mem[i]); fails = fails + 1; end
          end else if (marked(rw_mem[i])) begin
            $display("FAIL window ctx%0d stg%0d r%0d walked and must not be",
                     c, g, r); fails = fails + 1; end
        end

    for (s = 0; s < 32; s = s + 1)
      for (i = 0; i < 16; i = i + 1) begin
        d = s*16 + i;
        if (want_sv(s[4:0]) && (ptr_every_word || (d[1:0] == 2'd0))) begin
          nwalk = nwalk + 1;
          if (!marked(sv_mem[d])) begin
            $display("FAIL save slot%0d idx%0d not walked", s, i);
            fails = fails + 1; end
        end else if (marked(sv_mem[d])) begin
          $display("FAIL save slot%0d idx%0d walked and must not be", s, i);
          fails = fails + 1; end
      end

    for (s = 0; s < 32; s = s + 1)
      for (d = 0; d < 16; d = d + 1)
        for (i = 0; i < 16; i = i + 1) begin
          r = s*256 + d*16 + i;
          if (want_fr(s[4:0], d[3:0]) && (ptr_every_word || (r[1:0] == 2'd0))) begin
            nwalk = nwalk + 1;
            if (!marked(fr_mem[r])) begin
              $display("FAIL frame slot%0d d%0d idx%0d not walked", s, d, i);
              fails = fails + 1; end
          end else if (marked(fr_mem[r])) begin
            $display("FAIL frame slot%0d d%0d idx%0d walked and must not be",
                     s, d, i); fails = fails + 1; end
        end

    if (npres != nwalk) begin
      $display("FAIL presented %0d roots, wanted %0d", npres, nwalk);
      fails = fails + 1;
    end else
      $display("  %0d roots presented, %0d expected", npres, nwalk);
  end endtask

  task run; begin
    npres = 0;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    i = 0;
    while (busy && i < 200000) begin @(negedge clk); i = i + 1; end
    if (i >= 200000) begin $display("FAIL walker never finished"); fails = fails + 1; end
    @(negedge clk);
  end endtask

  initial begin
    // three live processes: 3 and 9 are resident, 7 is swapped out
    live_vec = 32'b0000_0000_0000_0000_0000_0010_1000_1000;
    seat_val = 4'b0011;
    seat_slot0 = 5'd3; seat_slot1 = 5'd9;
    seat_slot2 = 5'd0; seat_slot3 = 5'd0;
    for (i = 0; i < 32; i = i + 1) depth_of[i] = 4'd0;
    depth_of[3] = 4'd2;   // resident, two spilled frames
    depth_of[7] = 4'd0;   // swapped out, no frames
    depth_of[9] = 4'd1;
    depth_of[5] = 4'd4;   // DEAD slot with frames: must not be walked

    fill(1);
    repeat (4) @(negedge clk);
    rst = 0;
    repeat (2) @(negedge clk);

    $display("-- pass 1: every word a pointer");
    run;
    check(1);

    $display("-- pass 2: one word in four a pointer");
    rst = 1; repeat (3) @(negedge clk);
    fill(0);
    rst = 0; repeat (2) @(negedge clk);
    run;
    check(0);

    if (fails == 0) $display("__TB_ROOTWALK_OK__");
    else $display("__TB_ROOTWALK_FAIL__ %0d", fails);
    $finish;
  end
endmodule
