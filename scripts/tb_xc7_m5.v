// The Zynq timing harness, end to end, with the PS and the MMCM stubbed
// (scripts/xc7_sim_prims.v):
//
//   scripts/run_tbs.sh tb_xc7_m5
//
// 1. the DRP: a write and a readback through CTRL0/STATUS0
// 2. the image goes in over AXI one byte per CTRL2 write, the run is
//    released, the player pushes it down the `notes/37` side door, and
//    engine 0's first `out` is the push image's 0xAB
// 3. the same run again, with the pb_clk period changed: the signature
//    must not move. That is the property the Fmax sweep stands on.
//
// Prints __XC7_OK__ on full success.

`timescale 1ns/1ps

`ifndef PUSH_IMG
  `define PUSH_IMG "push_bytes.hex"
`endif
`ifndef PUSH_LEN
  `define PUSH_LEN 39
`endif
// run window, units of 1024 pb_clk cycles
`ifndef WIN
  `define WIN 12
`endif
// -DREFERENCE: one run of an arbitrary image (e.g. the fabfarm pb_fmax
// one: -DPUSH_IMG='"elixir_bytes.hex"' -DPUSH_LEN=1925 -DWIN=192), printing
// the signature, flags and out words the silicon sweep is compared with,
// instead of checking for the push image's 0xAB.

module tb;
  reg fclk = 0;
  always #5 fclk = ~fclk;
  reg fclk_rst_n = 0;

  // pb_clk source; its half period is changed between runs
  reg pb_src = 0;
  real pb_half = 10.0;
  always #(pb_half) pb_src = ~pb_src;

  reg [31:0] awaddr = 0, wdata = 0, araddr = 0;
  reg awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;

  xc7_m5_top dut ();
  // RTL memories need zeroing to match silicon; the post-synthesis
  // netlist's RAMB/RAM32M/RAM64M models start from their INIT (zero).
`ifndef POSTSYNTH
  `include "xc7_m5_meminit.vh"
