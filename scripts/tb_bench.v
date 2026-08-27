// picoBEAM benchmark harness: run one image, count the cycles between
// the 0xA0 and 0xA1 `out` markers, and report. Cycle-exact, so the
// numbers are architectural facts rather than estimates — and the
// project has repeatedly found sim and silicon to agree.
//
//   iverilog -DIMG=\"b1_solo_loop.hex\" -DNB=11 -DOPS=3000 \
//     -o b.vvp tb_bench.v barrel_engine_sim.v && vvp b.vvp

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg ld_en = 0; reg [8:0] ld_addr = 0; reg [71:0] ld_data = 0;
  reg boot_en = 0; reg [8:0] boot_pc = 0;

  wire out_valid; wire [35:0] out_data;
  wire idle, faulted; wire [7:0] fault_reason;
  wire [5:0] dbg_occ, dbg_qcount;
  wire [7:0] dbg_swaps, dbg_evicts;
  wire [11:0] dbg_spawns, dbg_deaths, dbg_sends, dbg_recvs;
  wire [5:0] dbg_scan;
  wire [1:0] dbg_x_seat; wire dbg_x_en; wire [8:0] dbg_pc;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;

  barrel_engine eng(.clk(clk), .rst(rst),
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
    .dbg_occ(dbg_occ), .dbg_qcount(dbg_qcount), .dbg_swaps(dbg_swaps),
    .dbg_spawns(dbg_spawns), .dbg_deaths(dbg_deaths),
    .dbg_sends(dbg_sends), .dbg_recvs(dbg_recvs), .dbg_scan(dbg_scan),
    .dbg_evicts(dbg_evicts),
    .dbg_x_seat(dbg_x_seat), .dbg_x_en(dbg_x_en), .dbg_pc(dbg_pc),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  reg [71:0] image [0:511];
  integer i, cyc = 0, t0 = 0, t1 = 0, started = 0, finished = 0;
  integer bundles = 0;

  always @(posedge clk) if (!rst) begin
    cyc = cyc + 1;
    if (dbg_x_en) bundles = bundles + 1;
    if (out_valid) begin
      if (out_data[7:0] == 8'hA0 && !started) begin t0 = cyc; started = 1; bundles = 0; end
      else if (out_data[7:0] == 8'hA1 && started && !finished) begin t1 = cyc; finished = 1; end
    end
  end

  initial begin
    for (i = 0; i < 512; i = i + 1) image[i] = 0;
    $readmemh(`IMG, image);

    for (i = 0; i < 8192; i = i + 1) eng.frames_frames[i] = 0;
    for (i = 0; i < 2048; i = i + 1) begin
      eng.mbox_words[i] = 0; eng.mbox_hv[i] = 0;
    end
    for (i = 0; i < 512; i = i + 1) begin
      eng.frames_rets[i] = 0; eng.seats_save[i] = 0; eng.code_mem_code[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      eng.procs_serials[i]=0; eng.procs_states[i]=0; eng.procs_pcs[i]=0;
      eng.procs_reasons[i]=0; eng.runq_q[i]=0; eng.procs_flist[i]=i;
      eng.procs_serials2[i]=0; eng.procs_states2[i]=0;
      eng.mbox_heads[i]=0; eng.mbox_tails[i]=0; eng.mbox_cnts[i]=0; eng.mbox_curs[i]=0;
      eng.mbox_heads2[i]=0; eng.mbox_tails2[i]=0; eng.mbox_cnts2[i]=0; eng.mbox_curs2[i]=0;
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

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    for (i = 0; i < `NB; i = i + 1) begin
      @(negedge clk);
      ld_en = 1; ld_addr = i[8:0]; ld_data = image[i];
      @(posedge clk); #1;
    end
    ld_en = 0;
    @(posedge clk); #1;
    @(negedge clk); boot_en = 1; boot_pc = 9'd0;
    @(posedge clk); #1; boot_en = 0;

    for (i = 0; i < 3000000; i = i + 1) begin
      @(posedge clk);
      if (finished) i = 3000000;
    end
    #1;

    if (!finished) $display("BENCH %0s INCOMPLETE (fault=%b pc=%0d)", `IMG, faulted, dbg_pc);
    else $display("BENCH %0s cycles=%0d ops=%0d bundles=%0d fault=%b",
                  `IMG, t1 - t0, `OPS, bundles, faulted);
    $finish;
  end

  initial begin
    #200000000;
    $display("BENCH %0s TIMEOUT", `IMG);
    $finish;
  end
endmodule
