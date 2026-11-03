defmodule PicoBEAM.RTL.Xc7M5Top do
  @moduledoc """
  The two-engine machine on a Zynq-7020, as a timing benchmark: `M5Core`
  clocked by an MMCM whose frequency the PS can rewrite, fed and watched
  from AXI, with no package pins at all.

      FCLK0 100 MHz ─▶ BUFG ─▶ axi_clk ─┬─▶ AXI4-Lite regs, DRP, image RAM
                                        └─▶ MMCME2_ADV ─▶ BUFG ─▶ pb_clk
      pb_clk: UART player ─▶ M5Core.ftdi_txd   (the `notes/37` side door)
              M5Core obs taps ─▶ 32-bit MISR, two `out` capture buffers

  ## Why a signature, not an answer

  Everything in the `pb_clk` domain leaves reset on the same edge: the
  core, the player that pushes the image, and the cycle counter. From that
  edge the machine is a pure function of the image, cycle for cycle, at
  ANY frequency at which it meets timing. So a signature over every
  cycle's fetch PCs, `out` words and flags, taken for a fixed number of
  cycles, is one number that must not change as the clock goes up. The
  first frequency at which it changes is where silicon stopped meeting
  timing. The reference is the same run at a slow clock, and the `out`
  capture buffers tie it back to the model's answer.

  No card: `sd_d0` idles high, the SD outputs go nowhere, and `SdBoot`
  talks to nothing, deterministically. The debug UART is unused.

  ## Registers (AXI base 0x4000_0000)

      CTRL0  DRP command: [15:0] DI, [22:16] DADDR, [23] DWE,
             [31] go (0 -> 1 issues one transaction)
      CTRL1  [0] MMCM reset  [1] hold the pb_clk side in reset
             [2] run: 0 -> 1 releases the core and starts the push
             [3] freq gate run  [4] freq counter clear
             [31:8] freq gate window, axi_clk cycles
      CTRL2  image write: [10:0] byte address, [23:16] byte
             (each write to CTRL2 stores one byte)
      CTRL3  [12:0] image length in bytes
             [31:16] run window, units of 1024 pb_clk cycles

      STATUS0 [15:0] DRP DO  [23:16] DRDY count  [30] DRP busy
              [31] MMCM locked
      STATUS1 [23:0] pb_clk cycles counted in the gate  [31] gate open
      STATUS2 0x0B5E0006 (design id)
      STATUS3 [23:0] heartbeat  [30] locked  [31] run window done

  Memory window (AXI offset 0x10000 + 4 * word):

      0x000  signature        0x001  cycles at done
      0x002  {out count 1, out count 0}
      0x003  {.., flags at done[7:4], push done[1], done[0]}
      0x400 + i  engine 0 `out` i: {cycle[15:0], word[15:0]}
      0x800 + i  engine 1 `out` i

  The pb_clk-side results are read only after STATUS3[31] is set, when
  they no longer change.
  """

  use Hw.Component

  # clocks per UART bit on both ends of the side door; the player below
  # hardcodes `div == @udiv - 1` as 7 (attributes do not expand in `on`)
  @udiv 8

  wire :fclk_clk0, 1
  wire :fclk_reset0_n, 1
  wire :axi_clk, 1
  clock :axi_clk, freq: 100.0

  wire :pb_raw, 1
  wire :pb_clk, 1
  clock :pb_clk, freq: 50.0

  # ---- AXI
  wire :awid, 12
  wire :awaddr, 32
  wire :awvalid, 1
  wire :awready, 1
  wire :wdata, 32
  wire :wstrb, 4
  wire :wvalid, 1
  wire :wready, 1
  wire :bresp, 2
  wire :bvalid, 1
  wire :bready, 1
  wire :arid, 12
  wire :araddr, 32
  wire :arvalid, 1
  wire :arready, 1
  wire :rdata, 32
  wire :rresp, 2
  wire :rvalid, 1
  wire :rready, 1
  wire :bid_q, 12, init: 0
  wire :rid_q, 12, init: 0
  wire :rlast_tie, 1
  wire :awaddr_low, 17
  wire :araddr_low, 17

  wire :ctrl0, 32
  wire :ctrl1, 32
  wire :ctrl2, 32
  wire :ctrl3, 32
  wire :ctrl2_wr, 1
  wire :status3_rd, 1
  wire :mem_raddr, 15
  wire :mem_rdata, 32
  wire :status0, 32
  wire :status1, 32
  wire :status2, 32
  wire :status3, 32
  wire :heartbeat, 24, init: 0
  wire :pad6, 6
  wire :pad7, 7

  # ---- MMCM and its DRP (axi_clk domain)
  wire :mm_rst, 1
  wire :mm_den, 1
  wire :mm_dwe, 1
  wire :mm_daddr, 7
  wire :mm_din, 16
  wire :mm_dout, 16
  wire :mm_drdy, 1
  wire :mm_locked, 1
  wire :mm_unused1, 1
  wire :mm_zero, 1
  wire :drp_go_q, 1, init: 0
  wire :drp_busy, 1, init: 0
  wire :drp_do_q, 16, init: 0
  wire :drp_cnt, 8, init: 0
  wire :locked_s, 1

  # ---- image RAM: written from AXI, read by the player on pb_clk
  memory :img, width: 8, depth: 2048, sync_read: :pb_clk
  wire :img_wr_q, 1, init: 0
  wire :img_rd, 8

  # ---- results, read back through the memory window
  memory :ob0, width: 32, depth: 512, sync_read: :axi_clk
  memory :ob1, width: 32, depth: 512, sync_read: :axi_clk
  wire :ob0_rd, 32
  wire :ob1_rd, 32
  wire :res_q, 32, init: 0
  wire :sel_q, 2, init: 0
  wire :done_s, 1

  # ---- freq counter (gate on axi_clk, count on pb_clk)
  wire :run_q, 1, init: 0
  wire :refcnt, 24, init: 0
  wire :gate, 1, init: 0
  wire :g_s0, 1, init: 0
  wire :g_s1, 1, init: 0
  wire :c_s0, 1, init: 0
  wire :c_s1, 1, init: 0
  wire :mcount, 24, init: 0

  # ---- pb_clk side
  wire :hold_a, 1
  wire :run_a, 1
  wire :poly, 32
  wire :win_rd, 32
  wire :hold_s, 1
  wire :run_s, 1
  wire :go, 1
  wire :pb_rst, 1
  wire :txd, 1, init: 1
  wire :div, 4, init: 0
  wire :bitpos, 4, init: 0
  wire :sh, 8, init: 0
  wire :bi, 13, init: 0
  wire :pdone, 1, init: 0
  wire :cyc, 26, init: 0
  wire :win, 26
  wire :zero10, 10
  wire :done, 1, init: 0
  wire :sig, 32, init: 0
  wire :obs32, 32
  wire :obs_hi, 32
  wire :od1_rot, 32
  wire :od0m, 36
  wire :od1m, 36
  wire :zero36, 36
  wire :n0, 16, init: 0
  wire :n1, 16, init: 0
  wire :flags_at_done, 4, init: 0

  wire :ov0, 1
  wire :od0, 36
  wire :ov1, 1
  wire :od1, 36
  wire :pc0, 9
  wire :pc1, 9
  wire :flags, 4

  wire :sd_clk, 1
  wire :sd_cmd, 1
  wire :sd_d1, 1
  wire :sd_d2, 1
  wire :sd_d3, 1
  wire :led, 8
  wire :dbg_txd, 1
  wire :one, 1
  wire :nil1, 1

  instance :ps, Hw.PS7,
    fclk_clk0: :fclk_clk0,
    fclk_reset0_n: :fclk_reset0_n,
    maxigp0_aclk: :axi_clk,
    maxigp0_awid: :awid,
    maxigp0_awaddr: :awaddr,
    maxigp0_awvalid: :awvalid,
    maxigp0_awready: :awready,
    maxigp0_wdata: :wdata,
    maxigp0_wstrb: :wstrb,
    maxigp0_wvalid: :wvalid,
    maxigp0_wready: :wready,
    maxigp0_bresp: :bresp,
    maxigp0_bvalid: :bvalid,
    maxigp0_bready: :bready,
    maxigp0_bid: :bid_q,
    maxigp0_arid: :arid,
    maxigp0_araddr: :araddr,
    maxigp0_arvalid: :arvalid,
    maxigp0_arready: :arready,
    maxigp0_rdata: :rdata,
    maxigp0_rresp: :rresp,
    maxigp0_rvalid: :rvalid,
    maxigp0_rready: :rready,
    maxigp0_rlast: :rlast_tie,
    maxigp0_rid: :rid_q

  instance :clkbuf, Hw.Xilinx.BUFG,
    i: :fclk_clk0,
    o: :axi_clk

  instance :axil, Hw.AXI4Lite.Slave,
    aclk: :axi_clk,
    aresetn: :fclk_reset0_n,
    s_axi_awaddr: :awaddr_low,
    s_axi_awvalid: :awvalid,
    s_axi_awready: :awready,
    s_axi_wdata: :wdata,
    s_axi_wstrb: :wstrb,
    s_axi_wvalid: :wvalid,
    s_axi_wready: :wready,
    s_axi_bresp: :bresp,
    s_axi_bvalid: :bvalid,
    s_axi_bready: :bready,
    s_axi_araddr: :araddr_low,
    s_axi_arvalid: :arvalid,
    s_axi_arready: :arready,
    s_axi_rdata: :rdata,
    s_axi_rresp: :rresp,
    s_axi_rvalid: :rvalid,
    s_axi_rready: :rready,
    ctrl0: :ctrl0,
    ctrl1: :ctrl1,
    ctrl2: :ctrl2,
    ctrl3: :ctrl3,
    ctrl2_wr: :ctrl2_wr,
    status3_rd: :status3_rd,
    mem_raddr: :mem_raddr,
    mem_rdata: :mem_rdata,
    status0: :status0,
    status1: :status1,
    status2: :status2,
    status3: :status3

  # 100 MHz in, 1000 MHz VCO, 50 MHz out until the DRP says otherwise
  instance :mmcm, Hw.Xilinx.MMCME2_ADV,
    CLKIN1_PERIOD: 10.0,
    DIVCLK_DIVIDE: 1,
    CLKFBOUT_MULT_F: 10.0,
    CLKOUT0_DIVIDE_F: 20.0,
    CLKOUT1_DIVIDE: 20,
    clkin1: :axi_clk,
    rst: :mm_rst,
    pwrdwn: :mm_zero,
    dclk: :axi_clk,
    den: :mm_den,
    dwe: :mm_dwe,
    daddr: :mm_daddr,
    din: :mm_din,
    dout: :mm_dout,
    drdy: :mm_drdy,
    clkout0: :pb_raw,
    clkout1: :mm_unused1,
    locked: :mm_locked

  instance :pbbuf, Hw.Xilinx.BUFG,
    i: :pb_raw,
    o: :pb_clk

  instance :lock_sync, Hw.CDC.Sync2,
    clk_dst: :axi_clk,
    rst: :mm_zero,
    data_in: :mm_locked,
    data_out: :locked_s

  instance :done_sync, Hw.CDC.Sync2,
    clk_dst: :axi_clk,
    rst: :mm_zero,
    data_in: :done,
    data_out: :done_s

  instance :hold_sync, Hw.CDC.Sync2,
    clk_dst: :pb_clk,
    rst: :mm_zero,
    data_in: :hold_a,
    data_out: :hold_s

  instance :run_sync, Hw.CDC.Sync2,
    clk_dst: :pb_clk,
    rst: :mm_zero,
    data_in: :run_a,
    data_out: :run_s

  instance :pb, PicoBEAM.RTL.M5Core,
    UDIV: @udiv,
    clk_12: :pb_clk,
    rst: :pb_rst,
    btn2: :mm_zero,
    sd_d0: :one,
    ftdi_txd: :txd,
    sd_clk: :sd_clk,
    sd_cmd: :sd_cmd,
    sd_d1: :sd_d1,
    sd_d2: :sd_d2,
    sd_d3: :sd_d3,
    led: :led,
    ftdi_rxd: :dbg_txd,
    obs_ov0: :ov0,
    obs_od0: :od0,
    obs_ov1: :ov1,
    obs_od1: :od1,
    obs_pc0: :pc0,
    obs_pc1: :pc1,
    obs_flags: :flags

  comb do
    rlast_tie = 1
    one = 1
    mm_zero = 0
    pad6 = 0
    pad7 = 0
    zero10 = 0
    awaddr_low = awaddr[16..0]
    araddr_low = araddr[16..0]

    mm_rst = ctrl1[0..0]
    mm_den = band(ctrl0[31..31], bnot(drp_go_q))
    mm_dwe = ctrl0[23..23]
    mm_daddr = ctrl0[22..16]
    mm_din = ctrl0[15..0]

    hold_a = bor(ctrl1[1..1], bnot(mm_locked))
    run_a = ctrl1[2..2]
    go = band(run_s, bnot(hold_s))
    pb_rst = bnot(go)

    status0 = {mm_locked, drp_busy, pad6, drp_cnt, drp_do_q}
    status1 = {gate, pad7, mcount}
    status2 = 0x0B5E0006
    status3 = {done_s, locked_s, pad6, heartbeat}

    img_rd = img[bi[10..0]]
    ob0_rd = ob0[mem_raddr[8..0]]
    ob1_rd = ob1[mem_raddr[8..0]]
    win_rd = if sel_q == 2, do: ob1_rd, else: res_q
    mem_rdata = if sel_q == 1, do: ob0_rd, else: win_rd

    win = {ctrl3[31..16], zero10}
    # an `out` word counts only on its strobe; between strobes the port
    # carries whatever the engine left on it
    zero36 = 0
    od0m = if ov0 == 1, do: od0, else: zero36
    od1m = if ov1 == 1, do: od1, else: zero36
    od1_rot = {od1m[15..0], od1m[31..16]}
    obs_hi = {pc0, pc1, ov0, ov1, flags, od0m[35..32], od1m[35..32]}
    obs32 = bxor(bxor(obs_hi, od0m[31..0]), od1_rot)
    poly = if sig[31..31] == 1, do: 0x04C11DB7, else: 0
  end

  # ---- axi_clk: AXI ids, heartbeat, DRP, image writes, result reads
  on :axi_clk do
    if fclk_reset0_n == 0 do
      bid_q = 0
      rid_q = 0
      heartbeat = 0
    else
      heartbeat = heartbeat + 1

      if awvalid == 1 and awready == 1 do
        bid_q = awid
      end

      if arvalid == 1 and arready == 1 do
        rid_q = arid
      end
    end
  end

  on :axi_clk do
    drp_go_q = ctrl0[31..31]

    if mm_den == 1 do
      drp_busy = 1
    end

    if mm_drdy == 1 do
      drp_busy = 0
      drp_do_q = mm_dout
      drp_cnt = drp_cnt + 1
    end
  end

  # `ctrl2_wr` comes out of the slave's registered FSM; one more flop puts
  # the store a cycle after it, when CTRL2 is certainly the new value.
  on :axi_clk do
    img_wr_q = ctrl2_wr

    if img_wr_q == 1 do
      img[ctrl2[10..0]] = ctrl2[23..16]
    end
  end

  # The memory window's address arrives a cycle before RVALID; register the
  # selection and the result word so they line up with the BRAM reads.
  on :axi_clk do
    sel_q = mem_raddr[11..10]

    if mem_raddr[1..0] == 0 do
      res_q = sig
    end

    if mem_raddr[1..0] == 1 do
      res_q = {pad6, cyc}
    end

    if mem_raddr[1..0] == 2 do
      res_q = {n1, n0}
    end

    if mem_raddr[1..0] == 3 do
      res_q = {heartbeat, flags_at_done, pad6[1..0], pdone, done}
    end
  end

  # ---- freq gate: opens on CTRL1[3] rising for CTRL1[31:8] axi_clk cycles
  on :axi_clk do
    run_q = ctrl1[3..3]

    if ctrl1[3..3] == 0 do
      refcnt = 0
      gate = 0
    else
      if run_q == 0 do
        refcnt = ctrl1[31..8]
        gate = 1
      else
        if refcnt != 0 do
          refcnt = refcnt - 1
        end

        if refcnt == 1 do
          gate = 0
        end
      end
    end
  end

  on :pb_clk do
    g_s0 = gate
    g_s1 = g_s0
    c_s0 = ctrl1[4..4]
    c_s1 = c_s0

    if c_s1 == 1 do
      mcount = 0
    else
      if g_s1 == 1 do
        mcount = mcount + 1
      end
    end
  end

  # ---- pb_clk: the player. 8N1, LSB first, @udiv clocks a bit, one byte
  # after another with no gap. The byte is taken at the END of its start
  # bit, so the image RAM's registered read has long since settled.
  on :pb_clk do
    if go == 0 do
      txd = 1
      div = 0
      bitpos = 0
      bi = 0
      pdone = 0
    else
      if pdone == 0 do
        if div == 0 do
          if bitpos == 0 do
            txd = 0
          end

          if bitpos != 0 and bitpos != 9 do
            txd = sh[0..0]
            sh = sh >>> 1
          end

          if bitpos == 9 do
            txd = 1
          end
        end

        if div == 7 do
          div = 0

          if bitpos == 0 do
            sh = img_rd
          end

          if bitpos == 9 do
            bitpos = 0
            bi = bi + 1

            if bi + 1 == ctrl3[12..0] do
              pdone = 1
            end
          else
            bitpos = bitpos + 1
          end
        else
          div = div + 1
        end
      end
    end
  end

  # ---- pb_clk: cycle counter, signature, out capture
  on :pb_clk do
    if go == 0 do
      cyc = 0
      done = 0
      sig = 0
      n0 = 0
      n1 = 0
      flags_at_done = 0
    else
      if done == 0 do
        cyc = cyc + 1
        sig = bxor({sig[30..0], mm_zero}, bxor(poly, obs32))

        if ov0 == 1 do
          if n0[15..9] == 0 do
            ob0[n0[8..0]] = {cyc[15..0], od0[15..0]}
          end

          n0 = n0 + 1
        end

        if ov1 == 1 do
          if n1[15..9] == 0 do
            ob1[n1[8..0]] = {cyc[15..0], od1[15..0]}
          end

          n1 = n1 + 1
        end

        if cyc + 1 == win do
          done = 1
          flags_at_done = flags
        end
      end
    end
  end
end
