// M4 shape-hash tripwire, hardware half: the RTL block must reproduce
// PicoBEAM.Encoding.shape_hash_of_word/3 on every vector the Elixir
// side emitted. Disagreement here means `recv_hash` filters on a value
// the mailbox never stamps, and selective receive silently never
// matches — a failure with no symptom other than a hung process.
//
//   cd _emit/m4 && iverilog -o tbs.vvp ../../scripts/tb_m4_shape.v \
//     shape_hash.v && vvp tbs.vvp

`timescale 1ns/1ps

module tb;
  reg clk = 0;
  always #5 clk = ~clk;

  reg [35:0] word = 0, tup_first = 0;
  reg [7:0] tup_arity = 0;
  wire [7:0] hash;

  shape_hash sh(.clk(clk), .word(word), .tup_arity(tup_arity),
                .tup_first(tup_first), .hash(hash));

  integer f, r, errors = 0, n = 0;
  reg [35:0] v_word, v_first;
  reg [7:0] v_arity, v_hash;

  initial begin
    f = $fopen("shape_vectors.hex", "r");
    if (f == 0) begin $display("__M4_SHAPE_NOFILE__"); $finish; end

    while (!$feof(f)) begin
      r = $fscanf(f, "%h %h %h %h\n", v_word, v_arity, v_first, v_hash);
      if (r == 4) begin
        word = v_word; tup_arity = v_arity; tup_first = v_first;
        #1;
        n = n + 1;
        if (hash !== v_hash) begin
          $display("FAIL word=%h arity=%0d first=%h rtl=%02h elixir=%02h",
                   v_word, v_arity, v_first, hash, v_hash);
          errors = errors + 1;
        end
      end
    end
    $fclose(f);

    if (n == 0) begin $display("__M4_SHAPE_NOVECTORS__"); $finish; end
    $display("vectors=%0d", n);
    if (errors == 0) $display("__M4_SHAPE_OK__");
    else $display("__M4_SHAPE_FAILED__ (%0d)", errors);
    $finish;
  end
endmodule
