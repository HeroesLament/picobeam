// An image, pushed down one wire (notes/37).
//
//   scripts/run_tbs.sh tb_uartload
//
// The testbench IS the host: it shifts the bytes of a real `.pbi` out
// at 8N1, 104 clocks a bit, exactly as `scripts/pbpush.exs` will over
// the FTDI. What comes out the other side has to be the same side-door
// writes `Encoding.image/2` produced — the same assertion `tb_sdboot`
// makes about the card, against the same image, through the same
// `ImageParser`, arriving by a completely different road.
//
// It also sends GARBAGE first. There is no handshake and no command
// byte: the magic is the frame sync, and a loader that can be started
// by line noise is a loader that reboots the board when someone opens
// the port. The junk here includes a lone 'p' — the byte that arms the
// window — so the resync has to survive a false start.
//
// Prints __UARTLOAD_OK__ on full success.

`timescale 1ns/1ps

`ifndef IMG_BYTES
  `define IMG_BYTES "elixir_bytes.hex"
`endif
`ifndef EXP_CODE
  `define EXP_CODE "elixir.hex"
`endif
`ifndef EXP_POOL
  `define EXP_POOL "elixir_pool.hex"
`endif
`ifndef WANT_E0
  `define WANT_E0 0
`endif
`ifndef WANT_E1
  `define WANT_E1 97
`endif

module tb;
  reg clk = 0, rst = 1;
  always #41.667 clk = ~clk;          // 12 MHz

  localparam DIV = 104;               // 115200 at 12 MHz

  reg rx = 1;
  wire code_en, pool_en, img_done, receiving;
  wire [8:0] code_addr, entry0, entry1;
  wire [71:0] code_data;
  wire [7:0] pool_addr;
  wire [35:0] pool_data;

  uart_loader dut (
    .clk(clk), .rst(rst), .rx(rx),
    .code_en(code_en), .code_addr(code_addr), .code_data(code_data),
    .pool_en(pool_en), .pool_addr(pool_addr), .pool_data(pool_data),
    .entry0(entry0), .entry1(entry1),
    .img_done(img_done), .receiving(receiving));

  // ---- the host half: one 8N1 frame, LSB first
  task send(input [7:0] b);
    integer k;
    begin
      rx = 0;                                   // start
      repeat (DIV) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        rx = b[k];
        repeat (DIV) @(posedge clk);
      end
      rx = 1;                                   // stop
      repeat (DIV) @(posedge clk);
    end
  endtask

  reg [7:0] img [0:8191];
  integer n_img = 0;

  reg [71:0] got_code [0:511];
  reg [35:0] got_pool [0:255];
  integer n_code = 0, n_pool = 0;
  integer code_order_ok = 1, pool_order_ok = 1;
  integer n_done = 0;

  always @(posedge clk) if (!rst) begin
    if (code_en) begin
      if (code_addr !== n_code[8:0]) code_order_ok = 0;
      got_code[n_code] = code_data;
      n_code = n_code + 1;
    end
    if (pool_en) begin
      if (pool_addr !== n_pool[7:0]) pool_order_ok = 0;
      got_pool[n_pool] = pool_data;
      n_pool = n_pool + 1;
    end
    if (img_done) n_done = n_done + 1;
  end

  reg [71:0] exp_code [0:511];
  reg [35:0] exp_pool [0:255];
  integer n_exp_code = 0, n_exp_pool = 0;

  integer errors = 0, i;

  task check(input cond, input [255:0] name);
    begin
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    for (i = 0; i < 8192; i = i + 1) img[i] = 8'h00;
    for (i = 0; i < 512; i = i + 1) exp_code[i] = {72{1'b1}};
    for (i = 0; i < 256; i = i + 1) exp_pool[i] = {36{1'b1}};
    $readmemh(`IMG_BYTES, img);
    $readmemh(`EXP_CODE, exp_code);
    $readmemh(`EXP_POOL, exp_pool);
    for (i = 0; i < 512; i = i + 1)
      if (exp_code[i] !== {72{1'b1}}) n_exp_code = n_exp_code + 1;
    for (i = 0; i < 256; i = i + 1)
      if (exp_pool[i] !== {36{1'b1}}) n_exp_pool = n_exp_pool + 1;
    // the image is padded to a sector; only the header's worth is real
    n_img = 12 + n_exp_code * 9 + n_exp_pool * 5;

    repeat (4) @(posedge clk);
    rst = 0;
    repeat (10) @(posedge clk);

    // noise first, including the byte that arms the magic window
    send(8'h0D); send(8'h0A); send(8'h70); send(8'h42);
    send(8'hFF); send(8'h00); send(8'h70);

    check(receiving == 1'b0, "line noise did not start an image");

    for (i = 0; i < n_img; i = i + 1) send(img[i]);

    repeat (20) @(posedge clk);

    if (n_code !== n_exp_code)
      $display("  %0d bundles arrived, image has %0d", n_code, n_exp_code);
    check(n_code == n_exp_code, "every bundle came down the wire");
    check(code_order_ok == 1, "at ascending addresses");

    if (n_pool !== n_exp_pool)
      $display("  %0d pool words arrived, image has %0d", n_pool, n_exp_pool);
    check(n_pool == n_exp_pool, "every pool word too");
    check(pool_order_ok == 1, "at ascending addresses");

    if (n_done !== 1) $display("  img_done pulsed %0d times", n_done);
    check(n_done == 1, "and the board was told exactly once");

    if (entry0 !== `WANT_E0 || entry1 !== `WANT_E1)
      $display("  entry0=%0d entry1=%0d, wanted %0d and %0d",
               entry0, entry1, `WANT_E0, `WANT_E1);
    check(entry0 == `WANT_E0, "the header's entry point survived the reset");
    check(entry1 == `WANT_E1, "and so did the second engine's");
    check(receiving == 1'b0, "and the parser is hunting for the next one");

    for (i = 0; i < n_exp_code && i < n_code; i = i + 1)
      if (got_code[i] !== exp_code[i]) begin
        $display("FAIL bundle %0d: wire %018h, image %018h", i, got_code[i], exp_code[i]);
        errors = errors + 1;
      end

    for (i = 0; i < n_exp_pool && i < n_pool; i = i + 1)
      if (got_pool[i] !== exp_pool[i]) begin
        $display("FAIL pool %0d: wire %09h, image %09h", i, got_pool[i], exp_pool[i]);
        errors = errors + 1;
      end

    $display("uartload: %0d bundles, %0d pool words, entries %0d/%0d",
             n_code, n_pool, entry0, entry1);

    if (errors == 0) $display("__UARTLOAD_OK__");
    else $display("__UARTLOAD_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #4000000000;
    $display("__UARTLOAD_TIMEOUT__ code=%0d pool=%0d recv=%0b", n_code, n_pool, receiving);
    $finish;
  end
endmodule
