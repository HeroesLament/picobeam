// M3 pass 2 testbench — ProcTable + RunQueue under iverilog.
//
//   cd _emit/m3 && iverilog -o tb.vvp ../../scripts/tb_m3_pass2.v \
//     proc_table.v run_queue.v && vvp tb.vvp
//
// Self-checking; prints __M3_PASS2_OK__ on full success.

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- ProcTable ----
  reg  [2:0] cmd = 0;
  reg  [4:0] cmd_slot = 0;
  reg  [8:0] cmd_pc = 0;
  reg  [4:0] rd_slot = 0;
  wire alloc_ok;
  wire [4:0] alloc_slot;
  wire [21:0] alloc_serial;
  wire [8:0] rd_pc;
  wire [21:0] rd_serial;
  wire [1:0] rd_state;
  wire [5:0] occ;

  proc_table pt(.clk(clk), .rst(rst), .cmd(cmd), .cmd_slot(cmd_slot),
    .cmd_pc(cmd_pc), .alloc_ok(alloc_ok), .alloc_slot(alloc_slot),
    .alloc_serial(alloc_serial), .rd_slot(rd_slot), .rd_pc(rd_pc),
    .rd_serial(rd_serial), .rd_state(rd_state), .occ(occ));

  // ---- RunQueue ----
  reg push = 0, pop = 0;
  reg [4:0] push_data = 0;
  wire [4:0] q_head;
  wire q_empty, q_full;
  wire [5:0] q_count;

  run_queue rq(.clk(clk), .rst(rst), .push(push), .push_data(push_data),
    .pop(pop), .q_head(q_head), .empty(q_empty), .full(q_full),
    .count(q_count));

  integer errors = 0;
  integer i;
  reg [4:0] got_slot;
  reg [21:0] got_serial;

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s", name);
      errors = errors + 1;
    end
  endtask

  // present a command for exactly one edge
  task do_cmd(input [2:0] c, input [4:0] s, input [8:0] p);
    begin
      cmd = c; cmd_slot = s; cmd_pc = p;
      @(posedge clk); #1;
      cmd = 0;
    end
  endtask

  initial begin
    // zero-init the un-initialized columns (LUT-RAM powers up 0 on ECP5)
    for (i = 0; i < 32; i = i + 1) begin
      tb.pt.serials[i] = 0; tb.pt.states[i] = 0;
      tb.pt.pcs[i] = 0;     tb.pt.reasons[i] = 0;
      tb.rq.q[i] = 0;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    check(occ == 0, "occ starts 0");

    // alloc #1: slot 0, serial 1 (first life = 1, matching the model)
    cmd = 1; cmd_pc = 9'd99; #1;
    check(alloc_ok == 1, "alloc1 ok");
    check(alloc_slot == 0, "alloc1 slot 0");
    check(alloc_serial == 1, "alloc1 serial 1");
    @(posedge clk); #1; cmd = 0;

    // alloc #2: slot 1
    cmd = 1; cmd_pc = 9'd77; #1;
    check(alloc_slot == 1, "alloc2 slot 1");
    check(alloc_serial == 1, "alloc2 serial 1");
    @(posedge clk); #1; cmd = 0;
    check(occ == 2, "occ 2");

    // entry pc + state landed
    rd_slot = 0; #1;
    check(rd_pc == 99, "slot0 entry pc");
    check(rd_state == 1, "slot0 queued");

    // bind → resident; save → new pc
    do_cmd(4, 0, 0);
    rd_slot = 0; #1; check(rd_state == 2, "slot0 resident");
    do_cmd(3, 0, 9'h155);
    rd_slot = 0; #1; check(rd_pc == 9'h155, "slot0 saved pc");

    // free slot 0 with reason 5
    do_cmd(2, 0, 9'd5);
    rd_slot = 0; #1;
    check(rd_state == 0, "slot0 free");
    check(rd_serial == 1, "serial survives death");
    check(occ == 1, "occ 1 after free");

    // fill the table: 30 allocs take slots 2..31, the 31st recycles
    // slot 0 at serial 2 (FIFO free list + ABA bump)
    for (i = 0; i < 30; i = i + 1) do_cmd(1, 0, 9'd11);
    cmd = 1; cmd_pc = 9'd11; #1;
    check(alloc_ok == 1, "recycle alloc ok");
    got_slot = alloc_slot; got_serial = alloc_serial;
    check(got_slot == 0, "recycled slot 0");
    check(got_serial == 2, "recycled serial 2");
    @(posedge clk); #1; cmd = 0;
    check(occ == 32, "table full occupancy");

    // full → alloc refused (the spawner's :system_limit)
    cmd = 1; #1;
    check(alloc_ok == 0, "alloc refused when full");
    @(posedge clk); #1; cmd = 0;

    // ---- RunQueue ----
    check(q_empty == 1, "queue starts empty");
    push = 1; push_data = 5; @(posedge clk); #1;
    push_data = 7; @(posedge clk); #1;
    push_data = 9; @(posedge clk); #1;
    push = 0;
    check(q_count == 3, "queue count 3");
    check(q_head == 5, "head 5 (FIFO)");

    pop = 1; @(posedge clk); #1; pop = 0;
    check(q_head == 7, "head 7 after pop");

    // simultaneous push+pop: count unchanged, order preserved
    push = 1; push_data = 11; pop = 1; @(posedge clk); #1;
    push = 0; pop = 0;
    check(q_count == 2, "push+pop count steady");
    check(q_head == 9, "head 9");

    pop = 1; @(posedge clk); #1; @(posedge clk); #1; pop = 0;
    check(q_empty == 1, "drained empty");

    if (errors == 0) $display("__M3_PASS2_OK__");
    else $display("__M3_PASS2_FAILED__ (%0d)", errors);
    $finish;
  end
endmodule
