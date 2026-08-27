// The V1 demo as a gate: a supervisor on engine 0 keeps a REGISTERED
// server alive across a cross-engine kill (notes/54).
//
//   scripts/run_tbs.sh tb_super2
//
// Everything Phase 3 and Phase 4 built, in one program: registration
// of a remote pid, send-by-name across the ring, a cross-engine link,
// exit(Pid, kill) crossing and coming back as {'EXIT', _, killed},
// the name freed by death and re-registered, and the restarted server
// answering with fresh state from the OTHER engine.
//
// Prints __SUPER2_OK__ on full success.

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
    $readmemh("super2.hex", img);
    $readmemh("super2_pool.hex", pool);
    $readmemh("super2_expect.hex", exp0);

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // one image, both engines
    for (i = 0; i < 512; i = i + 1) begin
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

    // engine 0 only — everything engine 1 does arrives over the ring
    @(negedge clk); boot0 = 1;
    @(posedge clk); #1; boot0 = 0;

    for (i = 0; i < 80000; i = i + 1) begin
      @(posedge clk);
      if (halted) i = 80000;
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

    // the pid words already prove the geography (their ENGINE fields
    // are in the expect file), but say it directly too:
    // engine 1 hosted the first server and recorded its kill
    check(dt1 > 0, "engine 1 buried the first server");
    check(!flt0, "engine 0 did not fault");
    check(flt1, "engine 1 recorded the kill");
    if (flt0) $display("  e0 fault reason=%0d slot=%0d", fr0, fs0);
    if (flt1) $display("  e1 fault reason=%0d slot=%0d", fr1, fs1);

    $display("  e0 outs=%0d/%0d  e1 outs=%0d  occ0=%0d occ1=%0d",
             n0, ne0, n1, occ0, occ1);

    if (errors == 0) $display("__SUPER2_OK__");
    else $display("__SUPER2_FAIL__ (%0d errors)", errors);
    $finish;
  end
endmodule
