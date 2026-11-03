// Behavioral body for RAMB18E1/RAMB36E1, spliced into yosys's
// timing-only cells_sim models by scripts/mk_cells_sim.sh.
// Scope: TDP and full-width SDP, DO_REG 0, no cascade, no ECC, clocks
// and enables not inverted, one of read/write width 0 per TDP port.
// Anything else stops the simulation.
// Layout per UG473: a word of d data bits at word address a holds data
// bits [a*d +: d] and parity bits [a*d/8 +: d/8]; INIT_kk is data bits
// [256*kk +: 256], INITP_kk parity bits [256*kk +: 256].
// The splice defines XB_DBITS, XB_ABITS and loads xb_d/xb_p from INIT.
localparam XB_PBITS = XB_DBITS / 8;
localparam XB_SDP = (RAM_MODE == "SDP");
localparam XB_HW = XB_DBITS / 1024;          // pins per data group: 16 or 32

reg [XB_DBITS-1:0] xb_d;
reg [XB_PBITS-1:0] xb_p;

function integer xb_dw(input integer w);     // data bits of a port width
  xb_dw = (w >= 9) ? (w / 9) * 8 : w;
endfunction
function integer xb_lg(input integer v);
  integer k;
  begin
    xb_lg = 0;
    for (k = 0; (1 << k) < v; k = k + 1) xb_lg = k + 1;
  end
