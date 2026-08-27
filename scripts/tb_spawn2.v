// Cross-engine spawn: one image, two engines, one ring.
//
//   scripts/run_tbs.sh tb_spawn2
//
// `tb_ring2` proved two engines can pass a MESSAGE. This proves they
// can hand each other WORK — `notes/47` sized the gap and `notes/49`
// closed it.
//
// The harness is `duo`, not two `barrel_engine`s wired up here, for one
// reason: `N_ENG` is an EHDL `param` and folds to a `localparam` that
// Verilog cannot override. A two-engine configuration has to be chosen
// on an `instance`, so it is a module.
//
// ONE image, loaded into both engines. That is what a spawn needs and a
// message does not: engine 0 sends an entry pc and engine 1 jumps to
// it, so the two have to be holding the same program at the same
// addresses.
//
// Only engine 0 is booted. Engine 1 starts with an empty proc table and
// an empty run queue, and everything it ever runs arrives over the ring
// — which is what makes the second output below evidence rather than
// decoration. Its ENGINE FIELD is 1, and there is no way for engine 0
// to mint that pid except by asking.
//
// The expectations come from `Machine` running the same program with
// `engines: 2`, so this is a model-versus-gates comparison and not a
// hand-written guess.
//
// Prints __SPAWN2_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  reg ld_en = 0, ld_pen = 0;
  reg [8:0] ld_addr = 0;
  reg [71:0] ld_d = 0;
  reg [7:0] ld_paddr = 0;
  reg [35:0] ld_pdata = 0;
  reg boot0 = 0, boot1 = 0;

  wire ov0, ov1, idle0, idle1, flt0, flt1, halted;
  wire [35:0] od0, od1;
  wire [7:0] fr0, fr1;
  wire [4:0] fs0, fs1;
  wire [11:0] sp0, sp1, dt0, dt1;
  wire [5:0] occ0, occ1;

  duo d(.clk(clk), .rst(rst),
    .ld_code_en(ld_en), .ld_code_addr(ld_addr), .ld_code_data(ld_d),
    .ld_pool_en(ld_pen), .ld_pool_addr(ld_paddr), .ld_pool_data(ld_pdata),
    .boot0(boot0), .boot_pc0(9'd0), .boot1(boot1), .boot_pc1(9'd0),
    .ov0(ov0), .od0(od0), .ov1(ov1), .od1(od1),
    .idle0(idle0), .idle1(idle1),
    .flt0(flt0), .flt1(flt1), .fr0(fr0), .fr1(fr1), .fs0(fs0), .fs1(fs1),
    .sp0(sp0), .sp1(sp1), .dt0(dt0), .dt1(dt1),
    .occ0(occ0), .occ1(occ1), .halted(halted));

  reg [71:0] img [0:511];
  reg [35:0] pool [0:255];
  reg [35:0] exp0 [0:15];
  reg [35:0] got0 [0:15];
  integer n0 = 0, n1 = 0, ne0 = 0;
  integer errors = 0, i;

  always @(posedge clk) if (!rst && ov0) begin
    if (n0 < 16) got0[n0] = od0;
    n0 = n0 + 1;
  end
  always @(posedge clk) if (!rst && ov1) n1 = n1 + 1;

