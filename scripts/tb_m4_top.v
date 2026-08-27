// M3 board-top testbench: the WHOLE top (ROM boot + engine + LED
// instrument), stubbing only the PLL. Silicon should hold no surprises
// that this misses — the M2 rule: simulate the top, not just the parts.
`timescale 1ns/1ps

module tb;
  reg clk = 0;
  always #5 clk = ~clk;
  // FIRE1 is reset; FIRE2 selects demo B (eviction) and UP demo C
  // (fixed point). Defaults pick demo A, ping-pong. `DEMO` overrides.
  `ifndef DEMO
    `define DEMO 0
  `endif
  reg btn1 = 1;
  reg btn2 = (`DEMO == 1);
  reg btn3 = (`DEMO == 2);
  wire [7:0] led;
  wire wifi_en, wifi_gpio0, ftdi_rxd;

  ulx3s_m4_top dut(.clk_25mhz(clk), .btn1(btn1), .btn2(btn2), .btn3(btn3), .led(led),
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
    for (i = 0; i < 2048; i = i + 1) begin
      dut.engine_mbox_words[i] = 0; dut.engine_mbox_hv[i] = 0;
    end
    for (i = 0; i < 256; i = i + 1) begin
      dut.engine_hp_h0[i] = 0; dut.engine_hp_h1[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      dut.engine_mbox_heads[i]=0; dut.engine_mbox_tails[i]=0;
      dut.engine_mbox_cnts[i]=0; dut.engine_mbox_curs[i]=0;
      dut.engine_mbox_heads2[i]=0; dut.engine_mbox_tails2[i]=0;
      dut.engine_mbox_cnts2[i]=0; dut.engine_mbox_curs2[i]=0;
      dut.engine_procs_serials2[i]=0; dut.engine_procs_states2[i]=0;
    end
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
    repeat (400000) @(posedge clk);

    check(dut.engine_flt == 0, "no fault on the board top");

    if (`DEMO == 0) begin
      check(dut.spawns == 1, "one pong server");
      check(dut.sends > 100, "messages are flowing");
      check(dut.recvs > 100, "and being taken");
      // every message sent is a message taken: the counters track
      check(dut.sends >= dut.recvs && dut.sends - dut.recvs <= 2,
        "sends and takes stay in lockstep");
      check(n_out > 0, "the pinger reported at least one block of 64 rounds");
      check(dut.deaths == 0, "nothing died: ping-pong runs forever");
      check(dut.occ == 2, "two live processes");
    end

    if (`DEMO == 1) begin
      // five waiters, four seats: blocked residents must be evicted for
      // the root to keep running, and exactly one is then woken
      check(dut.spawns == 5, "five waiters spawned");
      check(dut.evicts > 0, "blocked residents were EVICTED");
      check(dut.sends == 1, "the root sent exactly one message");
      check(n_out == 1, "exactly one waiter woke and reported");
      check(seen_out[0] == 8'd99, "and it reported the value it was sent");
      check(dut.occ == 4, "four waiters are still blocked, holding their slots");
    end

    if (`DEMO == 2) begin
      // the fixed-point kernel checks ITSELF against the model and
      // reports 0xA0 + 1 (plain sum) + 2 (tick-weighted sum). This is
      // the assertion that had to be made on SILICON, by building a
      // throwaway bitstream that defaulted to demo C, because the top
      // testbench was not in the gate to make it here.
      check(n_out > 0, "the fixed-point demo reported");
      check(seen_out[0] == 8'hA3,
        "both the plain and the tick-weighted Hermite sums match the model");
      check(dut.occ == 1, "one process, spinning on its result");
    end

    $display("DEMO=%0d spawns=%0d sends=%0d recvs=%0d outs=%0d out0=%02h occ=%0d deaths=%0d evicts=%0d",
      `DEMO, dut.spawns, dut.sends, dut.recvs, n_out, seen_out[0],
      dut.occ, dut.deaths, dut.evicts);

    if (errors == 0) $display("__M4_TOP_OK__");
    else $display("__M4_TOP_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #60000000;
    $display("__M4_TOP_TIMEOUT__ bst=%0d spawns=%0d deaths=%0d", dut.bst, dut.spawns, dut.deaths);
    $finish;
  end
endmodule
