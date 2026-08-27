// `SdBoot` against a card (notes/34).
//
//   scripts/run_tbs.sh tb_sdboot
//
//   cd _emit/sd && iverilog -DCARD_IMG='"sdimg_bytes.hex"' -o tbsd.vvp \
//     ../../scripts/tb_sdboot.v ../../scripts/sd_card_model.v \
//     ../all/p/sd_boot.v && vvp tbsd.vvp
//
// `notes/26` bug 9: 525 lines of loader, zero tests. Everything it does
// — the power-up gap, CMD0's retry, CMD8's five-byte R7, the
// CMD55/ACMD41 loop, CMD17 per sector, the token wait, the byte-stream
// parser — happens between reset and one `done` bit, and none of it had
// ever run.
//
// The assertion is the strongest one available: every bundle and every
// pool word that reaches the engine's loader side-door is compared,
// word for word, against what `Encoding.image/2` produced for the same
// program. Not "it finished" — "it delivered the image".
//
// The image is three sectors on purpose. `SdBoot`'s moduledoc says the
// parser is sector-agnostic and that images cross sector boundaries
// freely; bundle 112 of this one starts at byte 1016 and ends at 1024,
// which is the claim made physical.
//
// Prints __SDBOOT_OK__ on full success.

`timescale 1ns/1ps

`ifndef CARD_IMG
  `define CARD_IMG "sdimg_bytes.hex"
`endif
`ifndef EXP_CODE
  `define EXP_CODE "sdimg_code.hex"
`endif
`ifndef EXP_POOL
  `define EXP_POOL "sdimg_pool.hex"
`endif
`ifndef WANT_E0
  `define WANT_E0 0