`endif
`ifdef XPROBE
  // per-primitive X-origin probe, from scripts/gen_xprobe.sh
  `include "xprobe.vh"
`endif

  integer errors = 0, i;
  integer win;  // +WIN=<n> overrides `WIN at run time
  integer plen; // +LEN=<n> overrides `PUSH_LEN at run time
  reg [8*256-1:0] pimg_path; // +IMG=<hex file> overrides `PUSH_IMG
  reg [31:0] rd, sig1, sig2, cyc1;
  reg [7:0] pimg [0:2047];

  task check(input cond, input [255:0] name);
    begin
      if (cond !== 1'b1) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  task axw(input [31:0] a, input [31:0] d);
    begin
      @(posedge fclk); awaddr <= 32'h4000_0000 | a; awvalid <= 1;
      @(posedge fclk); while (!dut.awready) @(posedge fclk);
      awvalid <= 0; wdata <= d; wvalid <= 1;
      @(posedge fclk); while (!dut.wready) @(posedge fclk);
      wvalid <= 0; bready <= 1;
      @(posedge fclk); while (!dut.bvalid) @(posedge fclk);
      bready <= 0;
    end
  endtask

  task axr(input [31:0] a, output [31:0] d);
    begin
      @(posedge fclk); araddr <= 32'h4000_0000 | a; arvalid <= 1;
      @(posedge fclk); while (!dut.arready) @(posedge fclk);
      arvalid <= 0; rready <= 1;
      @(posedge fclk); while (!dut.rvalid) @(posedge fclk);
      d = dut.rdata;
      rready <= 0;
    end
  endtask

  // one full run: hold, release, wait for the window to close, read back
  task run_once(output [31:0] sig, output [31:0] cyc);
    begin
      axw(32'h10, 32'h0000_0002);           // hold, run low
      repeat (40) @(posedge fclk);
      axw(32'h10, 32'h0000_0004);           // release + run
      rd = 0;
      for (i = 0; i < 400000 && !rd[31]; i = i + 1) begin
        repeat (64) @(posedge fclk);
        axr(32'h28, rd);
      end
      check(rd[31] == 1'b1, "the run window closed");
      axr(32'h10000, sig);
      axr(32'h10004, cyc);
      axr(32'h10008, rd);
      $display("  sig=%08h cycles=%0d outs: e0=%0d e1=%0d", sig, cyc[25:0], rd[15:0], rd[31:16]);
`ifndef REFERENCE
      check(rd[15:0] >= 1, "engine 0 produced an out");
`endif
      axr(32'h1000C, rd);
      $display("  flags=%01h push_done=%0b done=%0b", rd[7:4], rd[1], rd[0]);
      check(rd[1] == 1'b1, "the player finished the push");
`ifdef REFERENCE
      for (i = 0; i < 8; i = i + 1) begin
        axr(32'h11000 + 4 * i, rd);
        $display("  engine 0 out[%0d]: cycle=%0d word=%04h", i, rd[31:16], rd[15:0]);
      end
      for (i = 0; i < 8; i = i + 1) begin
        axr(32'h12000 + 4 * i, rd);
        $display("  engine 1 out[%0d]: cycle=%0d word=%04h", i, rd[31:16], rd[15:0]);
      end
`else
      axr(32'h11000, rd);
      $display("  engine 0 out[0]: cycle=%0d word=%04h", rd[31:16], rd[15:0]);
      check(rd[15:0] == 16'h00AB, "the pushed program ran: out 0xAB");
`endif
    end
  endtask

  initial begin
    for (i = 0; i < 2048; i = i + 1) pimg[i] = 8'h00;
    if (!$value$plusargs("IMG=%s", pimg_path)) pimg_path = `PUSH_IMG;
    $readmemh(pimg_path, pimg);
    repeat (8) @(posedge fclk);
    fclk_rst_n = 1;
    repeat (8) @(posedge fclk);

    axr(32'h24, rd);
    check(rd == 32'h0B5E0006, "design id");

    // hold the core, release the MMCM, wait for lock
    axw(32'h10, 32'h0000_0002);
    rd = 0;
    for (i = 0; i < 100 && !rd[31]; i = i + 1) axr(32'h1C, rd);
    check(rd[31] == 1'b1, "MMCM locked");

    // DRP: write 0x1234 to 0x08, read it back
    axw(32'h0C, 32'h0088_1234);             // DWE, DADDR 0x08, DI; go low
    axw(32'h0C, 32'h8088_1234);             // go: the write
    axw(32'h0C, 32'h0008_0000);
    axw(32'h0C, 32'h8008_0000);             // go: read 0x08
    axr(32'h1C, rd);
    $display("  drp: do=%04h count=%0d busy=%0b", rd[15:0], rd[23:16], rd[30]);
    check(rd[15:0] == 16'h1234, "DRP readback");
    check(rd[23:16] == 8'd2, "two DRP transactions");

    // the image, one byte per CTRL2 write; length and a 12 x 1024 window
    if (!$value$plusargs("LEN=%d", plen)) plen = `PUSH_LEN;
    for (i = 0; i < plen; i = i + 1) axw(32'h14, (i & 32'h7FF) | (pimg[i] << 16));
    if (!$value$plusargs("WIN=%d", win)) win = `WIN;
    axw(32'h18, (win << 16) | plen);

    $display("run 1: pb_clk 20 ns");
    run_once(sig1, cyc1);
`ifdef REFERENCE
    $display("__XC7_REF__ sig=%08h", sig1);
    $finish;
`endif
    pb_half = 7.3;
    $display("run 2: pb_clk 14.6 ns");
    run_once(sig2, rd);
    check(sig1 == sig2, "signature independent of pb_clk period");
    check(sig1 != 32'h0, "signature is not zero");

    if (errors == 0) $display("__XC7_OK__");
    else $display("__XC7_FAILED__ (%0d)", errors);
    $finish;
  end

`ifndef POSTSYNTH
  // the first pb_clk cycle each observation tap is X while the core runs
  reg seen_ov = 0, seen_pc = 0, seen_fl = 0, seen_od = 0;
  always @(posedge pb_src) if (dut.go === 1'b1) begin
    if (!seen_ov && ^{dut.ov0, dut.ov1} === 1'bx) begin seen_ov = 1; $display("  first_x ov at cyc %0d", dut.cyc); end
    if (!seen_pc && ^{dut.pc0, dut.pc1} === 1'bx) begin seen_pc = 1; $display("  first_x pc at cyc %0d", dut.cyc); end
    if (!seen_fl && ^dut.flags === 1'bx) begin seen_fl = 1; $display("  first_x flags=%b at cyc %0d", dut.flags, dut.cyc); end
    if (!seen_od && ^{dut.od0, dut.od1} === 1'bx) begin seen_od = 1; $display("  first_x od at cyc %0d", dut.cyc); end
  end
`endif

  initial begin
    #20000000000;
    $display("__XC7_TIMEOUT__");
    $finish;
  end
endmodule
