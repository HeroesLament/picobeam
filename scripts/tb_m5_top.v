// The whole two-engine board, from power-up to an answer (notes/36).
//
//   scripts/run_tbs.sh tb_m5_top
//
// `tb_sdboot` proves the loader delivers an image and `tb_fixed:elixir`
// proves an engine runs the Elixir program. Neither can see the forty
// lines of board top that join them: the boot FSM, the shared side door
// feeding TWO code memories from one card read, and the two entry
// points coming out of the image's header rather than the bitstream.
//
// So this is the integration test, and it runs the real thing —
// `Ulx3sM5TopSim` is `Ulx3sM5Top` with the loader's power-up wait and
// SPI clock shortened, and nothing else changed.
//
// The assertion is deliberately about the SECOND engine. Engine 0
// running is what every other testbench already shows; engine 1 having
// fetched, spawned and retired bundles is the thing that is only true
// if the shared side door, the entry-point header and the second
// engine's reset all work.
//
// Prints __M5_OK__ on full success.

`timescale 1ns/1ps

`ifndef CARD_IMG
  `define CARD_IMG "elixir_bytes.hex"
`endif
`ifndef PUSH_IMG
  `define PUSH_IMG "push_bytes.hex"
`endif
// clocks per UART bit, matching `M5CoreSim`'s UDIV
`define UDIV 8

module tb;
  // 12 MHz directly: the PLL lives in the BOARD top, above the core, so
  // simulation does not have to model it — and a design whose clock
  // comes from a hard block it cannot simulate is a design that has to
  // be debugged on the bench.
  reg clk = 0;
  always #41.667 clk = ~clk;

  reg rst = 1, btn2 = 0;
  // the debug cable's other direction, idle high
  reg ftdi_txd = 1;
  wire sd_clk, sd_cmd, sd_d1, sd_d2, sd_d3, ftdi_rxd;
  wire [7:0] led;
  wire miso;

  m5_core_sim dut (
    .clk_12(clk), .rst(rst), .btn2(btn2), .sd_d0(miso), .ftdi_txd(ftdi_txd),
    .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_d1(sd_d1), .sd_d2(sd_d2),
    .sd_d3(sd_d3), .led(led), .ftdi_rxd(ftdi_rxd));

  // the card runs off the same clock; the model only edge-detects SCK
  sd_card #(.LBA(8192), .NBYTES(8192)) card (
    .clk(clk), .cs_n(sd_d3), .sck(sd_clk), .mosi(sd_cmd), .miso(miso));

  integer errors = 0, i;

  task check(input cond, input [255:0] name);
    begin
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  // reach into the flattened design for the two engines' witnesses
  `define E0_SPAWNS dut.core_sp0
  `define E1_SPAWNS dut.core_sp1
  `define E0_DEATHS dut.core_dt0
  `define E1_DEATHS dut.core_dt1
  `define SD_DONE   dut.core_sd_done
  `define SD_ERR    dut.core_sd_err
  `define E0_ENTRY  dut.core_sd_e0
  `define E1_ENTRY  dut.core_sd_e1
  `define OUT_L     dut.core_out_l
  `define FROM_UART dut.core_from_uart
  `define WROTE     dut.core_wrote_r
  `define WERR      dut.core_sd_werr

  // one 8N1 frame down the wire, LSB first — the host half of notes/37
  task upush(input [7:0] b);
    integer k;
    begin
      ftdi_txd = 0;
      repeat (`UDIV) @(posedge clk);
      for (k = 0; k < 8; k = k + 1) begin
        ftdi_txd = b[k];
        repeat (`UDIV) @(posedge clk);
      end
      ftdi_txd = 1;
      repeat (`UDIV) @(posedge clk);
    end
  endtask

  reg [7:0] pimg [0:255];

  initial begin
    repeat (4) @(posedge clk);
    rst = 0;

    // let the card power up and the image land
    for (i = 0; i < 2000000; i = i + 1) begin
      @(posedge clk);
      if (`SD_DONE || `SD_ERR != 0) i = 2000000;
    end

    if (`SD_ERR != 0)
      $display("  loader err=%0d state=%0d", `SD_ERR, dut.core_sd_state);
    check(`SD_ERR == 3'd0, "the card handed over an image");
    check(`SD_DONE == 1'b1, "and said so");
    $display("  entries: engine 0 at %0d, engine 1 at %0d", `E0_ENTRY, `E1_ENTRY);
    check(`E1_ENTRY != 9'd511, "the image named a second entry point");

    // then let both engines run it out. 60k clocks at 12 MHz is 5 ms of
    // board time and about twenty times what the demo needs; two
    // engines in iverilog run at roughly fifty clocks a second, so the
    // budget is set by patience and not by the program.
    for (i = 0; i < 60000; i = i + 1) @(posedge clk);
    #1;

    $display("  engine 0: spawns=%0d deaths=%0d   engine 1: spawns=%0d deaths=%0d",
             `E0_SPAWNS, `E0_DEATHS, `E1_SPAWNS, `E1_DEATHS);
    $display("  last out=%04h  led=%08b", `OUT_L, led);

    check(`E0_SPAWNS > 0, "engine 0 booted and spawned its worker");
    check(`E0_DEATHS > 0, "and reaped it");
    // the one that is only true if the shared side door, the header's
    // second entry point and engine 1's reset all work
    check(`E1_SPAWNS > 0, "ENGINE 1 booted and spawned its worker");
    check(`E1_DEATHS > 0, "and reaped it too");

    // ---- and now the same board, reloaded down one wire (notes/37).
    // Nothing is pressed, nothing is unplugged, the card is not touched:
    // a program arrives and the machine is running it.
    for (i = 0; i < 256; i = i + 1) pimg[i] = 8'h00;
    $readmemh(`PUSH_IMG, pimg);

    for (i = 0; i < 39; i = i + 1) upush(pimg[i]);
    repeat (4000) @(posedge clk);
    #1;

    $display("  after push: from_uart=%0b out=%04h entry0=%0d deaths=%0d",
             `FROM_UART, `OUT_L, `E0_ENTRY, `E0_DEATHS + `E1_DEATHS);

    check(`FROM_UART == 1'b1, "the board took the image off the wire");
    // 0xAB is not a number any other program in this project produces
    check(`OUT_L == 16'h00AB, "and REBOOTED into it — the pushed program ran");

    // ---- and the card kept it (notes/38). The write runs behind the
    // engines, so give it room, then read the CARD MODEL'S memory: the
    // pushed image has to be sitting at LBA 8192 where the loader will
    // find it after a power cycle.
    for (i = 0; i < 200000; i = i + 1) begin
      @(posedge clk);
      if (`WROTE || `WERR) i = 200000;
    end
    #1;

    $display("  card write: wrote=%0b err=%0b", `WROTE, `WERR);
    check(`WERR == 1'b0, "the card took the write");
    check(`WROTE == 1'b1, "and finished it");

    for (i = 0; i < 39; i = i + 1)
      if (card.mem[i] !== pimg[i]) begin
        $display("FAIL card byte %0d: card %02h, pushed %02h", i, card.mem[i], pimg[i]);
        errors = errors + 1;
        i = 39;
      end

    if (errors == 0) $display("__M5_OK__");
    else $display("__M5_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #4000000000;
    $display("__M5_TIMEOUT__ done=%0b err=%0d", `SD_DONE, `SD_ERR);
    $finish;
  end
endmodule