`endif
`ifndef WANT_E1
  `define WANT_E1 511
`endif

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  wire sck, mosi, cs_n, miso;
  wire busy, done;
  reg wr_en = 0, wr_go = 0;
  reg [7:0] wr_byte = 0;
  reg [12:0] wr_idx = 0, wr_len = 0;
  wire wr_busy, wr_done, wr_err;
  // `wr_done` is a one-cycle strobe, which is the right shape for RTL
  // and the wrong shape to sample from a testbench that reads at the
  // same edge the DUT writes. Latch it.
  reg saw_done = 0;
  wire [8:0] entry0, entry1;
  wire [2:0] err;
  wire [3:0] state_dbg;
  wire [7:0] last_rx;
  wire code_en, pool_en;
  wire [8:0] code_addr;
  wire [71:0] code_data;
  wire [7:0] pool_addr;
  wire [35:0] pool_data;

  // `sd_boot_sim`, not `sd_boot` with parameter overrides: EHDL folds
  // `param` at elaboration, so a Verilog `#(.PWRWAIT(64))` is accepted
  // and ignored. The wrapper overrides them where overriding works — on
  // the `instance`, before elaboration — and passes every port through.
  // Same source, a short power-up wait and a fast SPI clock.
  sd_boot_sim dut (
    .clk(clk), .rst(rst), .miso(miso),
    .sck(sck), .mosi(mosi), .cs_n(cs_n),
    .code_en(code_en), .code_addr(code_addr), .code_data(code_data),
    .pool_en(pool_en), .pool_addr(pool_addr), .pool_data(pool_data),
    .wr_en(wr_en), .wr_byte(wr_byte), .wr_idx(wr_idx),
    .wr_go(wr_go), .wr_len(wr_len),
    .wr_busy(wr_busy), .wr_done(wr_done), .wr_err(wr_err),
    .entry0(entry0), .entry1(entry1),
    .busy(busy), .done(done), .err(err), .state_dbg(state_dbg),
    .last_rx(last_rx));

  sd_card #(.LBA(8192), .NBYTES(8192)) card (
    .clk(clk), .cs_n(cs_n), .sck(sck), .mosi(mosi), .miso(miso));

  // ---- what the loader delivered, in the order it delivered it
  reg [71:0] got_code [0:511];
  reg [35:0] got_pool [0:255];
  integer n_code = 0, n_pool = 0;
  integer code_order_ok = 1, pool_order_ok = 1;

  always @(posedge clk) if (wr_done) saw_done <= 1;

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
    for (i = 0; i < 512; i = i + 1) exp_code[i] = {72{1'b1}};
    for (i = 0; i < 256; i = i + 1) exp_pool[i] = {36{1'b1}};
    $readmemh(`EXP_CODE, exp_code);
    $readmemh(`EXP_POOL, exp_pool);
    for (i = 0; i < 512; i = i + 1)
      if (exp_code[i] !== {72{1'b1}}) n_exp_code = n_exp_code + 1;
    for (i = 0; i < 256; i = i + 1)
      if (exp_pool[i] !== {36{1'b1}}) n_exp_pool = n_exp_pool + 1;

    repeat (4) @(posedge clk);
    rst = 0;

    // ~3 sectors at 256 clocks a byte, plus the init handshake
    for (i = 0; i < 400000; i = i + 1) begin
      @(posedge clk);
      if (done || err != 0) i = 400000;
    end
    #1;

    if (err != 0)
      $display("  loader stopped with err=%0d state=%0d last_rx=%02h",
               err, state_dbg, last_rx);
    check(err == 3'd0, "the loader reached the end without an error");
    check(done == 1'b1, "and reported done");
    check(busy == 1'b0, "and dropped busy, which is what holds the engine in reset");
    check(cs_n == 1'b1, "and released the card");

    // v2's entry points (notes/36). `mk_image` writes entry0 = the
    // image's own entry and entry1 = 0x1FF, "do not boot engine 1".
    if (entry0 !== `WANT_E0 || entry1 !== `WANT_E1)
      $display("  entry0=%0d entry1=%0d, wanted %0d and %0d",
               entry0, entry1, `WANT_E0, `WANT_E1);
    check(entry0 == `WANT_E0, "the header's entry point came through");
    check(entry1 == `WANT_E1, "and so did the second engine's");

    if (n_code !== n_exp_code)
      $display("  %0d bundles delivered, image has %0d", n_code, n_exp_code);
    check(n_code == n_exp_code, "every bundle in the image arrived");
    check(code_order_ok == 1, "at ascending addresses, one per bundle");

    if (n_pool !== n_exp_pool)
      $display("  %0d pool words delivered, image has %0d", n_pool, n_exp_pool);
    check(n_pool == n_exp_pool, "every pool word arrived");
    check(pool_order_ok == 1, "at ascending addresses too");

    for (i = 0; i < n_exp_code && i < n_code; i = i + 1)
      if (got_code[i] !== exp_code[i]) begin
        $display("FAIL bundle %0d: card %018h, image %018h", i, got_code[i], exp_code[i]);
        errors = errors + 1;
      end

    for (i = 0; i < n_exp_pool && i < n_pool; i = i + 1)
      if (got_pool[i] !== exp_pool[i]) begin
        $display("FAIL pool %0d: card %09h, image %09h", i, got_pool[i], exp_pool[i]);
        errors = errors + 1;
      end

    // ---- and the other direction (notes/38). Fill the buffer with a
    // recognisable pattern, write it, and read it back out of the card
    // model — which stores what it was sent, so a writer that gets the
    // token, the length or the CRC wrong cannot pass this.
    for (i = 0; i < 1024; i = i + 1) begin
      @(posedge clk);
      wr_en = 1; wr_idx = i[12:0]; wr_byte = (i * 7 + 3) & 8'hFF;
      @(posedge clk);
      wr_en = 0;
    end

    @(posedge clk); wr_len = 13'd1024; wr_go = 1;
    @(posedge clk); wr_go = 0;

    for (i = 0; i < 400000; i = i + 1) begin
      @(posedge clk);
      if (saw_done || wr_err) i = 400000;
    end
    #1;

    check(wr_err == 1'b0, "the card took the write");
    check(saw_done == 1'b1, "and said so");
    check(cs_n == 1'b1, "and was released again");

    for (i = 0; i < 1024; i = i + 1)
      if (card.mem[i] !== ((i * 7 + 3) & 8'hFF)) begin
        $display("FAIL written byte %0d: card %02h, sent %02h",
                 i, card.mem[i], (i * 7 + 3) & 8'hFF);
        errors = errors + 1;
        i = 1024;
      end

    $display("sdboot: %0d bundles, %0d pool words, err=%0d, wrote 2 sectors err=%0b",
             n_code, n_pool, err, wr_err);

    if (errors == 0) $display("__SDBOOT_OK__");
    else $display("__SDBOOT_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #40000000;
    $display("__SDBOOT_TIMEOUT__ state=%0d err=%0d last_rx=%02h bundles=%0d",
             state_dbg, err, last_rx, n_code);
    $finish;
  end
endmodule
