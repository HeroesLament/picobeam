// M3 pass 8 testbench — the integrated BarrelEngine running a real
// assembled image: a root that spawns eight workers, each of which
// emits the argument it was handed and dies.
//
//   cd _emit/m3 && iverilog -o tb8.vvp ../../scripts/tb_m3_pass8.v \
//     barrel_engine.v barrel_seq.v seat_unit.v proc_table.v run_queue.v \
//     reg_window_ctx.v frame_ram_proc.v code_mem.v decode.v classify.v alu.v \
//     && vvp tb8.vvp
//
// Nothing is stubbed: real Decode, real Classify, real ALU, real image.
// The workers' `out` values must be exactly {8,7,6,5,4,3,2,1} — the
// arguments the root staged, delivered through spawn's save-area path
// and read back by each child from its own restored window.
//
// Prints __M3_PASS8_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg ld_en = 0; reg [8:0] ld_addr = 0; reg [71:0] ld_data = 0;
  reg boot_en = 0; reg [8:0] boot_pc = 0;

  wire out_valid; wire [35:0] out_data;
  wire idle, faulted; wire [7:0] fault_reason;
  wire [11:0] dbg_sends, dbg_recvs;
  wire [5:0] dbg_scan;
  wire [5:0] dbg_occ, dbg_qcount;
  wire [7:0] dbg_swaps, dbg_spawns, dbg_deaths;
  wire [1:0] dbg_x_seat; wire dbg_x_en; wire [8:0] dbg_pc;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;

  barrel_engine eng(.clk(clk), .rst(rst),
    // Phase 3 gave the engine node-CAM ports; this test predates names —
    // tie the inputs off the way the single-engine board tops do
    .nm_q_hit(1'b0), .nm_q_eng(4'd0), .nm_q_slot(5'd0), .nm_q_serial(22'd0),
    .nm_name_taken(1'b0), .nm_pid_taken(1'b0), .nm_full(1'b1),
    .nm_probe_state(2'd0), .nm_probe_serial(22'd0), .peer_probe_slot(5'd0),
    // notes/33: one engine here, so the VM-wide halt has nobody to tell
    .halt_in(1'b0), .halt_req(),
    .eng_id(4'd0),
    .ring_w_en(), .ring_w_head(), .ring_w_kind(), .ring_w_deng(),
    .ring_w_word(), .ring_w_len(), .ring_w_ready(1'b1),
    .ring_r_valid(1'b0), .ring_r_head(1'b0), .ring_r_kind(4'd0),
    .ring_r_deng(4'd0), .ring_r_word(36'd0),
    .ring_r_len(7'd0), .ring_r_pop(),
    .ld_code_en(ld_en), .ld_code_addr(ld_addr), .ld_code_data(ld_data),
    .boot_en(boot_en), .boot_pc(boot_pc),
    .out_valid(out_valid), .out_data(out_data),
    .idle(idle), .faulted(faulted), .fault_reason(fault_reason),
    .dbg_sends(dbg_sends), .dbg_recvs(dbg_recvs), .dbg_scan(dbg_scan),
    .dbg_occ(dbg_occ), .dbg_qcount(dbg_qcount), .dbg_swaps(dbg_swaps),
    .dbg_spawns(dbg_spawns), .dbg_deaths(dbg_deaths),
    .dbg_x_seat(dbg_x_seat), .dbg_x_en(dbg_x_en), .dbg_pc(dbg_pc),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  reg [71:0] image [0:511];
  integer errors = 0, i, n_out = 0;
  reg [35:0] outs [0:31];
  integer seen [0:15];

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  always @(posedge clk) if (!rst && out_valid) begin
    if (n_out < 32) outs[n_out] = out_data;
    n_out = n_out + 1;
  end

  initial begin
    for (i = 0; i < 512; i = i + 1) image[i] = 0;
    for (i = 0; i < 16; i = i + 1) seen[i] = 0;
    $readmemh("spawn8.hex", image);

    // zero the RAMs the way ECP5 primitives power up
    for (i = 0; i < 8192; i = i + 1) eng.frames_frames[i] = 0;
    for (i = 0; i < 512; i = i + 1) eng.frames_rets[i] = 0;
    for (i = 0; i < 512; i = i + 1) begin eng.seats_save[i] = 0; eng.code_mem_code[i] = 0; end
    for (i = 0; i < 32; i = i + 1) begin
      eng.procs_serials[i]=0; eng.procs_states[i]=0;
      eng.procs_pcs[i]=0; eng.procs_reasons[i]=0; eng.runq_q[i]=0;
      eng.procs_flist[i]=i;
    end
    for (i = 0; i < 256; i = i + 1) begin
      eng.windows_b0r0[i]=0; eng.windows_b0r1[i]=0; eng.windows_b0r2[i]=0;
      eng.windows_b0r3[i]=0; eng.windows_b0r4[i]=0; eng.windows_b0r5[i]=0;
      eng.windows_b0r6[i]=0;
      eng.windows_b1r0[i]=0; eng.windows_b1r1[i]=0; eng.windows_b1r2[i]=0;
      eng.windows_b1r3[i]=0; eng.windows_b1r4[i]=0; eng.windows_b1r5[i]=0;
      eng.windows_b1r6[i]=0;
      eng.windows_b2r0[i]=0; eng.windows_b2r1[i]=0; eng.windows_b2r2[i]=0;
      eng.windows_b2r3[i]=0; eng.windows_b2r4[i]=0; eng.windows_b2r5[i]=0;
      eng.windows_b2r6[i]=0;
    end

    for (i = 0; i < 2048; i = i + 1) begin
      eng.mbox_words[i] = 0; eng.mbox_hv[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      eng.mbox_heads[i]=0; eng.mbox_tails[i]=0; eng.mbox_cnts[i]=0; eng.mbox_curs[i]=0;
      eng.mbox_heads2[i]=0; eng.mbox_tails2[i]=0; eng.mbox_cnts2[i]=0; eng.mbox_curs2[i]=0;
      eng.procs_serials2[i]=0; eng.procs_states2[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // stream the image into CodeMem through the loader side-door
    for (i = 0; i < 16; i = i + 1) begin
      @(negedge clk);
      ld_en = 1; ld_addr = i[8:0]; ld_data = image[i];
      @(posedge clk); #1;
    end
    ld_en = 0;
    @(posedge clk); #1;

    // create the root process at the image entry
    @(negedge clk); boot_en = 1; boot_pc = 9'd0;
    @(posedge clk); #1; boot_en = 0;

    // run to quiescence
    for (i = 0; i < 40000; i = i + 1) begin
      @(posedge clk);
      if (idle && dbg_deaths > 0) i = 40000;
    end
    #1;

    check(faulted == 0, "no faults");
    check(dbg_spawns == 8, "eight spawns committed");
    check(n_out == 8, "eight workers emitted a value");
    check(dbg_deaths == 9, "root plus eight workers died");
    check(dbg_occ == 0, "every proc-table slot was freed");

    // the emitted values must be exactly the arguments the root staged
    for (i = 0; i < n_out && i < 8; i = i + 1) begin
      if (outs[i] >= 1 && outs[i] <= 8) seen[outs[i]] = seen[outs[i]] + 1;
      else check(0, "an out value was outside the staged range");
    end
    for (i = 1; i <= 8; i = i + 1)
      check(seen[i] == 1, "each staged argument came back exactly once");

    $display("spawns=%0d outs=%0d deaths=%0d swaps=%0d occ=%0d values=[%0d %0d %0d %0d %0d %0d %0d %0d]",
      dbg_spawns, n_out, dbg_deaths, dbg_swaps, dbg_occ,
      outs[0], outs[1], outs[2], outs[3], outs[4], outs[5], outs[6], outs[7]);

    if (errors == 0) $display("__M3_PASS8_OK__");
    else $display("__M3_PASS8_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #6000000;
    $display("__M3_PASS8_TIMEOUT__ spawns=%0d outs=%0d deaths=%0d pc=%0d st=[%0d %0d %0d %0d]",
      dbg_spawns, n_out, dbg_deaths, dbg_pc, dbg_st0, dbg_st1, dbg_st2, dbg_st3);
    $finish;
  end
endmodule