`ifdef TRACE
  always @(posedge clk) if (!rst) begin
    if (d.eng0_sp_remote_x) $display("T=%0t E0 REMOTE-SPAWN seat=%0d tgt=%0d arity=%0d bx=%04h",
      $time, d.eng0_x_seat, d.eng0_sp_tgt, d.eng0_sp_arity_x, d.eng0_bx_cur);
    if (d.eng0_rt_start) $display("T=%0t E0 RT-START pc=%0d arity=%0d deng=%0d",
      $time, d.eng0_f_tgt, d.eng0_f_arity, d.eng0_f_tgt_eng);
    if (d.a_en) $display("T=%0t A-PUSH kind=%0d head=%0b word=%09h len=%0d",
      $time, d.a_kind, d.a_head, d.a_word, d.a_len);
    if (d.b_en) $display("T=%0t B-PUSH kind=%0d head=%0b word=%09h len=%0d",
      $time, d.b_kind, d.b_head, d.b_word, d.b_len);
    if (d.eng1_rg_take) $display("T=%0t E1 TAKE idx=%0d word=%09h", $time, d.eng1_rx_idx, d.a_rword);
    if (d.eng1_su_rsp_ok) $display("T=%0t E1 RSP-OK slot=%0d ser=%0d pc=%0d",
      $time, d.eng1_su_rsp_slot, d.eng1_su_rsp_serial, d.eng1_su_rsp_pc);
    if (d.eng1_su_rsp_done) $display("T=%0t E1 RSP-DONE", $time);
    if (d.eng0_ro_pw) $display("T=%0t E0 PID-WB seat=%0d rd=%0d pid=%09h",
      $time, d.eng0_ro_seat, d.eng0_ro_sr, d.eng0_ro_pid);
    if (d.eng1_mb_rg) $display("T=%0t E1 MB-ENQ word=%09h slot=%0d", $time, d.a_rword, d.eng1_rg_slot);
    if (d.a_valid && d.a_rhead) $display("T=%0t E1 HEAD kind=%0d word=%09h ok=%0b live=%0b slot=%0d pt_st=%0d pt_ser=%0d",
      $time, d.a_rkind, d.a_rword, d.eng1_rg_ok, d.eng1_rg_live, d.eng1_rg_slot,
      d.eng1_pt_rd5_state, d.eng1_pt_rd5_serial);
    if (d.eng1_x_en) $display("T=%0t E1 X pc=%0d seat=%0d st=%0d/%0d/%0d/%0d", $time,
      d.eng1_dbg_pc, d.eng1_x_seat, d.eng1_dbg_st0, d.eng1_dbg_st1, d.eng1_dbg_st2, d.eng1_dbg_st3);
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
    for (i = 0; i < 512; i = i + 1) img[i] = 0;
    for (i = 0; i < 256; i = i + 1) pool[i] = 0;
    for (i = 0; i < 16; i = i + 1) exp0[i] = 36'hFFFFFFFFF;
    $readmemh("spawn2.hex", img);
    $readmemh("spawn2_pool.hex", pool);
    $readmemh("spawn2_expect.hex", exp0);

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // one image, both engines
    for (i = 0; i < 64; i = i + 1) begin
      @(negedge clk);
      ld_en = 1; ld_addr = i[8:0]; ld_d = img[i];
      @(posedge clk); #1;
    end
    ld_en = 0;
    @(posedge clk); #1;

    for (i = 0; i < 256; i = i + 1) begin
      @(negedge clk);
      ld_pen = 1; ld_paddr = i[7:0]; ld_pdata = pool[i];
      @(posedge clk); #1;
    end
    ld_pen = 0;
    @(posedge clk); #1;

    // engine 0 only. Engine 1 has no process until one is spawned onto it.
    @(negedge clk); boot0 = 1;
    @(posedge clk); #1; boot0 = 0;

    for (i = 0; i < 60000; i = i + 1) begin
      @(posedge clk);
      if (halted) i = 60000;
    end
    #1;

    for (i = 0; i < 16; i = i + 1)
      if (exp0[i] !== 36'hFFFFFFFFF) ne0 = ne0 + 1;

    check(halted, "the machine halted");
    check(n0 == ne0, "engine 0 reported once per expected out");

    for (i = 0; i < ne0; i = i + 1)
      if (got0[i] !== exp0[i]) begin
        $display("FAIL e0 out %0d: got %09h, want %09h", i, got0[i], exp0[i]);
        errors = errors + 1;
      end

    // the point of the whole exercise: a process exists on the engine
    // that was never booted, and it got there by being asked for
    check(occ1 > 0, "engine 1 HOSTS a process it was never booted with");
    // `dbg_spawns` counts spawn COMMITS, and a remote spawn commits
    // here too — the child is elsewhere, the decision was made here.
    check(sp0 == 2, "engine 0 committed both spawns");
    check(sp1 == 0, "engine 1 spawned nothing of its own");

    check(!flt0, "engine 0 did not fault");
    check(!flt1, "engine 1 did not fault");
    if (flt0) $display("  e0 fault reason=%0d slot=%0d", fr0, fs0);
    if (flt1) $display("  e1 fault reason=%0d slot=%0d", fr1, fs1);

    $display("  e0 outs=%0d/%0d  e1 outs=%0d  occ0=%0d occ1=%0d spawns=%0d/%0d",
             n0, ne0, n1, occ0, occ1, sp0, sp1);

`ifdef RERUN
    // ---- entry 36's gate: the same image must run identically after a
    // soft reset, because an image push IS a soft reset. The code store
    // survives (it is load-path state); everything semantic must not.
    $display("  --- rerun after soft reset ---");
    // 40 cycles: the reset SWEEPERS (ProcTable, Mailbox) walk their 32
    // slots during rst — a real image push holds reset for thousands
    @(negedge clk); rst = 1;
    repeat (40) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    if (d.eng0_sp_rr !== 0) begin
      $display("FAIL: sp_rr survived reset (%0d)", d.eng0_sp_rr);
      errors = errors + 1;
    end

    // the counter RESETS TO 1, not 0: the model's `Machine.new`
    // starts at 1 and the first ref after an image push must agree
    if (d.eng0_next_ref !== 1) begin
      $display("FAIL: next_ref survived reset");
      errors = errors + 1;
    end

    if (d.eng0_rt_st !== 0 || d.eng0_ro_busy !== 0 || d.eng0_rx_pend !== 0) begin
      $display("FAIL: spawn-transport state survived reset");
      errors = errors + 1;
    end

    n0 = 0; n1 = 0;
    @(negedge clk); boot0 = 1;
    @(posedge clk); #1; boot0 = 0;

    for (i = 0; i < 60000; i = i + 1) begin
      @(posedge clk);
      if (halted) i = 60000;
    end
    #1;

    check(halted, "rerun: the machine halted again");
    check(n0 == ne0, "rerun: engine 0 reported once per expected out");

    for (i = 0; i < ne0; i = i + 1)
      if (got0[i] !== exp0[i]) begin
        $display("FAIL rerun e0 out %0d: got %09h, want %09h", i, got0[i], exp0[i]);
        errors = errors + 1;
      end
`endif

    if (errors == 0) $display("__SPAWN2_OK__");
    else $display("__SPAWN2_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #1200000;
    $display("__SPAWN2_TIMEOUT__ n0=%0d occ1=%0d", n0, occ1);
    $finish;
  end
endmodule
