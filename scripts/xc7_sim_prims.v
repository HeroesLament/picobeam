// Behavioural stand-ins for the 7-series hard blocks `Xc7M5Top` uses, for
// iverilog only. They model what the harness depends on and nothing else.
//
// PS7: FCLKCLK[0] and the M_AXI_GP0 master come from the testbench (`tb`)
// by hierarchical reference, so the testbench drives the bus directly.
// MMCME2_ADV: CLKOUT0 is the testbench's `pb_src`, an independent clock,
// so the two domains really are asynchronous in simulation. LOCKED rises
// 20 CLKIN cycles after RST falls. The DRP is a 128 x 16 register file
// that answers one DCLK after DEN.

`timescale 1ns/1ps

// -DPOSTSYNTH: the post-synthesis netlist is simulated against yosys's
// own xilinx/cells_sim.v, which already has a BUFG.
`ifndef POSTSYNTH
module BUFG(input I, output O);
  assign O = I;
endmodule
`endif

module MMCME2_ADV #(
  parameter BANDWIDTH = "OPTIMIZED", parameter COMPENSATION = "INTERNAL",
  parameter CLKIN1_PERIOD = 10.0, parameter DIVCLK_DIVIDE = 1,
  parameter CLKFBOUT_MULT_F = 10.0, parameter CLKFBOUT_PHASE = 0.0,
  parameter CLKOUT0_DIVIDE_F = 10.0, parameter CLKOUT0_PHASE = 0.0,
  parameter CLKOUT0_DUTY_CYCLE = 0.5, parameter CLKOUT1_DIVIDE = 10,
  parameter CLKOUT1_PHASE = 0.0, parameter CLKOUT1_DUTY_CYCLE = 0.5,
  parameter STARTUP_WAIT = "FALSE"
) (
  input CLKIN1, input CLKIN2, input CLKINSEL, input CLKFBIN, output CLKFBOUT,
  input RST, input PWRDWN, input DCLK, input DEN, input DWE,
  input [6:0] DADDR, input [15:0] DI, output reg [15:0] DO, output reg DRDY,
  input PSCLK, input PSEN, input PSINCDEC,
  output CLKOUT0, output CLKOUT1, output reg LOCKED
);
  reg [15:0] regs [0:127];
  reg [4:0] lk = 0;
  integer k;
  initial begin
    for (k = 0; k < 128; k = k + 1) regs[k] = 16'h0000;
    DRDY = 0; DO = 0; LOCKED = 0;
  end
  assign CLKFBOUT = CLKIN1;
  assign CLKOUT0 = tb.pb_src;
  assign CLKOUT1 = 1'b0;
  always @(posedge CLKIN1) begin
    if (RST) begin lk <= 0; LOCKED <= 0; end
    else if (lk != 5'd20) lk <= lk + 1;
    else LOCKED <= 1;
  end
  always @(posedge DCLK) begin
    DRDY <= DEN;
    if (DEN) begin
      if (DWE) regs[DADDR] <= DI;
      DO <= DWE ? 16'h0000 : regs[DADDR];
    end
  end
endmodule

module PS7(
  output [3:0] FCLKCLK, output [3:0] FCLKRESETN,
  input MAXIGP0ACLK,
  output [11:0] MAXIGP0AWID, output [31:0] MAXIGP0AWADDR, output [3:0] MAXIGP0AWLEN,
  output [2:0] MAXIGP0AWSIZE, output [1:0] MAXIGP0AWBURST, output [2:0] MAXIGP0AWPROT,
  output MAXIGP0AWVALID, input MAXIGP0AWREADY,
  output [11:0] MAXIGP0WID, output [31:0] MAXIGP0WDATA, output [3:0] MAXIGP0WSTRB,
  output MAXIGP0WLAST, output MAXIGP0WVALID, input MAXIGP0WREADY,
  input [11:0] MAXIGP0BID, input [1:0] MAXIGP0BRESP, input MAXIGP0BVALID, output MAXIGP0BREADY,
  output [11:0] MAXIGP0ARID, output [31:0] MAXIGP0ARADDR, output [3:0] MAXIGP0ARLEN,
  output [2:0] MAXIGP0ARSIZE, output [1:0] MAXIGP0ARBURST, output [2:0] MAXIGP0ARPROT,
  output MAXIGP0ARVALID, input MAXIGP0ARREADY,
  input [11:0] MAXIGP0RID, input [31:0] MAXIGP0RDATA, input [1:0] MAXIGP0RRESP,
  input MAXIGP0RLAST, input MAXIGP0RVALID, output MAXIGP0RREADY
);
  assign FCLKCLK = {3'b000, tb.fclk};
  assign FCLKRESETN = {3'b000, tb.fclk_rst_n};
  assign MAXIGP0AWID = 12'h000;
  assign MAXIGP0AWADDR = tb.awaddr;
  assign MAXIGP0AWLEN = 4'h0;
  assign MAXIGP0AWSIZE = 3'd2;
  assign MAXIGP0AWBURST = 2'd1;
  assign MAXIGP0AWPROT = 3'd0;
  assign MAXIGP0AWVALID = tb.awvalid;
  assign MAXIGP0WID = 12'h000;
  assign MAXIGP0WDATA = tb.wdata;
  assign MAXIGP0WSTRB = 4'hF;
  assign MAXIGP0WLAST = 1'b1;
  assign MAXIGP0WVALID = tb.wvalid;
  assign MAXIGP0BREADY = tb.bready;
  assign MAXIGP0ARID = 12'h000;
  assign MAXIGP0ARADDR = tb.araddr;
  assign MAXIGP0ARLEN = 4'h0;
  assign MAXIGP0ARSIZE = 3'd2;
  assign MAXIGP0ARBURST = 2'd1;
  assign MAXIGP0ARPROT = 3'd0;
  assign MAXIGP0ARVALID = tb.arvalid;
  assign MAXIGP0RREADY = tb.rready;
endmodule
