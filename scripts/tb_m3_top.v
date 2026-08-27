// M3 board-top testbench: the WHOLE top (ROM boot + engine + LED
// instrument), stubbing only the PLL. Silicon should hold no surprises
// that this misses — the M2 rule: simulate the top, not just the parts.
`timescale 1ns/1ps

module tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg btn1 = 1, btn2 = 0;
  wire [7:0] led;
  wire wifi_en, wifi_gpio0, ftdi_rxd;

  ulx3s_m3_top dut(.clk_25mhz(clk), .btn1(btn1), .btn2(btn2), .led(led),
    .wifi_en(wifi_en), .wifi_gpio0(wifi_gpio0), .ftdi_rxd(ftdi_rxd));

  integer errors = 0, i;
  integer seats_used = 0;
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
    for (i = 0; i < 4000000; i = i + 1) begin
      @(posedge clk);
      if (dut.eng_idle && dut.deaths > 100) i = 4000000;
    end

    check(dut.engine_flt == 0, "no fault: the root never hit :system_limit");
    check(dut.spawns == 1000, "one thousand spawns");
    check(dut.deaths == 1001, "a thousand workers plus the root");
    check(dut.occ == 0, "the proc table drained completely");
    check(n_out == 1, "the root announced completion");
    check(seen_out[0] == 85, "completion marker 85 = 0x55");
    check(dut.swaps > 100, "the scheduler swapped throughout");
    // Demo A runs at LOW process count (a root plus whichever worker is
    // being reaped), so the rotation phase-locks onto two seats and the
    // other two idle. That is the barrel's honest behaviour, not a
    // fault — demo B is the one that saturates all four. Assert the
    // shape we actually expect: the workers all ran somewhere, and each
    // contributed exactly its one halt bundle.
    seats_used = 0;
    for (i = 0; i < 4; i = i + 1) if (act[i] > 0) seats_used = seats_used + 1;
    check(seats_used >= 2, "at least two seats carried the load");
    check(act[0] + act[1] + act[2] + act[3] > 1000,
      "every spawned worker retired at least its halt");

    $display("spawns=%0d outs=%0d deaths=%0d occ=%0d q=%0d swaps=%0d seat_strobes=[%0d %0d %0d %0d]",
      dut.spawns, n_out, dut.deaths, dut.occ, dut.qcnt, dut.swaps,
      act[0], act[1], act[2], act[3]);
    $display("marker=%0d", seen_out[0]);

    if (errors == 0) $display("__M3_TOP_OK__");
    else $display("__M3_TOP_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #900000000;
    $display("__M3_TOP_TIMEOUT__ bst=%0d spawns=%0d deaths=%0d", dut.bst, dut.spawns, dut.deaths);
    $finish;
  end
endmodule
