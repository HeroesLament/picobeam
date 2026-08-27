// M4 send testbench: SendUnit + ProcTable + Mailbox + ShapeHash wired
// as the engine will wire them, exercising every outcome a send can
// have.
//
//   cd _emit/m4 && iverilog -o tbsend.vvp ../../scripts/tb_m4_send.v \
//     send_unit.v proc_table.v mailbox.v shape_hash.v && vvp tbsend.vvp

`timescale 1ns/1ps

module tb;
  reg clk = 0, rst = 1;
  always #5 clk = ~clk;

  // ---- ProcTable ----
  reg [2:0] pt_cmd = 0;
  reg [4:0] pt_cmd_slot = 0;
  reg [8:0] pt_cmd_pc = 0;
  reg [4:0] pt_rd_slot = 0;
  wire alloc_ok; wire [4:0] alloc_slot; wire [21:0] alloc_serial;
  wire [8:0] pt_rd_pc; wire [21:0] pt_rd_serial, pt_rd2_serial;
  wire [1:0] pt_rd_state, pt_rd2_state;
  wire [5:0] occ; wire [31:0] doom_vec;
  wire [4:0] su_pt_slot;

  proc_table pt(.clk(clk), .rst(rst), .cmd(pt_cmd), .cmd_slot(pt_cmd_slot),
    .cmd_pc(pt_cmd_pc), .alloc_ok(alloc_ok), .alloc_slot(alloc_slot),
    .alloc_serial(alloc_serial), .rd_slot(pt_rd_slot), .rd_pc(pt_rd_pc),
    .rd_serial(pt_rd_serial), .rd_state(pt_rd_state), .occ(occ),
    .rd2_slot(su_pt_slot), .rd2_serial(pt_rd2_serial),
    .rd2_state(pt_rd2_state), .doom_vec(doom_vec));

  // ---- ShapeHash + SendUnit ----
  reg send_en = 0;
  reg [35:0] pid_word = 0, msg_word = 0;
  wire [7:0] msg_hash;
  wire [2:0] mb_cmd_s; wire [4:0] mb_slot_s; wire [35:0] mb_word_s;
  wire [7:0] mb_hash_s;
  wire delivered, dead_letter, overflow, bad_pid;
  wire remote;
  wire [5:0] remote_slot;
  wire [4:0] overflow_slot;

  shape_hash sh(.clk(clk), .word(msg_word), .tup_arity(8'd0),
                .tup_first(36'd0), .hash(msg_hash));

  send_unit su(.clk(clk), .eng_id(4'd0), .remote(remote), .remote_slot(remote_slot),
    .send_en(send_en), .pid_word(pid_word),
    .msg_word(msg_word), .msg_hash(msg_hash),
    .pt_slot(su_pt_slot), .pt_serial(pt_rd2_serial), .pt_state(pt_rd2_state),
    .mb_cmd(mb_cmd_s), .mb_slot(mb_slot_s), .mb_word(mb_word_s),
    .mb_hash(mb_hash_s), .mb_full(mb_full),
    .delivered(delivered), .dead_letter(dead_letter), .overflow(overflow),
    .overflow_slot(overflow_slot), .bad_pid(bad_pid));

  // ---- Mailbox (the receive side is driven directly here) ----
  reg [2:0] rx_cmd = 0;
  reg [4:0] rx_slot = 0;
  reg [7:0] rx_filter = 0;
  reg rx_filtered = 0;
  // the probe port: the engine muxes this between a send's target and
  // the running process's own slot; the TB does the same by hand
  reg [4:0] probe_slot = 0;
  // the engine's rule: enqueue wins the command port
  wire [2:0] mb_cmd   = (mb_cmd_s != 0) ? mb_cmd_s : rx_cmd;
  wire [4:0] mb_slot  = (mb_cmd_s != 0) ? mb_slot_s : rx_slot;
  wire mb_full, mb_busy, mb_done, mb_hit, mb_unseen;
  wire [35:0] mb_hit_word;
  wire [5:0] mb_scan_len;
  wire [6:0] mb_count;

  mailbox mb(.clk(clk), .rst(rst), .cmd(mb_cmd), .cmd_slot(mb_slot),
    .q_slot(probe_slot),
    .cmd_word(mb_word_s), .cmd_hash(mb_hash_s), .cmd_filter(rx_filter),
    .cmd_filtered(rx_filtered), .full(mb_full), .busy(mb_busy),
    .done(mb_done), .hit(mb_hit), .hit_word(mb_hit_word),
    .scan_len(mb_scan_len), .count(mb_count), .unseen(mb_unseen));

  integer errors = 0, i;
  reg [35:0] pid_a, pid_b, pid_stale;
  reg [4:0] slot_a, slot_b;
  reg [21:0] ser_a, ser_b;

  task check(input cond, input [255:0] name);
    if (!cond) begin
      $display("FAIL: %0s (t=%0t)", name, $time);
      errors = errors + 1;
    end
  endtask

  task ptop(input [2:0] c, input [4:0] s, input [8:0] p);
    begin
      @(negedge clk); pt_cmd = c; pt_cmd_slot = s; pt_cmd_pc = p;
      @(posedge clk); #1; pt_cmd = 0;
    end
  endtask

  task do_send(input [35:0] pid, input [35:0] msg);
    begin
      @(negedge clk); send_en = 1; pid_word = pid; msg_word = msg;
      probe_slot = pid[26:22];
      #1;
    end
  endtask

  task end_send;
    begin @(posedge clk); #1; send_en = 0; end
  endtask

  function [35:0] mkpid(input [3:0] eng, input [5:0] slot, input [21:0] ser);
    mkpid = {4'h5, eng, slot, ser};
  endfunction

  initial begin
    for (i = 0; i < 2048; i = i + 1) begin mb.words[i] = 0; mb.hv[i] = 0; end
    for (i = 0; i < 32; i = i + 1) begin
      mb.heads[i]=0; mb.tails[i]=0; mb.cnts[i]=0; mb.curs[i]=0;
      mb.heads2[i]=0; mb.tails2[i]=0; mb.curs2[i]=0; mb.cnts2[i]=0;
      pt.serials[i]=0; pt.serials2[i]=0; pt.states[i]=0; pt.states2[i]=0;
      pt.pcs[i]=0; pt.reasons[i]=0; pt.flist[i]=i;
    end

    repeat (3) @(posedge clk); #1;
    rst = 0; @(posedge clk); #1;

    // two live processes
    @(negedge clk); pt_cmd = 1; pt_cmd_pc = 9'd100; #1;
    slot_a = alloc_slot; ser_a = alloc_serial;
    @(posedge clk); #1; pt_cmd = 0;
    @(negedge clk); pt_cmd = 1; pt_cmd_pc = 9'd200; #1;
    slot_b = alloc_slot; ser_b = alloc_serial;
    @(posedge clk); #1; pt_cmd = 0;

    pid_a = mkpid(4'd0, {1'b0, slot_a}, ser_a);
    pid_b = mkpid(4'd0, {1'b0, slot_b}, ser_b);
    check(slot_a != slot_b, "two distinct slots");

    // ---- 1. an ordinary delivery ----
    do_send(pid_a, 36'h1_0000002A);            // an atom-tagged word
    check(delivered == 1, "a live pid is delivered to");
    check(dead_letter == 0 && overflow == 0 && bad_pid == 0, "no other outcome");
    check(mb_slot_s == slot_a, "routed by the pid's slot field");
    check(mb_hash_s == msg_hash, "stamped with the shape hash");
    end_send;
    rx_slot = slot_a; probe_slot = slot_a; #1;
    check(mb_count == 1, "the message landed in the target's mailbox");
    rx_slot = slot_b; probe_slot = slot_b; #1;
    check(mb_count == 0, "and not in anyone else's");

    // ---- 2. a stale pid: right slot, wrong incarnation ----
    pid_stale = mkpid(4'd0, {1'b0, slot_a}, ser_a + 1);
    do_send(pid_stale, 36'h1_0000002B);
    check(dead_letter == 1, "a stale serial dead-letters");
    check(delivered == 0, "and delivers nothing");
    end_send;
    rx_slot = slot_a; probe_slot = slot_a; #1;
    check(mb_count == 1, "the stale send left the mailbox untouched");

    // ---- 3. a pid naming a freed slot ----
    ptop(3'd2, slot_b, 9'd0);                  // free slot_b
    do_send(pid_b, 36'h1_0000002C);
    check(dead_letter == 1, "a pid for a dead process dead-letters");
    end_send;

    // ---- 4. the ABA case: the slot is recycled, the old pid must miss
    // The free list is a FIFO precisely so a slot is reused as LATE as
    // possible — maximum real time between a pid dying and its slot
    // answering again. So drain the list to force the recycle.
    for (i = 0; i < 30; i = i + 1) ptop(3'd1, 5'd0, 9'd400);
    @(negedge clk); pt_cmd = 1; pt_cmd_pc = 9'd300; #1;
    check(alloc_slot == slot_b, "the freed slot comes back last, as FIFO promises");
    check(alloc_serial == ser_b + 1, "with a bumped incarnation");
    @(posedge clk); #1; pt_cmd = 0;
    do_send(pid_b, 36'h1_0000002D);            // the OLD pid
    check(dead_letter == 1, "the old pid does not reach the new occupant");
    end_send;
    rx_slot = slot_b; probe_slot = slot_b; #1;
    check(mb_count == 0, "the recycled process received nothing");

    // ...while the CURRENT pid does
    do_send(mkpid(4'd0, {1'b0, slot_b}, ser_b + 1), 36'h1_0000002E);
    check(delivered == 1, "the current pid reaches the new occupant");
    end_send;
    rx_slot = slot_b; probe_slot = slot_b; #1;
    check(mb_count == 1, "and its message landed");

    // ---- 5. not a pid at all ----
    do_send(36'h0_0000002A, 36'h1_0000002F);   // a fixnum
    check(bad_pid == 1, "a non-pid is :badarg on the SENDER");
    check(delivered == 0 && dead_letter == 0, "and is not a delivery failure");
    end_send;

    // ---- 6. a remote engine is a packet for the ring ----
    //
    // This used to assert `dead_letter`, with a comment saying a remote
    // pid had nowhere to go until the ring existed. It exists. A pid
    // naming another engine is now `remote`: not delivered here, not a
    // failure, handed to the ring and checked at the far end, because
    // this engine's table knows nothing about another's slots.
    do_send(mkpid(4'd3, {1'b0, slot_a}, ser_a), 36'h1_00000030);
    check(remote == 1, "a pid on another engine routes to the ring");
    check(remote_slot == {1'b0, slot_a}, "carrying the target's slot");
    check(dead_letter == 0, "and is NOT a dead letter — nothing has failed yet");
    check(delivered == 0, "nor a local delivery");
    end_send;

    // ---- 7. overflow kills the RECEIVER ----
    for (i = 0; i < 62; i = i + 1) begin
      do_send(pid_a, 36'h1_00000000 + i); end_send;
    end
    rx_slot = slot_a; probe_slot = slot_a; #1;
    check(mb_count == 63, "mailbox filled to the ring limit");
    do_send(pid_a, 36'h1_000000FF);
    check(overflow == 1, "overflow raised on the 64th");
    check(delivered == 0, "nothing was enqueued");
    check(overflow_slot == slot_a, "the RECEIVER is named, not the sender");
    end_send;
    // the engine's response: doom the target with :mailbox_full (atom 7)
    ptop(3'd6, slot_a, 9'd7);
    check(doom_vec[slot_a] == 1, "the target is doomed");
    check(doom_vec[slot_b] == 0, "and nobody else is");
    // a recycled slot must not inherit a death
    ptop(3'd2, slot_a, 9'd7);
    check(doom_vec[slot_a] == 0, "freeing clears the doom bit");

    if (errors == 0) $display("__M4_SEND_OK__");
    else $display("__M4_SEND_FAILED__ (%0d)", errors);
    $finish;
  end

  initial begin
    #400000;
    $display("__M4_SEND_TIMEOUT__");
    $finish;
  end
endmodule
