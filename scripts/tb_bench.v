// picoBEAM benchmark harness: run one image, count the cycles between
// the 0xA0 and 0xA1 `out` markers, and report. Cycle-exact, so the
// numbers are architectural facts rather than estimates — and the
// project has repeatedly found sim and silicon to agree.
//
//   scripts/run_tbs.sh tb_bench          (all six, from _emit/bench/manifest.txt)
//
// The engine setup is tb_fixed's: the name table as a node unit beside
// the engine (notes/53), the literal-pool side door tied off, every RAM
// zeroed the way the primitives power up, the whole 512-bundle store
// loaded. The previous harness predated the name table moving out of
// the engine: its `nm_*` inputs floated, the send path read X, and the
// first `out` was X with simulation time stuck at that step until the
// 900 s wall cap, which is why every bench "failed" with no output.
//
// -DIMG/-DNB/-DOPS as before; NB is reported, OPS sets the ops count the
// cycles are divided by in notes/18.

`timescale 1ns/1ps

`ifndef IMG
  `define IMG "b1_solo_loop.hex"
`endif
`ifndef NB
  `define NB 0
`endif
`ifndef OPS
  `define OPS 1
`endif

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg ld_en = 0; reg [8:0] ld_addr = 0; reg [71:0] ld_data = 0;
  reg boot_en = 0; reg [8:0] boot_pc = 0;

  wire out_valid; wire [35:0] out_data;
  wire idle, faulted; wire [7:0] fault_reason;
  wire [4:0] fault_slot; wire [7:0] fault_count;
  wire [11:0] dbg_sends, dbg_recvs;
  wire [5:0] dbg_scan;
  wire [5:0] dbg_occ, dbg_qcount;
  wire [7:0] dbg_swaps, dbg_spawns, dbg_deaths;
  wire [1:0] dbg_x_seat; wire dbg_x_en; wire [8:0] dbg_pc;
  wire [4:0] dbg_st0, dbg_st1, dbg_st2, dbg_st3;

  wire [15:0] nm_qn;
  wire nm_qh; wire [3:0] nm_qe; wire [4:0] nm_qs; wire [21:0] nm_qr;
  wire [3:0] nm_we; wire [4:0] nm_ws; wire [21:0] nm_wr;
  wire nm_wen, nm_tk, nm_pt, nm_fl, nm_clr, nm_die;
  wire [35:0] nm_dpid;
  wire [4:0] nm_ps;

  name_table names(.clk(clk), .rst(rst),
    .q_name(nm_qn), .q_hit(nm_qh), .q_eng(nm_qe), .q_slot(nm_qs), .q_serial(nm_qr),
    .w_name(nm_qn), .w_eng(nm_we), .w_slot(nm_ws), .w_serial(nm_wr), .w_en(nm_wen),
    .name_taken(nm_tk), .pid_taken(nm_pt), .table_full(nm_fl),
    .clr_en(nm_clr), .clr_name(nm_qn),
    .die_en(nm_die), .die_eng(4'd0), .die_slot(nm_dpid[26:22]), .die_serial(nm_dpid[21:0]),
    .q2_name(16'd0), .w2_name(16'd0), .w2_eng(4'd0), .w2_slot(5'd0),
    .w2_serial(22'd0), .w2_en(1'b0), .clr2_en(1'b0), .clr2_name(16'd0),
    .die2_en(1'b0), .die2_eng(4'd0), .die2_slot(5'd0), .die2_serial(22'd0));

  barrel_engine eng(.clk(clk), .rst(rst),
    .nm_q_name(nm_qn), .nm_q_hit(nm_qh), .nm_q_eng(nm_qe), .nm_q_slot(nm_qs),
    .nm_q_serial(nm_qr), .nm_name_taken(nm_tk), .nm_pid_taken(nm_pt), .nm_full(nm_fl),
    .nm_w_en(nm_wen), .nm_w_eng(nm_we), .nm_w_slot(nm_ws), .nm_w_serial(nm_wr),
    .nm_clr_en(nm_clr), .nm_die(nm_die), .nm_die_pid(nm_dpid),
    .nm_probe_slot(nm_ps), .nm_probe_state(2'd0), .nm_probe_serial(22'd0),
    .peer_probe_slot(5'd0),
    // notes/33: one engine here, so the VM-wide halt has nobody to tell
    .halt_in(1'b0), .halt_req(),
    .eng_id(4'd0),
    .ring_w_en(), .ring_w_head(), .ring_w_kind(), .ring_w_deng(),
    .ring_w_word(), .ring_w_len(), .ring_w_ready(1'b1),
    .ring_r_valid(1'b0), .ring_r_head(1'b0), .ring_r_kind(4'd0),
    .ring_r_deng(4'd0), .ring_r_word(36'd0),
    .ring_r_len(7'd0), .ring_r_pop(),
    .ld_code_en(ld_en), .ld_code_addr(ld_addr), .ld_code_data(ld_data),
    .ld_pool_en(1'b0), .ld_pool_addr(8'd0), .ld_pool_data(36'd0),
    .boot_en(boot_en), .boot_pc(boot_pc),
    .out_valid(out_valid), .out_data(out_data),
    .idle(idle), .faulted(faulted), .fault_reason(fault_reason),
    .fault_slot(fault_slot), .fault_count(fault_count),
    .dbg_sends(dbg_sends), .dbg_recvs(dbg_recvs), .dbg_scan(dbg_scan),
    .dbg_occ(dbg_occ), .dbg_qcount(dbg_qcount), .dbg_swaps(dbg_swaps),
    .dbg_spawns(dbg_spawns), .dbg_deaths(dbg_deaths),
    .dbg_x_seat(dbg_x_seat), .dbg_x_en(dbg_x_en), .dbg_pc(dbg_pc),
    .dbg_st0(dbg_st0), .dbg_st1(dbg_st1), .dbg_st2(dbg_st2), .dbg_st3(dbg_st3));

  reg [71:0] image [0:511];
  integer i, cyc = 0, t0 = 0, t1 = 0, started = 0, finished = 0, bundles = 0;

  // the measured span: from the 0xA0 marker to the 0xA1 marker, counting
  // every bundle the X stage retires in between
  always @(posedge clk) if (!rst) begin
    cyc = cyc + 1;
    if (started && !finished && dbg_x_en) bundles = bundles + 1;
    if (out_valid) begin
      if (out_data[7:0] == 8'hA0 && !started) begin t0 = cyc; started = 1; bundles = 0; end
      else if (out_data[7:0] == 8'hA1 && started && !finished) begin t1 = cyc; finished = 1; end
    end
  end

  initial begin
    for (i = 0; i < 512; i = i + 1) image[i] = 0;
    $readmemh(`IMG, image);

    // zero the RAMs the way the primitives power up (tb_fixed's list)
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
    for (i = 0; i < 256; i = i + 1) begin
      eng.hp_h0[i] = 0; eng.hp_h1[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      eng.mbox_heads[i]=0; eng.mbox_tails[i]=0; eng.mbox_cnts[i]=0; eng.mbox_curs[i]=0;
      eng.mbox_heads2[i]=0; eng.mbox_tails2[i]=0; eng.mbox_cnts2[i]=0; eng.mbox_curs2[i]=0;
      eng.procs_serials2[i]=0; eng.procs_states2[i]=0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // the whole store, as tb_fixed does: a short image's tail is zeros
    for (i = 0; i < 512; i = i + 1) begin
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

    if (!finished) $display("BENCH %0s INCOMPLETE (fault=%b pc=%0d started=%0d)", `IMG, faulted, dbg_pc, started);
    else $display("BENCH %0s cycles=%0d ops=%0d bundles=%0d nb=%0d fault=%b",
                  `IMG, t1 - t0, `OPS, bundles, `NB, faulted);
    $finish;
  end

  initial begin
    #40000000;
    $display("BENCH %0s TIMEOUT", `IMG);
    $finish;
  end
endmodule
