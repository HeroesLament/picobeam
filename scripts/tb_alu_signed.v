// Does the M2 ALU implement PicoBEAM.Term's fixnum contract?
//
//   term.ex: "Fixnums are signed 32-bit two's complement in the payload.
//    Arithmetic that leaves that range TRAPS (exit reason :overflow) —
//    it never wraps (notes/09, consequence 4)."
//
//   cd _emit/alu && iverilog -o tba.vvp ../../scripts/tb_alu_signed.v \
//     alu.v && vvp tba.vvp
//
// Every case below is the model's answer (machine.ex :add/:sub/:cmplt/
// :cmple via Term.int_checked/1). This TB does not assume the RTL is
// wrong; it just asks.

`timescale 1ns/1ps

module tb;
  reg clk = 0;
  always #5 clk = ~clk;

  reg [4:0] sel = 0;
  reg [35:0] a = 0, b = 0;
  reg [3:0] tag_imm = 0;
  reg [11:0] imm = 0;
  wire [35:0] y;
  wire fault;
  wire [7:0] fault_reason;

  alu u(.clk(clk), .sel(sel), .a(a), .b(b), .tag_imm(tag_imm), .imm(imm),
        .y(y), .fault(fault), .fault_reason(fault_reason));

  integer errors = 0;
  integer checks = 0;

  // INT word from a signed 32-bit value
  function [35:0] iw(input signed [31:0] v);
    iw = {4'h0, v};
  endfunction

  task expect_y(input [4:0] s, input [35:0] xa, input [35:0] xb,
                input [35:0] want, input [255:0] name);
    begin
      sel = s; a = xa; b = xb; #1;
      checks = checks + 1;
      if (y !== want || fault !== 1'b0) begin
        $display("FAIL %0s: y=%09h fault=%0b  (want y=%09h fault=0)",
                 name, y, fault, want);
        errors = errors + 1;
      end
    end
  endtask

  task expect_fault(input [4:0] s, input [35:0] xa, input [35:0] xb,
                    input [7:0] why, input [255:0] name);
    begin
      sel = s; a = xa; b = xb; #1;
      checks = checks + 1;
      if (fault !== 1'b1 || fault_reason !== why) begin
        $display("FAIL %0s: fault=%0b reason=%0d  (want fault=1 reason=%0d) y=%09h",
                 name, fault, fault_reason, why, y);
        errors = errors + 1;
      end
    end
  endtask

  localparam [35:0] TRUE_W  = 36'h100000000 + 14;
  localparam [35:0] FALSE_W = 36'h100000000 + 15;

  integer k;
  reg signed [31:0] ra, rb;
  reg signed [63:0] want64;
  reg [35:0] wantw;

  task random_sweep(input integer n);
    begin
      for (k = 0; k < n; k = k + 1) begin
        // mix full-range values with values clustered near the edges,
        // where the overflow rule earns its keep
        ra = (k[1:0] == 0) ? {$random} :
             (k[1:0] == 1) ? 32'h7FFFFFFF - {$random} % 4 :
             (k[1:0] == 2) ? 32'h80000000 + {$random} % 4 : {$random} % 100000;
        rb = (k[2:1] == 0) ? {$random} :
             (k[2:1] == 1) ? 32'h7FFFFFFF - {$random} % 4 :
             (k[2:1] == 2) ? 32'h80000000 + {$random} % 4 : {$random} % 100000;

        // add
        want64 = ra + rb; sel = 5'd0; a = iw(ra); b = iw(rb); #1;
        chk_arith(want64, "add");
        // sub
        want64 = ra - rb; sel = 5'd1; #1;
        chk_arith(want64, "sub");
        // mul
        want64 = ra * rb; sel = 5'd2; #1;
        chk_arith(want64, "mul");
        // cmplt / cmple
        sel = 5'd8; #1;
        wantw = (ra < rb) ? TRUE_W : FALSE_W;
        chk_word(wantw, "cmplt");
        sel = 5'd9; #1;
        wantw = (ra <= rb) ? TRUE_W : FALSE_W;
        chk_word(wantw, "cmple");
        // mulsr at a shift that varies with k
        imm = {8'd0, k[3:0]};
        want64 = (ra * rb) >>> (k[3:0] + 1);
        sel = 5'd16; #1;
        chk_arith(want64, "mulsr");
        imm = 12'd0;
      end
    end
  endtask

  task chk_arith(input signed [63:0] want, input [255:0] name);
    begin
      checks = checks + 1;
      if (want > 64'sd2147483647 || want < -64'sd2147483648) begin
        if (fault !== 1'b1 || fault_reason !== 8'd5) begin
          $display("FAIL %0s(%0d,%0d): want overflow trap, got y=%09h fault=%0b r=%0d",
                   name, ra, rb, y, fault, fault_reason);
          errors = errors + 1;
        end
      end else begin
        if (fault !== 1'b0 || y !== {4'h0, want[31:0]}) begin
          $display("FAIL %0s(%0d,%0d): want %09h, got y=%09h fault=%0b",
                   name, ra, rb, {4'h0, want[31:0]}, y, fault);
          errors = errors + 1;
        end
      end
    end
  endtask

  task chk_word(input [35:0] want, input [255:0] name);
    begin
      checks = checks + 1;
      if (fault !== 1'b0 || y !== want) begin
        $display("FAIL %0s(%0d,%0d): want %09h, got y=%09h fault=%0b",
                 name, ra, rb, want, y, fault);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    #20;

    // ---- add / sub, positive: the M2 path fib already exercises ----
    expect_y(5'd0, iw(5), iw(7), iw(12),  "add 5+7");
    expect_y(5'd1, iw(7), iw(5), iw(2),   "sub 7-5");

    // ---- add / sub crossing zero ----
    expect_y(5'd1, iw(5), iw(7), iw(-2),  "sub 5-7 = -2");
    expect_y(5'd0, iw(-2), iw(3), iw(1),  "add -2+3 = 1");
    expect_y(5'd0, iw(-2), iw(-3), iw(-5),"add -2+-3 = -5");
    expect_y(5'd1, iw(-2), iw(3), iw(-5), "sub -2-3 = -5");

    // ---- the motion case: a Q12 basis function times a delta ----
    expect_y(5'd2, iw(6), iw(7), iw(42),        "mul 6*7");
    expect_y(5'd2, iw(-40000), iw(2048), iw(-81920000), "mul -40000*2048");

    // ---- signed compare (cmplt = sel 8, cmple = sel 9) ----
    expect_y(5'd8, iw(-2), iw(3),  TRUE_W,  "cmplt -2 < 3");
    expect_y(5'd8, iw(3), iw(-2),  FALSE_W, "cmplt 3 < -2");
    expect_y(5'd9, iw(-2), iw(-2), TRUE_W,  "cmple -2 <= -2");
    expect_y(5'd9, iw(3), iw(-2),  FALSE_W, "cmple 3 <= -2");

    // ---- overflow must TRAP, not wrap (reason index 5) ----
    expect_fault(5'd0, iw(32'h7FFFFFFF), iw(1), 8'd5,  "add INT_MAX+1 traps");
    expect_fault(5'd1, iw(32'h80000000), iw(1), 8'd5,  "sub INT_MIN-1 traps");
    expect_fault(5'd2, iw(65536), iw(65536), 8'd5,     "mul 2^16*2^16 traps");

    // ---- badarith still works (reason index 3) ----
    expect_fault(4'd0, 36'h100000000, iw(1), 8'd3, "add atom+int badarith");

    // ---- mulsr: multiply then arithmetic-shift-right, one op.
    // k is encoded in f4 = imm[3:0] biased by one, so imm=11 is >> 12.
    imm = 12'd11;
    expect_y(5'd16, iw(-40000), iw(2048), iw(-20000), "mulsr -40000*2048>>12");
    expect_y(5'd16, iw(4096), iw(4096), iw(4096),     "mulsr Q12 1.0*1.0");
    expect_y(5'd16, iw(3000), iw(2048), iw(1500),     "mulsr 3000*0.5");
    // floor semantics, not truncate-toward-zero: -1*1 >> 12 is -1, not 0
    expect_y(5'd16, iw(-1), iw(1), iw(-1),            "mulsr floors negatives");
    imm = 12'd15;  // >> 16
    expect_y(5'd16, iw(32'h40000000), iw(65536), iw(32'h40000000),
             "mulsr Q16 max shift");
    // the product itself would overflow a fixnum; the SHIFTED result
    // does not, and that is the whole point of fusing the two.
    imm = 12'd11;
    expect_y(5'd16, iw(1000000), iw(1000000), iw(244140625),
             "mulsr survives an intermediate no fixnum could hold");
    // 2e6 * 2e6 >> 12 is 976,562,500 — a fixnum, even though the
    // intermediate is 4e12. That case must NOT trap.
    expect_y(5'd16, iw(2000000), iw(2000000), iw(976562500),
             "mulsr does not trap on a big intermediate that shifts down");
    // 4e6 * 4e6 >> 12 is 3.9e9 — past INT_MAX, so it must.
    expect_fault(5'd16, iw(4000000), iw(4000000), 8'd5,
                 "mulsr traps when the SHIFTED result overflows");
    imm = 12'd0;

    // ---- the rest of the sel table.
    // add/sub/mul/cmplt/cmple/mulsr are swept exhaustively below, which
    // left eight of the seventeen micro-ops with no coverage at all —
    // including `mov`, which every non-ALU slot decodes to, and `istag`,
    // which is the only thing that reads a tag as data.
    expect_y(5'd3, iw(32'h0F0F0F0F), iw(32'h00FF00FF), iw(32'h000F000F), "band");
    expect_y(5'd4, iw(32'h0F0F0F0F), iw(32'h00FF00FF), iw(32'h0FFF0FFF), "bor");
    expect_y(5'd5, iw(32'h0F0F0F0F), iw(32'h00FF00FF), iw(32'h0FF00FF0), "bxor");
    // the bitwise group is tag-checked too: the payload is meaningless
    // if the operands were not integers
    expect_fault(5'd3, 36'h100000000, iw(1), 8'd3, "band of an atom is badarith");

    // cmpeq/cmpne compare WHOLE WORDS and accept any term — that is the
    // model's semantics, and it is why they are not in the tag-checked
    // group with cmplt/cmple
    expect_y(5'd6, iw(7), iw(7), TRUE_W,  "cmpeq 7 == 7");
    expect_y(5'd6, iw(7), iw(8), FALSE_W, "cmpeq 7 == 8");
    expect_y(5'd6, 36'h100000005, 36'h100000005, TRUE_W, "cmpeq on two atoms");
    expect_y(5'd6, 36'h100000005, iw(5), FALSE_W,
             "cmpeq distinguishes atom 5 from integer 5 — the whole word");
    expect_y(5'd7, iw(7), iw(8), TRUE_W,  "cmpne 7 /= 8");
    expect_y(5'd7, 36'h500000001, 36'h500000001, FALSE_W, "cmpne on equal pids");

    // istag reads the tag as data; tag_imm is the immediate operand
    tag_imm = 4'h0;
    expect_y(5'd10, iw(42), 36'd0, TRUE_W,  "istag INT on an integer");
    expect_y(5'd10, 36'h100000003, 36'd0, FALSE_W, "istag INT on an atom");
    tag_imm = 4'h3;
    expect_y(5'd10, 36'h300000005, 36'd0, TRUE_W, "istag CONS on a cons");
    tag_imm = 4'h2;
    expect_y(5'd10, 36'h200000000, 36'd0, TRUE_W, "istag NIL on nil");
    tag_imm = 4'h0;

    // mov and pass carry the whole word through, tag included — every
    // slot that is not an ALU op decodes to one of these
    expect_y(5'd11, 36'h500000001, 36'd0, 36'h500000001, "mov passes a pid intact");
    expect_y(5'd15, 36'h900000004, 36'd0, 36'h900000004, "pass carries a header");

    // the three loads the ALU serves
    imm = 12'd1234;
    expect_y(5'd12, 36'd0, 36'd0, iw(1234), "ldi a positive immediate");
    imm = 12'hFFF;
    expect_y(5'd12, 36'd0, 36'd0, iw(-1), "ldi sign-extends");
    imm = 12'h800;
    expect_y(5'd12, 36'd0, 36'd0, iw(-2048), "ldi at the negative edge");
    imm = 12'd0;
    expect_y(5'd13, 36'd0, 36'd0, 36'h200000000, "ldn is the NIL word");
    imm = 12'd14;
    expect_y(5'd14, 36'd0, 36'd0, TRUE_W, "lda builds a tagged ATOM");
    imm = 12'd0;

    // ---- randomised sweep against Verilog's own signed arithmetic,
    // which is an independent oracle here: nothing in the netlist uses
    // a signed type, so agreeing with $signed is a real cross-check.
    random_sweep(20000);

    $display("---- %0d checks, %0d failures ----", checks, errors);
    if (errors == 0) $display("__ALU_SIGNED_OK__");
    else $display("__ALU_SIGNED_FAILED__ (%0d)", errors);
    $finish;
  end
endmodule
