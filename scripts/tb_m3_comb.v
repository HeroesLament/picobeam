// M3 board-top testbench: the WHOLE top (ROM boot + engine + LED
// instrument), stubbing only the PLL. Silicon should hold no surprises
// that this misses — the M2 rule: simulate the top, not just the parts.
`timescale 1ns/1ps

module tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg btn1 = 1, btn2 = 1;   // FIRE2 held: demo B, the comb
  wire [7:0] led;
  wire wifi_en, wifi_gpio0, ftdi_rxd;

  ulx3s_m3_top dut(.clk_25mhz(clk), .btn1(btn1), .btn2(btn2), .led(led),
    .wifi_en(wifi_en), .wifi_gpio0(wifi_gpio0), .ftdi_rxd(ftdi_rxd));

  integer errors = 0, i;
  integer act [0:3];
  integer prev_spawn = 0;
  reg [7:0] seen_out [0:15];
  integer n_out = 0;

  task check(input cond, input [255:0] name);
    if (!cond) begin $display("FAIL: %0s", name); errors = errors + 1; end
  endtask

  // count raw per-seat retire strobes straight off the LED pins
  always @(posedge dut.clk_12) if (dut.bst == 3) begin
    for (i = 0; i < 4; i = i + 1) if (led[i]) act[i] = act[i] + 1;
    if (dut.out_v) begin
      if (n_out < 16) seen_out[n_out] = dut.out_d[7:0];
      n_out = n_out + 1;
    end
  end

  initial begin
    for (i = 0; i < 4; i = i + 1) act[i] = 0;
    for (i = 0; i < 8192; i = i + 1) dut.engine_frames_frames[i] = 0;
    for (i = 0; i < 512; i = i + 1) begin
      dut.engine_frames_rets[i] = 0; dut.engine_seats_save[i] = 0;
      dut.engine_code_mem_code[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      dut.engine_procs_serials[i]=0; dut.engine_procs_states[i]=0;
      dut.engine_procs_pcs[i]=0; dut.engine_procs_reasons[i]=0;
      dut.engine_runq_q[i]=0; dut.engine_procs_flist[i]=i;
    end
    for (i = 0; i < 256; i = i + 1) begin
      dut.engine_windows_b0r0[i]=0; dut.engine_windows_b0r1[i]=0;
      dut.engine_windows_b0r2[i]=0; dut.engine_windows_b0r3[i]=0;
      dut.engine_windows_b0r4[i]=0; dut.engine_windows_b0r5[i]=0;
      dut.engine_windows_b0r6[i]=0;
      dut.engine_windows_b1r0[i]=0; dut.engine_windows_b1r1[i]=0;
      dut.engine_windows_b1r2[i]=0; dut.engine_windows_b1r3[i]=0;
      dut.engine_windows_b1r4[i]=0; dut.engine_windows_b1r5[i]=0;
      dut.engine_windows_b1r6[i]=0;
      dut.engine_windows_b2r0[i]=0; dut.engine_windows_b2r1[i]=0;
      dut.engine_windows_b2r2[i]=0; dut.engine_windows_b2r3[i]=0;
      dut.engine_windows_b2r4[i]=0; dut.engine_windows_b2r5[i]=0;
      dut.engine_windows_b2r6[i]=0;
    end

    repeat (10) @(posedge clk);
    btn1 = 0;                        // release boot reset

    // run until the root reports done (or the guard trips)
    repeat (200000) @(posedge clk);

    check(dut.engine_flt == 0, "no fault");
    check(dut.spawns == 6, "six spinners spawned");
    check(dut.deaths == 1, "only the root exited");
    check(dut.occ == 6, "six live processes");
    check(dut.qcnt == 2, "two queued");
    // THE instrument: four seats, equal shares
    // A floor, not a calibration. The absolute strobe count is a
    // function of the run window and the boot sequence — it drifted the
    // moment the demo ROM grew from 64 bundles to 128 — and asserting a
    // number tuned to one run makes the testbench fail for reasons that
    // are not about the machine. What is being claimed here is only
    // "this seat is carrying traffic, not stalled"; the REAL instrument
    // is the ratio check below.
    for (i = 0; i < 4; i = i + 1) check(act[i] > 1000, "seat LED carries sustained traffic");
    for (i = 0; i < 4; i = i + 1)
      check(act[i] * 10 > act[0] * 8 && act[i] * 8 < act[0] * 10,
        "seat shares within 25% (the 1/T comb)");

    $display("spawns=%0d outs=%0d deaths=%0d occ=%0d q=%0d swaps=%0d seat_strobes=[%0d %0d %0d %0d]",
      dut.spawns, n_out, dut.deaths, dut.occ, dut.qcnt, dut.swaps,
      act[0], act[1], act[2], act[3]);
    $display("marker=%0d", seen_out[0]);

    if (errors == 0) $display("__M3_COMB_OK__");
    else $display("__M3_COMB_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #40000000;
    $display("__M3_COMB_TIMEOUT__ bst=%0d spawns=%0d deaths=%0d", dut.bst, dut.spawns, dut.deaths);
    $finish;
  end
endmodule
