// The debug streamer, decoded.
//
// `DbgUart` is the only part of picoBEAM a person looks at directly —
// it is what `screen /dev/tty.usbserial-*01 115200` shows while the
// board is running — and until now nothing tested it. Its moduledoc
// described a field as the fault reason while the top wired that field
// to occupancy, and no testbench could have noticed, because none of
// them ever sampled `txd`.
//
// So this one does: it recovers the bit stream at 115200 8N1 the way
// the FTDI does, reassembles the line, and compares it to the string
// the format promises for a known set of inputs. If a field moves, or
// a width changes, or a separator goes missing, this fails.
//
//   scripts/run_tbs.sh tb_dbguart
//
// Prints __DBGUART_OK__ on success.

`timescale 1ns/1ps

module tb;
  // 12 MHz in the design's own terms; the baud divisor is 12e6/115200
  // = 104 CLOCKS, so the decoder counts clocks, not nanoseconds, and
  // stays right whatever period the simulation picks.
  localparam integer DIV = 104;

  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg  [8:0] pc    = 9'h123;
  reg  [3:0] sst   = 4'h5;
  reg  [3:0] flags = 4'hA;
  reg  [7:0] fr    = 8'h2C;
  reg [15:0] outv  = 16'hBEEF;
  reg  [5:0] fp    = 6'h07;
  reg  [3:0] sdst  = 4'h3;
  reg [11:0] rt1   = 12'h456;
  reg  [8:0] rt2   = 9'h0;
  reg  [3:0] rcnt  = 4'hB;
  reg [11:0] rtl   = 12'h789;
  reg  [3:0] ocnt  = 4'hC;
  reg  [7:0] frr   = 8'h03;   // badarith
  reg  [7:0] fcnt  = 8'h11;   // 17 abnormal deaths

  wire txd;

  dbg_uart u(.clk(clk), .rst(rst), .pc(pc), .sstate(sst), .flags(flags),
             .fr(fr), .outv(outv), .fp(fp), .sdst(sdst), .rt1(rt1),
             .rt2(rt2), .rcnt(rcnt), .rtl(rtl), .ocnt(ocnt),
             .frr(frr), .fcnt(fcnt), .txd(txd));

  // pPPP S F CC AAA LLL Q E OO WD XX NN
  localparam [8*35-1:0] WANT = "p123 5 a 2c 456 789 b c ef 73 03 11";

  integer errors = 0;
  reg [7:0] line [0:63];
  integer n = 0, i, b;
  reg [7:0] byt;

  task wait_clks(input integer k);
    begin
      for (i = 0; i < k; i = i + 1) @(posedge clk);
    end
  endtask

  // one 8N1 frame: start bit, 8 data LSB-first, stop
  task rx_byte(output reg [7:0] v);
    begin
      @(negedge txd);              // start bit
      wait_clks(DIV + DIV/2);      // into the middle of bit 0
      for (b = 0; b < 8; b = b + 1) begin
        v[b] = txd;
        if (b != 7) wait_clks(DIV);
      end
    end
  endtask

  initial begin
    repeat (4) @(posedge clk); #1;
    rst = 0;

    // one full line: characters up to and including LF
    n = 0;
    byt = 0;
    while (byt !== 8'h0A && n < 60) begin
      rx_byte(byt);
      line[n] = byt;
      n = n + 1;
    end

    if (n < 2 || line[n-1] !== 8'h0A || line[n-2] !== 8'h0D) begin
      $display("FAIL: line does not end CR LF (n=%0d)", n);
      errors = errors + 1;
    end

    n = n - 2;                     // the printable part

    if (n != 35) begin
      $display("FAIL: %0d printable chars, the format promises 35", n);
      errors = errors + 1;
    end

    for (i = 0; i < (n < 35 ? n : 35); i = i + 1) begin
      if (line[i] !== WANT[8*(35-i)-1 -: 8]) begin
        $display("FAIL char %0d: got '%c' (%02h), want '%c'", i,
                 line[i], line[i], WANT[8*(35-i)-1 -: 8]);
        errors = errors + 1;
      end
    end

    $write("  line = \"");
    for (i = 0; i < n; i = i + 1) $write("%c", line[i]);
    $display("\"");

    if (errors == 0) $display("__DBGUART_OK__");
    else $display("__DBGUART_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #400000000;
    $display("__DBGUART_TIMEOUT__");
    $finish;
  end
endmodule
