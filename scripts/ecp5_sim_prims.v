// Behavioural stubs for the ECP5 hard blocks a board top instantiates,
// so `tb_m3_top` / `tb_m4_top` can simulate the WHOLE design — ROM
// loader, engine, LED instrument and UART — rather than the parts.
//
// `notes/15` set that rule at M2 ("simulate the top, not just the
// parts") and it is why first silicon held no surprises. The stub then
// lived only in an ad-hoc iverilog invocation and was never committed,
// so the top testbenches quietly stopped being runnable and drifted
// out of the regression gate. This file is that stub, kept.
//
// Only what the tops actually use is modelled. The PLL is a divider
// pair, not a phase model: the design's clocks are integer ratios of
// the 25 MHz input and nothing in it is sensitive to PLL phase.

`timescale 1ns/1ps

module EHXPLLL (
  input  CLKI,
  input  CLKFB,
  input  RST,
  input  STDBY,
  input  PHASESEL0, input PHASESEL1, input PHASEDIR,
  input  PHASESTEP, input PHASELOADREG, input PLLWAKESYNC,
  input  ENCLKOP, input ENCLKOS, input ENCLKOS2, input ENCLKOS3,
  output CLKOP,
  output CLKOS,
  output CLKOS2,
  output CLKOS3,
  output LOCK,
  output INTLOCK,
  output REFCLK,
  output CLKINTFB
);
  parameter CLKI_DIV = 1;
  parameter CLKFB_DIV = 1;
  parameter CLKOP_DIV = 1;
  parameter CLKOS_DIV = 1;
  parameter CLKOP_CPHASE = 0, CLKOS_CPHASE = 0;
  parameter CLKOP_FPHASE = 0, CLKOS_FPHASE = 0;
  parameter CLKOS2_DIV = 1, CLKOS3_DIV = 1;
  parameter PLLRST_ENA = "DISABLED", INTFB_WAKE = "DISABLED";
  parameter STDBY_ENABLE = "DISABLED", DPHASE_SOURCE = "DISABLED";
  parameter OUTDIVIDER_MUXA = "DIVA", OUTDIVIDER_MUXB = "DIVB";
  parameter OUTDIVIDER_MUXC = "DIVC", OUTDIVIDER_MUXD = "DIVD";
  parameter CLKOP_ENABLE = "ENABLED", CLKOS_ENABLE = "DISABLED";
  parameter CLKOS2_ENABLE = "DISABLED", CLKOS3_ENABLE = "DISABLED";
  parameter FEEDBK_PATH = "CLKOP";
  parameter CLKOP_TRIM_POL = "FALLING", CLKOP_TRIM_DELAY = 0;
  parameter CLKOS_TRIM_POL = "FALLING", CLKOS_TRIM_DELAY = 0;

  // The VCO is CLKI * CLKFB_DIV / CLKI_DIV; each output is the VCO
  // divided down. Modelled as counters off CLKI, which is exact for
  // integer ratios and is all these designs need.
  real vco_mult = (CLKFB_DIV * 1.0) / (CLKI_DIV * 1.0);

  integer op_acc = 0, os_acc = 0;
  reg op_r = 0, os_r = 0;

  // toggle CLKOP every CLKOP_DIV/vco_mult input half-cycles
  integer op_n, os_n;
  initial begin
    op_n = (CLKOP_DIV * CLKI_DIV);
    os_n = (CLKOS_DIV * CLKI_DIV);
  end

  always @(posedge CLKI or negedge CLKI) begin
    op_acc = op_acc + CLKFB_DIV;
    if (op_acc >= op_n) begin op_acc = op_acc - op_n; op_r = ~op_r; end
    os_acc = os_acc + CLKFB_DIV;
    if (os_acc >= os_n) begin os_acc = os_acc - os_n; os_r = ~os_r; end
  end

  assign CLKOP = op_r;
  assign CLKOS = os_r;
  assign CLKOS2 = 1'b0;
  assign CLKOS3 = 1'b0;
  assign REFCLK = CLKI;
  assign CLKINTFB = op_r;

  // lock after a few input cycles, the way the real block behaves
  integer lk = 0;
  reg lock_r = 0;
  always @(posedge CLKI) begin
    if (lk < 20) lk = lk + 1;
    else lock_r <= 1'b1;
  end
  assign LOCK = lock_r;
  assign INTLOCK = lock_r;
endmodule