endfunction
function [71:0] xb_unx(input [71:0] v);      // silicon has no X: X loads as 0
  integer k;
  for (k = 0; k < 72; k = k + 1) xb_unx[k] = (v[k] === 1'b1);
endfunction

localparam XB_DA = XB_SDP ? 2 * XB_HW : xb_dw(READ_WIDTH_A > WRITE_WIDTH_A ? READ_WIDTH_A : WRITE_WIDTH_A);
localparam XB_DB = XB_SDP ? 2 * XB_HW : xb_dw(READ_WIDTH_B > WRITE_WIDTH_B ? READ_WIDTH_B : WRITE_WIDTH_B);

// output latches; in SDP the A latch holds the whole read word
reg [63:0] xb_oa, xb_ob;
reg [7:0] xb_opa, xb_opb;

assign DOADO = xb_oa[XB_HW-1:0];
assign DOPADOP = xb_opa[XB_HW/8-1:0];
assign DOBDO = XB_SDP ? xb_oa[2*XB_HW-1:XB_HW] : xb_ob[XB_HW-1:0];
assign DOPBDOP = XB_SDP ? xb_opa[XB_HW/4-1:XB_HW/8] : xb_opb[XB_HW/8-1:0];

task xb_outval(input [71:0] va, input [71:0] vb, input which_b);
  reg [71:0] a, b;
  begin
    a = xb_unx(va); b = xb_unx(vb);
    if (XB_SDP) begin
      xb_oa = 0; xb_opa = 0;
      xb_oa[XB_HW-1:0] = a[XB_HW-1:0];
      xb_oa[2*XB_HW-1:XB_HW] = b[XB_HW-1:0];
      xb_opa[XB_HW/8-1:0] = a[XB_HW +: 4];
      xb_opa[XB_HW/4-1:XB_HW/8] = b[XB_HW +: 4];
    end else if (!which_b) begin
      xb_oa = a & ((72'd1 << XB_DA) - 1);
      xb_opa = (a >> XB_DA) & ((1 << (XB_DA / 8)) - 1);
    end else begin
      xb_ob = b & ((72'd1 << XB_DB) - 1);
      xb_opb = (b >> XB_DB) & ((1 << (XB_DB / 8)) - 1);
    end
  end
endtask

initial begin
  if (DOA_REG != 0 || DOB_REG != 0) begin $display("XB %m: DO_REG unsupported"); $finish; end
  if (IS_CLKARDCLK_INVERTED || IS_CLKBWRCLK_INVERTED || IS_ENARDEN_INVERTED || IS_ENBWREN_INVERTED) begin
    $display("XB %m: inverted clock or enable unsupported"); $finish;
  end
  if (XB_SDP && (xb_dw(READ_WIDTH_A) != 2 * XB_HW || xb_dw(WRITE_WIDTH_B) != 2 * XB_HW)) begin
    $display("XB %m: SDP only at full width (R%0d W%0d)", READ_WIDTH_A, WRITE_WIDTH_B); $finish;
  end
  if (!XB_SDP && ((READ_WIDTH_A && WRITE_WIDTH_A && READ_WIDTH_A != WRITE_WIDTH_A) ||
                  (READ_WIDTH_B && WRITE_WIDTH_B && READ_WIDTH_B != WRITE_WIDTH_B))) begin
    $display("XB %m: asymmetric TDP port unsupported"); $finish;
  end
  xb_oa = 0; xb_ob = 0; xb_opa = 0; xb_opb = 0;
  xb_outval(INIT_A, INIT_B, 0);
  if (!XB_SDP) xb_outval(INIT_A, INIT_B, 1);
end

// collisions: the last write and read of each port, by time and bit range
time xb_wt_a = 0, xb_wt_b = 0, xb_rt_a = 0, xb_rt_b = 0;
reg xb_wv_a = 0, xb_wv_b = 0, xb_rv_a = 0, xb_rv_b = 0;
integer xb_wlo_a, xb_whi_a, xb_wlo_b, xb_whi_b, xb_rlo_a, xb_rhi_a, xb_rlo_b, xb_rhi_b;
integer xb_ncoll = 0;
task xb_coll(input integer lo1, input integer hi1, input integer lo2, input integer hi2);
  if (lo1 <= hi2 && lo2 <= hi1 && xb_ncoll < 4) begin
    xb_ncoll = xb_ncoll + 1;
    $display("XB collision %m bits %0d..%0d vs %0d..%0d t=%0t modes %0s/%0s", lo1, hi1, lo2, hi2, $time, WRITE_MODE_A, WRITE_MODE_B);
  end
endtask

// Port A: TDP port A, or the SDP read port. Memory writes are nonblocking,
// so a read on either port in the same time step sees the old contents.
always @(posedge CLKARDCLK) if (ENARDEN === 1'b1) begin : xb_pa
  integer dw, a, lo, plo, k;
  reg [63:0] old, nw;
  reg [7:0] oldp, nwp;
  reg wr, rd, en;
  dw = XB_DA;
  a = ADDRARDADDR[XB_ABITS-1:0] >> xb_lg(dw);
  lo = a * dw;
  plo = a * (dw / 8);
  old = xb_d[lo +: 64] & ((65'd1 << dw) - 1);
  oldp = (dw >= 8) ? (xb_p[plo +: 8] & ((9'd1 << (dw / 8)) - 1)) : 8'd0;
  nw = old;
  nwp = oldp;
  wr = 0;
  rd = XB_SDP || READ_WIDTH_A != 0;
  if (!XB_SDP && WRITE_WIDTH_A != 0) begin
    for (k = 0; k < dw; k = k + 1) begin
      en = (dw >= 16) ? WEA[k / 8] : WEA[0];
      if (en === 1'b1) begin nw[k] = DIADI[k]; wr = 1; end
    end
    for (k = 0; k < dw / 8; k = k + 1) begin
      en = (dw >= 16) ? WEA[k] : WEA[0];
      if (en === 1'b1) nwp[k] = DIPADIP[k];
    end
  end
  if (wr) begin
    for (k = 0; k < dw; k = k + 1) xb_d[lo + k] <= nw[k];
    for (k = 0; k < dw / 8; k = k + 1) xb_p[plo + k] <= nwp[k];
    xb_wt_a = $time; xb_wv_a = 1; xb_wlo_a = lo; xb_whi_a = lo + dw - 1;
    if (xb_rv_b && xb_rt_b == $time) xb_coll(xb_wlo_a, xb_whi_a, xb_rlo_b, xb_rhi_b);
  end
  if (RSTRAMARSTRAM === 1'b1) xb_outval(SRVAL_A, SRVAL_B, 0);
  else if (rd) begin
    if (wr && WRITE_MODE_A == "NO_CHANGE") ;
    else if (wr && WRITE_MODE_A == "WRITE_FIRST") begin xb_oa = nw; xb_opa = nwp; end
    else begin xb_oa = old; xb_opa = oldp; end
    xb_rt_a = $time; xb_rv_a = 1; xb_rlo_a = lo; xb_rhi_a = lo + dw - 1;
    if (xb_wv_b && xb_wt_b == $time) xb_coll(xb_rlo_a, xb_rhi_a, xb_wlo_b, xb_whi_b);
  end
end

// Port B: TDP port B, or the SDP write port (data on both pin groups).
always @(posedge CLKBWRCLK) if (ENBWREN === 1'b1) begin : xb_pb
  integer dw, a, lo, plo, k;
  reg [63:0] old, nw, din;
  reg [7:0] oldp, nwp, dinp;
  reg wr, rd, en;
  dw = XB_DB;
  a = ADDRBWRADDR[XB_ABITS-1:0] >> xb_lg(dw);
  lo = a * dw;
  plo = a * (dw / 8);
  old = xb_d[lo +: 64] & ((65'd1 << dw) - 1);
  oldp = (dw >= 8) ? (xb_p[plo +: 8] & ((9'd1 << (dw / 8)) - 1)) : 8'd0;
  din = XB_SDP ? {DIBDI, DIADI} : DIBDI;
  dinp = XB_SDP ? {DIPBDIP, DIPADIP} : DIPBDIP;
  nw = old;
  nwp = oldp;
  wr = 0;
  rd = !XB_SDP && READ_WIDTH_B != 0;
  if (XB_SDP || WRITE_WIDTH_B != 0) begin
    for (k = 0; k < dw; k = k + 1) begin
      en = (dw >= 16) ? WEBWE[k / 8] : WEBWE[0];
      if (en === 1'b1) begin nw[k] = din[k]; wr = 1; end
    end
    for (k = 0; k < dw / 8; k = k + 1) begin
      en = (dw >= 16) ? WEBWE[k] : WEBWE[0];
      if (en === 1'b1) nwp[k] = dinp[k];
    end
  end
  if (wr) begin
    for (k = 0; k < dw; k = k + 1) xb_d[lo + k] <= nw[k];
    for (k = 0; k < dw / 8; k = k + 1) xb_p[plo + k] <= nwp[k];
    xb_wt_b = $time; xb_wv_b = 1; xb_wlo_b = lo; xb_whi_b = lo + dw - 1;
    if (xb_rv_a && xb_rt_a == $time) xb_coll(xb_wlo_b, xb_whi_b, xb_rlo_a, xb_rhi_a);
  end
  if (!XB_SDP && RSTRAMB === 1'b1) xb_outval(SRVAL_A, SRVAL_B, 1);
  else if (rd) begin
    if (wr && WRITE_MODE_B == "NO_CHANGE") ;
    else if (wr && WRITE_MODE_B == "WRITE_FIRST") begin xb_ob = nw; xb_opb = nwp; end
    else begin xb_ob = old; xb_opb = oldp; end
    xb_rt_b = $time; xb_rv_b = 1; xb_rlo_b = lo; xb_rhi_b = lo + dw - 1;
    if (xb_wv_a && xb_wt_a == $time) xb_coll(xb_rlo_b, xb_rhi_b, xb_wlo_a, xb_whi_a);
  end
end
