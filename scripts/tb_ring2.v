// Two engines, one ring, one message across it.
//
//   scripts/run_tbs.sh tb_ring2
//
// The first testbench whose result depends on there being more than
// one engine. Engine 0 builds `{7, [8|9], 9}` on its own heap and sends
// it to a process on engine 1; engine 1 reads the elements back.
//
// The assertion that matters is not just that the right numbers come
// out of engine 1 — it is that engine 1's ALLOCATION POINTER MOVED. The
// two engines share no memory, so a term on engine 1's heap can only
// have got there by being rebuilt from flits. Before the serialiser was
// wired in, what would have crossed the ring is engine 0's heap
// address, and engine 1 would have dereferenced a number naming a cell
// in somebody else's address space. That is `notes/26` bug 1, and this
// is the configuration it was a bug ABOUT.
//
// Prints __RING2_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg ld_en0 = 0, ld_en1 = 0, ld_pen0 = 0;
  reg [8:0] ld_addr = 0;
  reg [71:0] ld_d0 = 0, ld_d1 = 0;
  reg [7:0] ld_paddr = 0;
  reg [35:0] ld_pdata = 0;
  reg boot0 = 0, boot1 = 0;

  wire ov0, ov1, idle0, idle1, flt0, flt1;
  wire [35:0] od0, od1;
  wire [7:0] fr0, fr1, fc0, fc1;
  wire [4:0] fs0, fs1;
  wire [11:0] snd0, rcv0, snd1, rcv1;
  wire [5:0] sc0, sc1, occ0, occ1, qc0, qc1;
  wire [7:0] sw0, sw1, sp0, sp1, dt0, dt1;
  wire [1:0] xs0, xs1;
  wire xe0, xe1;
  wire [8:0] pc0, pc1;
  wire [3:0] s00, s01, s02, s03, s10, s11, s12, s13;

  // ---- the ring: two links, one each way. With two engines a
  // unidirectional ring is a pair of point-to-point FIFOs.
  wire a_en, a_head, a_ready, a_valid, a_rhead, a_pop;
  wire [35:0] a_word, a_rword;
  wire [6:0] a_len, a_rlen;
  wire [3:0] a_kind, a_rkind, a_deng, a_rdeng;
  wire b_en, b_head, b_ready, b_valid, b_rhead, b_pop;
  wire [35:0] b_word, b_rword;
  wire [6:0] b_len, b_rlen;
  wire [3:0] b_kind, b_rkind, b_deng, b_rdeng;

  ring_link link_ab(.clk(clk), .rst(rst),
    .w_en(a_en), .w_head(a_head), .w_kind(a_kind), .w_deng(a_deng),
    .w_word(a_word), .w_len(a_len), .w_ready(a_ready),
    .r_valid(a_valid), .r_head(a_rhead), .r_kind(a_rkind), .r_deng(a_rdeng),
    .r_word(a_rword), .r_len(a_rlen), .r_pop(a_pop), .depth());

  ring_link link_ba(.clk(clk), .rst(rst),
    .w_en(b_en), .w_head(b_head), .w_kind(b_kind), .w_deng(b_deng),
    .w_word(b_word), .w_len(b_len), .w_ready(b_ready),
    .r_valid(b_valid), .r_head(b_rhead), .r_kind(b_rkind), .r_deng(b_rdeng),
    .r_word(b_rword), .r_len(b_rlen), .r_pop(b_pop), .depth());

  // notes/33: `erlang:halt/0` stops the RUNTIME, and the runtime is both
  // engines. A sideband, not a ring packet — a packet queues behind a
  // full FIFO and halt must not wait on anything.
  wire h0, h1;
  wire vm_halt = h0 | h1;

  barrel_engine e0(.clk(clk), .rst(rst), .eng_id(4'd0),
    // Phase 3 gave the engine node-CAM ports; ring2 predates names —
    // tie the inputs off the way the single-engine board tops do
    .nm_q_hit(1'b0), .nm_q_eng(4'd0), .nm_q_slot(5'd0), .nm_q_serial(22'd0),
    .nm_name_taken(1'b0), .nm_pid_taken(1'b0), .nm_full(1'b1),
    .nm_probe_state(2'd0), .nm_probe_serial(22'd0), .peer_probe_slot(5'd0),
        .halt_in(vm_halt), .halt_req(h0),
    .ld_code_en(ld_en0), .ld_code_addr(ld_addr), .ld_code_data(ld_d0),
    .ld_pool_en(ld_pen0), .ld_pool_addr(ld_paddr), .ld_pool_data(ld_pdata),
    .boot_en(boot0), .boot_pc(9'd0),
    .ring_w_en(a_en), .ring_w_head(a_head), .ring_w_kind(a_kind),
    .ring_w_deng(a_deng), .ring_w_word(a_word),
    .ring_w_len(a_len), .ring_w_ready(a_ready),
    .ring_r_valid(b_valid), .ring_r_head(b_rhead), .ring_r_kind(b_rkind),
    .ring_r_deng(b_rdeng), .ring_r_word(b_rword),
    .ring_r_len(b_rlen), .ring_r_pop(b_pop),
    .out_valid(ov0), .out_data(od0),
    .idle(idle0), .faulted(flt0), .fault_reason(fr0),
    .fault_slot(fs0), .fault_count(fc0),
    .dbg_sends(snd0), .dbg_recvs(rcv0), .dbg_scan(sc0),
    .dbg_occ(occ0), .dbg_qcount(qc0), .dbg_swaps(sw0),
    .dbg_spawns(sp0), .dbg_deaths(dt0),
    .dbg_x_seat(xs0), .dbg_x_en(xe0), .dbg_pc(pc0),
    .dbg_st0(s00), .dbg_st1(s01), .dbg_st2(s02), .dbg_st3(s03));

  barrel_engine e1(.clk(clk), .rst(rst), .eng_id(4'd1),
    // Phase 3 gave the engine node-CAM ports; ring2 predates names —
    // tie the inputs off the way the single-engine board tops do
    .nm_q_hit(1'b0), .nm_q_eng(4'd0), .nm_q_slot(5'd0), .nm_q_serial(22'd0),
    .nm_name_taken(1'b0), .nm_pid_taken(1'b0), .nm_full(1'b1),
    .nm_probe_state(2'd0), .nm_probe_serial(22'd0), .peer_probe_slot(5'd0),
        .halt_in(vm_halt), .halt_req(h1),
    .ld_code_en(ld_en1), .ld_code_addr(ld_addr), .ld_code_data(ld_d1),
    .ld_pool_en(1'b0), .ld_pool_addr(8'd0), .ld_pool_data(36'd0),
    .boot_en(boot1), .boot_pc(9'd0),
    .ring_w_en(b_en), .ring_w_head(b_head), .ring_w_kind(b_kind),
    .ring_w_deng(b_deng), .ring_w_word(b_word),
    .ring_w_len(b_len), .ring_w_ready(b_ready),
    .ring_r_valid(a_valid), .ring_r_head(a_rhead), .ring_r_kind(a_rkind),
    .ring_r_deng(a_rdeng), .ring_r_word(a_rword),
    .ring_r_len(a_rlen), .ring_r_pop(a_pop),
    .out_valid(ov1), .out_data(od1),
    .idle(idle1), .faulted(flt1), .fault_reason(fr1),
    .fault_slot(fs1), .fault_count(fc1),
    .dbg_sends(snd1), .dbg_recvs(rcv1), .dbg_scan(sc1),
    .dbg_occ(occ1), .dbg_qcount(qc1), .dbg_swaps(sw1),
    .dbg_spawns(sp1), .dbg_deaths(dt1),
    .dbg_x_seat(xs1), .dbg_x_en(xe1), .dbg_pc(pc1),
    .dbg_st0(s10), .dbg_st1(s11), .dbg_st2(s12), .dbg_st3(s13));

  reg [71:0] img0 [0:511];
  reg [71:0] img1 [0:511];
  reg [35:0] pool0 [0:255];
  reg [35:0] exp0 [0:15];
  reg [35:0] exp1 [0:15];

  reg [35:0] got0 [0:15];
  reg [35:0] got1 [0:15];
  integer n0 = 0, n1 = 0, ne0 = 0, ne1 = 0;
  integer errors = 0, i;
  integer hp1_before;

  always @(posedge clk) if (!rst && ov0) begin
    if (n0 < 16) got0[n0] = od0;
    n0 = n0 + 1;
  end
  always @(posedge clk) if (!rst && ov1) begin
    if (n1 < 16) got1[n1] = od1;
    n1 = n1 + 1;
  end

`ifdef TRACE
  always @(posedge clk) if (!rst) begin
    if (e0.snd_en) $display("T=%0t SEND pid=%09h msg=%09h rem=%0b del=%0b dl=%0b longp=%0b",
      $time, e0.snd_pid, e0.snd_msg, e0.snd_remote, e0.delivered, e0.dead_letter, e0.is_send_long);
    if (e0.send_go) $display("T=%0t SENDGO seat=%0d rem=%0b pid=%09h", $time, e0.send_seat, e0.sr_rem, e0.sr_pid);
    if (e0.ser_counted) $display("T=%0t COUNTED n=%0d rem=%0b goem=%0b rdy=%0b hdr=%0b",
      $time, e0.ser_count, e0.sr_rem, e0.ser_go_emit, a_ready, e0.sr_hdr);
    if (a_en) $display("T=%0t RING-PUSH head=%0b word=%09h len=%0d", $time, a_head, a_word, a_len);
    if (a_valid) $display("T=%0t RING-AVAIL head=%0b word=%09h len=%0d pop=%0b st=%0d ok=%0b live=%0b slot=%0d pt_st=%0d pt_ser=%0d want=%0d",
      $time, a_rhead, a_rword, a_rlen, a_pop, e1.rg_st, e1.rg_ok, e1.rg_live, e1.rg_slot,
      e1.pt_rd5_state, e1.pt_rd5_serial, a_rword[21:0]);
    if (e1.mb_rg) $display("T=%0t E1-ENQ word=%09h slot=%0d head=%0b len=%0d",
      $time, e1.ring_r_word, e1.rg_slot, e1.rg_head, e1.rg_len);
  end
`endif

  task check(input cond, input [255:0] name);
    begin
      if (!cond) begin
        $display("FAIL: %0s (t=%0t)", name, $time);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    for (i = 0; i < 512; i = i + 1) begin img0[i] = 0; img1[i] = 0; end
    for (i = 0; i < 256; i = i + 1) pool0[i] = 0;
    for (i = 0; i < 16; i = i + 1) begin
      exp0[i] = 36'hFFFFFFFFF; exp1[i] = 36'hFFFFFFFFF;
    end
    $readmemh("ring2a.hex", img0);
    $readmemh("ring2b.hex", img1);
    $readmemh("ring2a_pool.hex", pool0);
    $readmemh("ring2a_expect.hex", exp0);
    $readmemh("ring2b_expect.hex", exp1);

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    for (i = 0; i < 64; i = i + 1) begin
      @(negedge clk);
      ld_en0 = 1; ld_en1 = 1; ld_addr = i[8:0];
      ld_d0 = img0[i]; ld_d1 = img1[i];
      @(posedge clk); #1;
    end
    ld_en0 = 0; ld_en1 = 0;
    @(posedge clk); #1;

    for (i = 0; i < 256; i = i + 1) begin
      @(negedge clk);
      ld_pen0 = 1; ld_paddr = i[7:0]; ld_pdata = pool0[i];
      @(posedge clk); #1;
    end
    ld_pen0 = 0;
    @(posedge clk); #1;

    // engine 1 first, so its receiver is already scanning when the
    // packet lands — the ring has latency but no ordering guarantee
    // against a process that has not started yet
    @(negedge clk); boot1 = 1;
    @(posedge clk); #1; boot1 = 0;
    @(negedge clk); boot0 = 1;
    @(posedge clk); #1; boot0 = 0;

    hp1_before = e1.hp_hp;

    for (i = 0; i < 20000; i = i + 1) begin
      @(posedge clk);
      if (n1 >= 5 && idle0) i = 20000;
    end
    #1;

    for (i = 0; i < 16; i = i + 1) begin
      if (exp0[i] !== 36'hFFFFFFFFF) ne0 = ne0 + 1;
      if (exp1[i] !== 36'hFFFFFFFFF) ne1 = ne1 + 1;
    end

    check(n0 == ne0, "engine 0 reported once per expected out");
    check(n1 == ne1, "engine 1 reported once per expected out");

    for (i = 0; i < ne0; i = i + 1)
      if (got0[i] !== exp0[i]) begin
        $display("FAIL e0 out %0d: got %09h, want %09h", i, got0[i], exp0[i]);
        errors = errors + 1;
      end

    for (i = 0; i < ne1; i = i + 1)
      if (got1[i] !== exp1[i]) begin
        $display("FAIL e1 out %0d: got %09h, want %09h", i, got1[i], exp1[i]);
        errors = errors + 1;
      end

    // the point of the whole exercise
    if (e1.hp_hp == 0)
      $display("  engine 1 allocated nothing: the term was not rebuilt");
    check(e1.hp_hp > 0,
          "engine 1 ALLOCATED — the message was copied onto its own heap");

    check(!flt0, "engine 0 did not fault");
    check(!flt1, "engine 1 did not fault");
    check(e0.dbg_sends > 0, "engine 0 counted a send");

    $display("  e0 outs=%0d/%0d  e1 outs=%0d/%0d  e1 heap cells=%0d",
             n0, ne0, n1, ne1, e1.hp_hp);

    if (errors == 0) $display("__RING2_OK__");
    else $display("__RING2_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #4000000;
    $display("__RING2_TIMEOUT__ n0=%0d n1=%0d", n0, n1);
    $finish;
  end
endmodule
