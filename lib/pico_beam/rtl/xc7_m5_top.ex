defmodule PicoBEAM.RTL.Xc7M5Top do
  @moduledoc """
  The two-engine machine on a Zynq-7020, as a timing benchmark and as a
  machine left running: `M5Core` clocked by an MMCM whose frequency the
  PS can rewrite, fed and watched from AXI, with no package pins at all.

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
             [2] run: 0 -> 1 releases the core and starts the push;
                 1 -> 0 stops it (the core is held in reset)
             [3] freq gate run  [4] freq counter clear
             [5] snapshot request: toggle it, wait for STATUS3[29] to
                 equal it, then read words 0x004..0x00B and 0x00E
             [6] host-out pop request: toggle it, wait for STATUS3[27]
                 to equal it, then read words 0x00C/0x00D
             [31:8] freq gate window, axi_clk cycles
      CTRL2  [31:30] selects what a write to CTRL2 does:
             0  image byte: [10:0] address, [23:16] byte
             1  host-in flit, word[23:0] from [23:0]
             2  host-in flit, word[35:24] from [11:0], len from [18:12]
             3  host-in flit, head [0], kind [4:1], deng [8:5], and
                push: toggles the host-in request; wait for STATUS3[28]
                to follow before staging the next flit
      CTRL3  [12:0] image length in bytes
             [31:16] run window, units of 1024 pb_clk cycles;
                     0 runs until CTRL1[2] is cleared (done never sets)

      STATUS0 [15:0] DRP DO  [23:16] DRDY count  [30] DRP busy
              [31] MMCM locked
      STATUS1 [23:0] pb_clk cycles counted in the gate  [31] gate open
      STATUS2 0x0B5E0008 (design id; 7 had no host port, 6 no snapshot)
      STATUS3 [23:0] heartbeat  [27] host-out pop ack  [28] host-in
              push ack  [29] snapshot ack  [30] locked
              [31] run window done

  Memory window (AXI offset 0x10000 + 4 * word):

      0x000  signature        0x001  cycles at done
      0x002  {out count 1, out count 0}
      0x003  {.., flags at done[7:4], push done[1], done[0]}

  Snapshot (valid once STATUS3[29] == CTRL1[5]; stable until the next
  toggle, so a running machine can be read without tearing):

      0x004  pb_clk cycles since run (free-running, 32 bits)
      0x005  global {vm halt, idle both, fault any, from uart,
             sd write nibble[27:24], last out word[23:8], 0[7:0]}
      0x006  engine 0 {fault reason[31:24], fault slot[23:19],
             fault count[15:8], swaps[7:0]}
      0x007  engine 0 {spawns[31:20], deaths[19:8], occupancy[7:2],
             idle[1], faulted[0]}
      0x008  engine 0 {run-queue count[31:26], x seat[25:24],
             x enable[23], x pc[22:14]}
      0x009..0x00B  engine 1, same three words
      0x00E  queue levels at the snapshot {host-in [21:16], host-out [5:0]}

  Host port (`RingHost`, ring node 15; valid once STATUS3[27] == CTRL1[6]):

      0x00C  popped flit {valid[31], head[30], kind[29:26], deng[25:22],
             len[21:15], word[35:32] at [3:0]}; valid 0 = host-out empty
      0x00D  popped flit word[31:0]

  A packet is a head (kind, dest engine, dest pid in `word`, `len`) and
  `len` payload flits. A process sends to the host by sending to a pid
  whose engine field is 15; the host sends by pushing a kind-0 packet
  whose head names the engine (0 or 1) and the pid. Pushes while the
  core is held in reset are dropped (the queue is in reset).
      0x400 + i  engine 0 `out` i: {cycle[15:0], word[15:0]}
      0x800 + i  engine 1 `out` i

  Words 0x000..0x003 and the `out` buffers are read only after
  STATUS3[31] is set, when they no longer change. Only single-bit
  toggles cross between the clocks; the snapshot registers change only
  in answer to a request, so the AXI side reads them while they hold.
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
  wire :pad5, 5
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

  # ---- live status: request/ack snapshot, free-running cycle count
  wire :forever, 1
  wire :pbcyc, 32, init: 0
  wire :req_a, 1
  wire :req_s, 1
  wire :snap_ack, 1, init: 0
  wire :ack_s, 1
  wire :e0a, 32
  wire :e0b, 32
  wire :e0c, 32
  wire :e1a, 32
  wire :e1b, 32
  wire :e1c, 32
  wire :gst, 32
  wire :s_cyc, 32, init: 0
  wire :s_e0a, 32, init: 0
  wire :s_e0b, 32, init: 0
  wire :s_e0c, 32, init: 0
  wire :s_e1a, 32, init: 0
  wire :s_e1b, 32, init: 0
  wire :s_e1c, 32, init: 0
  wire :s_g, 32, init: 0
  wire :s_q, 32, init: 0

  # ---- host port: staging on axi_clk, one flit per toggle handshake
  wire :hs_lo, 24, init: 0
  wire :hs_hi, 12, init: 0
  wire :hs_len, 7, init: 0
  wire :hs_head, 1, init: 0
  wire :hs_kind, 4, init: 0
  wire :hs_deng, 4, init: 0
  wire :hin_req, 1, init: 0
  wire :hin_req_s, 1
  wire :hin_ack, 1, init: 0
  wire :hin_ack_s, 1
  wire :hin_go, 1
  wire :hin_word, 36
  wire :hin_ready, 1
  wire :hin_depth, 6
  wire :hout_req_a, 1
  wire :hout_req_s, 1
  wire :hout_ack, 1, init: 0
  wire :hout_ack_s, 1
  wire :hout_valid, 1
  wire :hout_head, 1
  wire :hout_kind, 4
  wire :hout_deng, 4
  wire :hout_word, 36
  wire :hout_len, 7
  wire :hout_pop, 1
  wire :hout_depth, 6
  wire :ho_v, 1, init: 0
  wire :ho_h, 1, init: 0
  wire :ho_k, 4, init: 0
  wire :ho_d, 4, init: 0
  wire :ho_l, 7, init: 0
  wire :ho_w, 36, init: 0
  wire :pad3, 3
  wire :pad11, 11
  wire :pad10, 10

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

  instance :req_sync, Hw.CDC.Sync2,
    clk_dst: :pb_clk,
    rst: :mm_zero,
    data_in: :req_a,
    data_out: :req_s

  instance :ack_sync, Hw.CDC.Sync2,
    clk_dst: :axi_clk,
    rst: :mm_zero,
    data_in: :snap_ack,
    data_out: :ack_s

  instance :hin_sync, Hw.CDC.Sync2,
    clk_dst: :pb_clk,
    rst: :mm_zero,
    data_in: :hin_req,
    data_out: :hin_req_s

  instance :hin_ack_sync, Hw.CDC.Sync2,
    clk_dst: :axi_clk,
    rst: :mm_zero,
    data_in: :hin_ack,
    data_out: :hin_ack_s

  instance :hout_sync, Hw.CDC.Sync2,
    clk_dst: :pb_clk,
    rst: :mm_zero,
    data_in: :hout_req_a,
    data_out: :hout_req_s

  instance :hout_ack_sync, Hw.CDC.Sync2,
    clk_dst: :axi_clk,
    rst: :mm_zero,
    data_in: :hout_ack,
    data_out: :hout_ack_s

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
    obs_flags: :flags,
    obs_e0a: :e0a,
    obs_e0b: :e0b,
    obs_e0c: :e0c,
    obs_e1a: :e1a,
    obs_e1b: :e1b,
    obs_e1c: :e1c,
    obs_g: :gst,
    hin_en: :hin_go,
    hin_head: :hs_head,
    hin_kind: :hs_kind,
    hin_deng: :hs_deng,
    hin_word: :hin_word,
    hin_len: :hs_len,
    hin_ready: :hin_ready,
    hin_depth: :hin_depth,
    hout_valid: :hout_valid,
    hout_head: :hout_head,
    hout_kind: :hout_kind,
    hout_deng: :hout_deng,
    hout_word: :hout_word,
    hout_len: :hout_len,
    hout_pop: :hout_pop,
    hout_depth: :hout_depth

  comb do
    rlast_tie = 1
    one = 1
    mm_zero = 0
    pad6 = 0
    pad5 = 0
    pad7 = 0
    req_a = ctrl1[5..5]
    hout_req_a = ctrl1[6..6]
    pad3 = 0
    pad11 = 0
    pad10 = 0
    hin_word = {hs_hi, hs_lo}
    hin_go = band(hin_req_s != hin_ack, hin_ready)
    hout_pop = band(hout_req_s != hout_ack, hout_valid)
    forever = ctrl3[31..16] == 0
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
    status2 = 0x0B5E0008
    status3 = {done_s, locked_s, ack_s, hin_ack_s, hout_ack_s, pad3, heartbeat}

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

    if band(img_wr_q, ctrl2[31..30] == 0) == 1 do
      img[ctrl2[10..0]] = ctrl2[23..16]
    end

    # host-in staging: the flit is complete, and stable, before the push
    # toggle that op 3 makes, and stays so until the ack comes back
    if band(img_wr_q, ctrl2[31..30] == 1) == 1 do
      hs_lo = ctrl2[23..0]
    end

    if band(img_wr_q, ctrl2[31..30] == 2) == 1 do
      hs_hi = ctrl2[11..0]
      hs_len = ctrl2[18..12]
    end

    if band(img_wr_q, ctrl2[31..30] == 3) == 1 do
      hs_head = ctrl2[0..0]
      hs_kind = ctrl2[4..1]
      hs_deng = ctrl2[8..5]
      hin_req = bnot(hin_req)
    end
  end

  # The memory window's address arrives a cycle before RVALID; register the
  # selection and the result word so they line up with the BRAM reads.
  on :axi_clk do
    sel_q = mem_raddr[11..10]

    if mem_raddr[3..0] == 0 do
      res_q = sig
    end

    if mem_raddr[3..0] == 1 do
      res_q = {pad6, cyc}
    end

    if mem_raddr[3..0] == 2 do
      res_q = {n1, n0}
    end

    if mem_raddr[3..0] == 3 do
      res_q = {heartbeat, flags_at_done, pad6[1..0], pdone, done}
    end

    if mem_raddr[3..0] == 4 do
      res_q = s_cyc
    end

    if mem_raddr[3..0] == 5 do
      res_q = s_g
    end

    if mem_raddr[3..0] == 6 do
      res_q = s_e0a
    end

    if mem_raddr[3..0] == 7 do
      res_q = s_e0b
    end

    if mem_raddr[3..0] == 8 do
      res_q = s_e0c
    end

    if mem_raddr[3..0] == 9 do
      res_q = s_e1a
    end

    if mem_raddr[3..0] == 10 do
      res_q = s_e1b
    end

    if mem_raddr[3..0] == 11 do
      res_q = s_e1c
    end

    if mem_raddr[3..0] == 12 do
      res_q = {ho_v, ho_h, ho_k, ho_d, ho_l, pad11, ho_w[35..32]}
    end

    if mem_raddr[3..0] == 13 do
      res_q = ho_w[31..0]
    end

    if mem_raddr[3..0] == 14 do
      res_q = s_q
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

        if cyc + 1 == win and forever == 0 do
          done = 1
          flags_at_done = flags
        end
      end
    end
  end

  # ---- pb_clk: live status. The request is a toggle; a new value is
  # answered by one copy and the matching ack, and the copies then hold
  # until the next toggle. Runs whether or not the core is released, so a
  # stopped machine still answers (with its reset values).
  on :pb_clk do
    if go == 0 do
      pbcyc = 0
    else
      pbcyc = pbcyc + 1
    end

    if req_s != snap_ack do
      snap_ack = req_s
      s_cyc = pbcyc
      s_g = gst
      s_e0a = e0a
      s_e0b = e0b
      s_e0c = e0c
      s_e1a = e1a
      s_e1b = e1b
      s_e1c = e1c
      s_q = {pad10, hin_depth, pad10, hout_depth}
    end

    # host-in: one push per toggle, when the queue has room
    if hin_go == 1 do
      hin_ack = hin_req_s
    end

    # host-out: one pop (or an empty answer) per toggle
    if hout_req_s != hout_ack do
      hout_ack = hout_req_s
      ho_v = hout_valid
      ho_h = hout_head
      ho_k = hout_kind
      ho_d = hout_deng
      ho_l = hout_len
      ho_w = hout_word
    end
  end
end
