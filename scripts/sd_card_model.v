// A microSD card in SPI mode, enough of one for `SdBoot` (notes/34).
//
// Backed by a byte image loaded with $readmemh from -DCARD_IMG; sector
// S maps to image byte (S - CARD_LBA) * 512, so the file is exactly the
// bytes `mk_image.exs` writes and nothing has to agree about padding.
//
// Answers CMD0, CMD8, CMD55, ACMD41, CMD17 and CMD24. ACMD41 reports
// "still initialising" twice before it reports ready, because a card
// that is ready on the first ask never exercises the CMD55/ACMD41 loop
// and that loop is where a real card spends its first 50 ms.
//
// CMD24 writes for real: the bytes land in `mem`, so a testbench can
// write a sector and then READ IT BACK through the same model and find
// out whether the loader and the writer agree about the format. It also
// goes BUSY afterwards — MISO low for a few byte times, the way a card
// does while its flash settles — because a writer that does not wait
// for that is a writer that works in simulation and corrupts cards.
//
// Mode 0: MOSI is sampled on the rising edge of SCK, MISO changes on
// the falling edge. `SdBoot` samples MISO at the clock edge where it
// raises SCK, which is the edge after the card presented it.

module sd_card #(
  parameter LBA = 8192,
  parameter NBYTES = 4096
) (
  input  wire clk,
  input  wire cs_n,
  input  wire sck,
  input  wire mosi,
  output wire miso
);

  reg [7:0] mem [0:NBYTES-1];

  // ---- bit plumbing
  reg sck_d = 0;
  wire rise = (sck == 1'b1) && (sck_d == 1'b0);
  wire fall = (sck == 1'b0) && (sck_d == 1'b1);

  reg [7:0] shin  = 8'h00;
  reg [7:0] shout = 8'hFF;
  reg [3:0] nbit  = 0;

  assign miso = cs_n ? 1'b1 : shout[7];

  // ---- response queue
  reg [7:0] rbuf [0:1023];
  integer rlen = 0, rptr = 0;

  // ---- CMD24: 0 idle, 1 awaiting token, 2 taking data, 3 crc, 4 busy
  reg [2:0]  wst  = 0;
  reg [31:0] wsec = 0;
  integer    wi   = 0;
  integer    wbusy = 0;

  // ---- command assembly
  reg        coll = 0;
  reg [2:0]  ci   = 0;
  reg [7:0]  cmd [0:5];
  integer    acmd41_asks = 0;
  integer    i;
  reg [31:0] arg;
  reg [31:0] off;

  task push(input [7:0] b);
    begin rbuf[rlen] = b; rlen = rlen + 1; end
  endtask

  task decode;
    begin
      arg = {cmd[1], cmd[2], cmd[3], cmd[4]};
      rlen = 0; rptr = 0;
      push(8'hFF);                                  // NCR
      case (cmd[0])
        8'h40: push(8'h01);                         // CMD0  -> idle
        8'h48: begin                                // CMD8  -> R7
                 push(8'h01);
                 push(8'h00); push(8'h00); push(8'h01); push(8'hAA);
               end
        8'h77: push(8'h01);                         // CMD55 -> idle
        8'h69: begin                                // ACMD41
                 if (acmd41_asks < 2) push(8'h01); else push(8'h00);
                 acmd41_asks = acmd41_asks + 1;
               end
        8'h58: begin                                // CMD24 -> write block
                 push(8'h00);
                 wsec = arg;
                 wst  = 1;
                 wi   = 0;
               end
        8'h51: begin                                // CMD17 -> single block
                 push(8'h00);
                 push(8'hFF); push(8'hFF);          // a little token latency
                 push(8'hFE);
                 off = (arg - LBA) * 512;
                 for (i = 0; i < 512; i = i + 1) push(mem[off + i]);
                 push(8'h00); push(8'h00);          // CRC16, discarded
               end
        default: push(8'h04);                       // illegal command
      endcase
    end
  endtask

  initial begin
    for (i = 0; i < NBYTES; i = i + 1) mem[i] = 8'h00;
`ifdef CARD_IMG
    $readmemh(`CARD_IMG, mem);
`endif
  end

  always @(posedge clk) begin
    sck_d <= sck;

    if (cs_n) begin
      nbit  <= 0;
      shout <= 8'hFF;
      coll  <= 0;
      wst   <= 0;
    end else begin
      if (rise) begin
        shin <= {shin[6:0], mosi};

        if (nbit == 7) begin
          nbit <= 0;
          // the byte just completed, MSB-first
          if (wst != 0) begin
            // a write is in progress: these bytes are the block, not a
            // command, and must not be parsed as one
            case (wst)
              1: if ({shin[6:0], mosi} == 8'hFE) begin wst <= 2; wi = 0; end
              2: begin
                   mem[(wsec - LBA) * 512 + wi] = {shin[6:0], mosi};
                   wi = wi + 1;
                   if (wi == 512) wst <= 3;
                 end
              3: begin
                   wi = wi + 1;
                   if (wi == 514) begin
                     // data accepted, then busy for a few byte times
                     rlen = 0; rptr = 0;
                     push(8'h05);
                     wbusy = 0;
                     wst <= 4;
                   end
                 end
              4: begin
                   wbusy = wbusy + 1;
                   if (wbusy > 6) wst <= 0;
                 end
            endcase
          end else if (coll) begin
            cmd[ci] = {shin[6:0], mosi};
            if (ci == 5) begin coll <= 0; ci <= 0; decode;
`ifdef CARD_TRACE
              $display("T=%0t CARD cmd %02h arg=%02h%02h%02h%02h", $time,
                       cmd[0], cmd[1], cmd[2], cmd[3], cmd[4]);
`endif
            end
            else ci <= ci + 1;
          end else if (({shin[6:0], mosi} & 8'hC0) == 8'h40) begin
            cmd[0] = {shin[6:0], mosi};
            coll <= 1;
            ci   <= 1;
          end
        end else begin
          nbit <= nbit + 1;
        end
      end

      if (fall) begin
        if (nbit == 0) begin
          // load the next response byte for the byte about to be clocked
          if (wst == 4 && rptr >= rlen) shout <= 8'h00;   // busy
          else if (rptr < rlen) begin
`ifdef CARD_TRACE
            $display("T=%0t CARD tx %02h (%0d/%0d)", $time, rbuf[rptr], rptr, rlen);
`endif
            shout <= rbuf[rptr]; rptr = rptr + 1;
          end
          else shout <= 8'hFF;
        end else begin
          shout <= {shout[6:0], 1'b1};
        end
      end
    end
  end
endmodule
