defmodule PicoBEAM.RTL.M5Core do
  @moduledoc """
  Two engines, one ring, booting Elixir off a microSD card — everything
  the board top has except the pins and the PLL.

      SdBoot ── SPI ──▶ microSD (.pbi v2 at LBA 8192)
             └─ side-door ──┬──▶ Engine 0 ──┐
                            └──▶ Engine 1 ──┤
                                            ├─ RingLink 0→1
                                            └─ RingLink 1→0
                                 halt sideband across both

  This is the first board top with more than one engine on it, and the
  first that boots a program the Elixir compiler produced.

  ## One image, two entry points

  Both engines are loaded from the SAME side-door stream — one card
  read, two identical code memories — and started at the two entry
  points the image's header carries (`notes/36`). That is the whole
  reason the header grew them: with one engine, `boot_pc` can be a
  bitstream constant; with two, where each engine starts is a property
  of the PROGRAM, and a bitstream rebuild costs twenty minutes of
  place-and-route while writing a card costs seconds.

  `entry1 = 0x1FF` means "do not boot engine 1", so a single-engine
  image runs on this bitstream unchanged.

  ## What is and is not proven here

  Both engines execute independently out of one loader, and the ring is
  wired between them with the halt sideband across both. Cross-engine
  SPAWN and cross-engine SIGNALS are still unbuilt (`notes/29`), so the
  demo image gives each engine its own work rather than pretending
  otherwise; `tb_ring2` is where a message actually crosses.

  ## The LEDs are two combs

      while loading   {busy, err[2:0], state_dbg[3:0]}
      after boot      led[3:0] = engine 0's per-seat retire strobes
                      led[7:4] = engine 1's

  Each nibble is the 1/T comb `notes/18` describes — four dim, equal
  glows to the eye, four square waves 90° apart on a scope. Two nibbles
  doing it at once is what two engines look like.

  ## Ports

      rst         hold to re-run the whole boot, card and all
      btn2        hold to show the last `out` byte on the LEDs
      sd_*        SPI mode: sd_clk, sd_cmd = MOSI, sd_d0 = MISO,
                  sd_d3 = CS_n; d1/d2 driven high (d2 has no board
                  pullup). The board top is what holds the ESP32 in
                  reset — the microSD lines are shared with its GPIO
                  12–15 and stock firmware mounts the card at boot,
                  which wrecks the FPGA's SPI conversation (`Ulx3sTop`
                  learned that on first silicon as error 1: CMD0
                  answered by nothing but 0xFF).
      ftdi_rxd    the debug UART, 115200 8N1
  """

  use Hw.Component

  # The loader's two timing constants, lifted to the TOP so a simulation
  # wrapper can instantiate this whole board with a short power-up wait
  # and a fast SPI clock. EHDL folds params at elaboration, so an
  # override has to happen on an `instance` — which means the only way
  # to simulate a board top is for something to instantiate it
  # (`Ulx3sM5TopSim`, and `notes/34` for why).
  param :PWRWAIT, default: 1_200_000
  param :HALF, default: 16
  # clocks per UART bit: 104 is 115200 at 12 MHz
  param :UDIV, default: 104

  # The clock is a PORT, and the PLL that makes it lives in the board
  # top. That is not tidiness: EHDL promotes an INTERNAL clock to a port
  # when the component is flattened into another one, so a core whose
  # 12 MHz came from a PLL inside it could not be instantiated by a
  # simulation wrapper without the wrapper sprouting a `clk_12` input
  # that nothing drove — two nets with the same idea and no connection
  # between them, which simulates as a design that never clocks.
  clock :clk_12, freq: 12.0

  input :rst, 1
  input :btn2, 1
  input :sd_d0, 1
  # the debug cable's other direction. Push a `.pbi` at it and the board
  # reboots into it without touching the card (`notes/37`).
  input :ftdi_txd, 1

  output :sd_clk, 1
  output :sd_cmd, 1
  output :sd_d1, 1
  output :sd_d2, 1
  output :sd_d3, 1
  output :led, 8
  output :ftdi_rxd, 1

  # ---- the loader
  wire :sd_busy, 1
  wire :sd_done, 1
  wire :sd_err, 3
  wire :sd_state, 4
  wire :sd_lrx, 8
  wire :sd_ce, 1
  wire :sd_ca, 9
  wire :sd_cd, 72
  wire :sd_pe, 1
  wire :sd_pa, 8
  wire :sd_pd, 36
  wire :sd_e0, 9
  wire :sd_e1, 9

  # ---- boot: 0 loading · 1 settle · 2 pulse boot_en · 3 running
  wire :bst, 2, init: 0
  wire :settle, 4, init: 0
  wire :eng_rst, 1
  wire :boot0, 1
  wire :boot1, 1
  # which loader the running image came from. The card wins at power-up
  # because it is the only one with anything to say; the wire wins
  # afterwards, because someone had to be there to push.
  wire :from_uart, 1, init: 0
  wire :wrote_r, 1, init: 0
  wire :ld_ce, 1
  wire :ld_ca, 9
  wire :ld_cd, 72
  wire :ld_pe, 1
  wire :ld_pa, 8
  wire :ld_pd, 36
  wire :ent0, 9
  wire :ent1, 9

  # ---- the UART loader
  wire :ul_ce, 1
  wire :ul_ca, 9
  wire :ul_cd, 72
  wire :ul_pe, 1
  wire :ul_pa, 8
  wire :ul_pd, 36
  wire :ul_e0, 9
  wire :ul_e1, 9
  wire :ul_done, 1
  wire :ul_recv, 1
  wire :ul_store, 1
  wire :ul_sidx, 13
  wire :ul_sbyte, 8
  wire :ul_len, 13
  wire :sd_wbusy, 1
  wire :sd_wdone, 1
  wire :sd_werr, 1

  # ---- engine 0
  wire :ov0, 1
  wire :od0, 36
  wire :idle0, 1
  wire :flt0, 1
  wire :fr0, 8
  wire :fs0, 5
  wire :fc0, 8
  wire :occ0, 6
  wire :qc0, 6
  wire :sw0, 8
  wire :sp0, 12
  wire :dt0, 12
  wire :xs0, 2
  wire :xe0, 1
  wire :pc0, 9
  wire :s00, 5
  wire :s01, 5
  wire :s02, 5
  wire :s03, 5
  wire :nm0_qn, 16
  wire :nm0_qh, 1
  wire :nm0_qe, 4
  wire :nm0_qs, 5
  wire :nm0_qr, 22
  wire :nm0_we, 4
  wire :nm0_ws, 5
  wire :nm0_wr, 22
  wire :nm0_wen, 1
  wire :nm0_tk, 1
  wire :nm0_pt, 1
  wire :nm0_fl, 1
  wire :nm0_clr, 1
  wire :nm0_die, 1
  wire :nm0_dpid, 36
  wire :nm0_dslot, 5
  wire :nm0_dser, 22
  wire :nm0_ps, 5
  wire :nm0_pst, 2
  wire :nm0_pser, 22
  wire :nm1_qn, 16
  wire :nm1_qh, 1
  wire :nm1_qe, 4
  wire :nm1_qs, 5
  wire :nm1_qr, 22
  wire :nm1_we, 4
  wire :nm1_ws, 5
  wire :nm1_wr, 22
  wire :nm1_wen, 1
  wire :nm1_tk, 1
  wire :nm1_pt, 1
  wire :nm1_fl, 1
  wire :nm1_clr, 1
  wire :nm1_die, 1
  wire :nm1_dpid, 36
  wire :nm1_dslot, 5
  wire :nm1_dser, 22
  wire :nm1_ps, 5
  wire :nm1_pst, 2
  wire :nm1_pser, 22
  wire :h0, 1

  # ---- engine 1
  wire :ov1, 1
  wire :od1, 36
  wire :idle1, 1
  wire :flt1, 1
  wire :fr1, 8
  wire :fs1, 5
  wire :fc1, 8
  wire :occ1, 6
  wire :qc1, 6
  wire :sw1, 8
  wire :sp1, 12
  wire :dt1, 12
  wire :xs1, 2
  wire :xe1, 1
  wire :pc1, 9
  wire :s10, 5
  wire :s11, 5
  wire :s12, 5
  wire :s13, 5
  wire :h1, 1

  wire :vm_halt, 1

  # ---- the ring: 0 → 1 on link A, 1 → 0 on link B
  wire :a_en, 1
  wire :a_head, 1
  wire :a_kind, 4
  wire :a_deng, 4
  wire :a_word, 36
  wire :a_len, 7
  wire :a_ready, 1
  wire :a_valid, 1
  wire :a_rhead, 1
  wire :a_rkind, 4
  wire :a_rdeng, 4
  wire :a_rword, 36
  wire :a_rlen, 7
  wire :a_pop, 1
  wire :a_depth, 6

  wire :b_en, 1
  wire :b_head, 1
  wire :b_kind, 4
  wire :b_deng, 4
  wire :b_word, 36
  wire :b_len, 7
  wire :b_ready, 1
  wire :b_valid, 1
  wire :b_rhead, 1
  wire :b_rkind, 4
  wire :b_rdeng, 4
  wire :b_rword, 36
  wire :b_rlen, 7
  wire :b_pop, 1
  wire :b_depth, 6

  # ---- instrument
  wire :act0, 4
  wire :act1, 4
  wire :led_r, 8, init: 0
  wire :out_l, 16, init: 0
  wire :out_seen, 1, init: 0
  wire :dbg_flags, 4
  wire :occ_both, 8
  wire :qc4, 4
  wire :deaths_both, 12
  wire :fault_any, 1
  wire :idle_both, 1
  wire :fcnt_both, 8
  # {card-write busy, done, error} and whether the running image came
  # off the wire — one nibble on the debug line, which is where you look
  # when you have just pushed something
  wire :wr_nib, 4

  comb do
    sd_d1 = 1
    sd_d2 = 1

    # in reset until an image is in and the settle has run. `bst == 0`
    # covers the card at power-up and a program arriving over the wire
    # afterwards — either way the engines are holding still while their
    # code memories are written under them.
    eng_rst = bor(rst, bst == 0)
    nm0_dslot = nm0_dpid[26..22]
    nm0_dser = nm0_dpid[21..0]
    nm1_dslot = nm1_dpid[26..22]
    nm1_dser = nm1_dpid[21..0]

    # the two loaders share the side door. They cannot both be talking:
    # the card is finished before the wire can start, and the wire holds
    # `bst` at 0 while it works.
    ld_ce = bor(sd_ce, ul_ce)
    ld_ca = ul_ce * ul_ca + band(bnot(ul_ce), 1) * sd_ca
    ld_cd = ul_ce * ul_cd + band(bnot(ul_ce), 1) * sd_cd
    ld_pe = bor(sd_pe, ul_pe)
    ld_pa = ul_pe * ul_pa + band(bnot(ul_pe), 1) * sd_pa
    ld_pd = ul_pe * ul_pd + band(bnot(ul_pe), 1) * sd_pd

    ent0 = from_uart * ul_e0 + band(bnot(from_uart), 1) * sd_e0
    ent1 = from_uart * ul_e1 + band(bnot(from_uart), 1) * sd_e1

    # one pulse each, at the same turn, with the entry points the image
    # carried. `0x1FF` is the header's "leave this engine alone".
    boot0 = band(bst == 2, ent0 != 511)
    boot1 = band(bst == 2, ent1 != 511)

    # a halt anywhere stops the VM, and the VM is both engines
    vm_halt = bor(h0, h1)

    act0 =
      band(xe0, xs0 == 0) * 1 + band(xe0, xs0 == 1) * 2 +
        band(xe0, xs0 == 2) * 4 + band(xe0, xs0 == 3) * 8

    act1 =
      band(xe1, xs1 == 0) * 1 + band(xe1, xs1 == 1) * 2 +
        band(xe1, xs1 == 2) * 4 + band(xe1, xs1 == 3) * 8

    led = led_r

    idle_both = band(idle0, idle1)
    fault_any = bor(flt0, flt1)
    dbg_flags = idle_both * 8 + fault_any * 4 + xe0 * 2 + out_seen
    # both occupancies in one byte, one hex digit each
    occ_both = occ0[3..0] * 16 + occ1[3..0]
    qc4 = qc0[3..0]
    deaths_both = dt0 + dt1
    fcnt_both = fc0 + fc1
    wr_nib = sd_wbusy * 8 + wrote_r * 4 + sd_werr * 2 + from_uart
  end

  on :clk_12 do
    if rst == 1 do
      bst = 0
      settle = 0
      out_seen = 0
      out_l = 0
      led_r = 0
      from_uart = 0
      wrote_r = 0
    else
      if bst == 0 do
        # the card owns the machine until it says otherwise
        if sd_done == 1 do
          bst = 1
          settle = 0
        end
      end

      # ...and after that, so does anyone with the cable. A program
      # arriving is a program about to replace the one that is running,
      # so the engines go back into reset for as long as it takes.
      if ul_recv == 1 do
        bst = 0
      end

      if sd_wdone == 1 do
        wrote_r = 1
      end

      if ul_done == 1 do
        from_uart = 1
        wrote_r = 0
        bst = 1
        settle = 0
      end

      if bst == 1 do
        # let the loader's last side-door write land before the engines
        # come out of reset and start fetching
        if settle == 7 do
          bst = 2
        else
          settle = settle + 1
        end
      end

      if bst == 2 do
        bst = 3
      end

      # either engine's `out` is the machine's out; they interleave, and
      # the UART line is a status view rather than a transcript
      if ov0 == 1 do
        out_l = od0[15..0]
        out_seen = 1
      end

      if ov1 == 1 do
        out_l = od1[15..0]
        out_seen = 1
      end

      # while the card is talking, the LEDs are the loader's status; once
      # the engines are running they are two combs, one nibble each
      if sd_done == 0 do
        led_r = 128 + sd_err * 16 + sd_state
      else
        if btn2 == 1 do
          led_r = out_l[7..0]
        else
          led_r = act1 * 16 + act0
        end
      end
    end
  end

  # `:loader`, not `:sd` — EHDL flattens an instance's internals under
  # its name, and `SdBoot` has an `lrx` and this top has an `sd_lrx`, so
  # an instance called `sd` collides with the wires that carry its own
  # outputs. It is invisible one level deep and a duplicate declaration
  # two levels deep, which is where `Ulx3sM5TopSim` found it.
  instance :loader, PicoBEAM.RTL.SdBoot,
    PWRWAIT: PWRWAIT,
    HALF: HALF,
    clk: :clk_12,
    rst: :rst,
    miso: :sd_d0,
    sck: :sd_clk,
    mosi: :sd_cmd,
    cs_n: :sd_d3,
    code_en: :sd_ce,
    code_addr: :sd_ca,
    code_data: :sd_cd,
    pool_en: :sd_pe,
    pool_addr: :sd_pa,
    pool_data: :sd_pd,
    entry0: :sd_e0,
    entry1: :sd_e1,
    # a pushed image writes THROUGH to the card, so it survives a power
    # cycle (`notes/38`). It happens after the engines have already
    # rebooted into it — the side door got there first — so nothing
    # waits on the card.
    wr_en: :ul_store,
    wr_byte: :ul_sbyte,
    wr_idx: :ul_sidx,
    wr_go: :ul_done,
    wr_len: :ul_len,
    wr_busy: :sd_wbusy,
    wr_done: :sd_wdone,
    wr_err: :sd_werr,
    busy: :sd_busy,
    done: :sd_done,
    err: :sd_err,
    state_dbg: :sd_state,
    last_rx: :sd_lrx

  # `notes/53` — the node registry (see Duo for the full argument)
  instance :names, PicoBEAM.RTL.NameTable,
    clk: :clk_12,
    rst: :eng_rst,
    q_name: :nm0_qn,
    q_hit: :nm0_qh,
    q_eng: :nm0_qe,
    q_slot: :nm0_qs,
    q_serial: :nm0_qr,
    w_name: :nm0_qn,
    w_eng: :nm0_we,
    w_slot: :nm0_ws,
    w_serial: :nm0_wr,
    w_en: :nm0_wen,
    name_taken: :nm0_tk,
    pid_taken: :nm0_pt,
    table_full: :nm0_fl,
    clr_en: :nm0_clr,
    clr_name: :nm0_qn,
    die_en: :nm0_die,
    die_eng: 0,
    die_slot: :nm0_dslot,
    die_serial: :nm0_dser,
    q2_name: :nm1_qn,
    q2_hit: :nm1_qh,
    q2_eng: :nm1_qe,
    q2_slot: :nm1_qs,
    q2_serial: :nm1_qr,
    w2_name: :nm1_qn,
    w2_eng: :nm1_we,
    w2_slot: :nm1_ws,
    w2_serial: :nm1_wr,
    w2_en: :nm1_wen,
    name_taken2: :nm1_tk,
    pid_taken2: :nm1_pt,
    table_full2: :nm1_fl,
    clr2_en: :nm1_clr,
    clr2_name: :nm1_qn,
    die2_en: :nm1_die,
    die2_eng: 1,
    die2_slot: :nm1_dslot,
    die2_serial: :nm1_dser

  instance :link_ab, PicoBEAM.RTL.RingLink,
    clk: :clk_12,
    rst: :rst,
    w_en: :a_en,
    w_head: :a_head,
    w_kind: :a_kind,
    w_deng: :a_deng,
    w_word: :a_word,
    w_len: :a_len,
    w_ready: :a_ready,
    r_valid: :a_valid,
    r_head: :a_rhead,
    r_kind: :a_rkind,
    r_deng: :a_rdeng,
    r_word: :a_rword,
    r_len: :a_rlen,
    r_pop: :a_pop,
    depth: :a_depth

  instance :link_ba, PicoBEAM.RTL.RingLink,
    clk: :clk_12,
    rst: :rst,
    w_en: :b_en,
    w_head: :b_head,
    w_kind: :b_kind,
    w_deng: :b_deng,
    w_word: :b_word,
    w_len: :b_len,
    w_ready: :b_ready,
    r_valid: :b_valid,
    r_head: :b_rhead,
    r_kind: :b_rkind,
    r_deng: :b_rdeng,
    r_word: :b_rword,
    r_len: :b_rlen,
    r_pop: :b_pop,
    depth: :b_depth

  instance :eng0, PicoBEAM.RTL.BarrelEngine,
    N_ENG: 2,
    clk: :clk_12,
    rst: :eng_rst,
    eng_id: 0,
    ld_code_en: :ld_ce,
    ld_code_addr: :ld_ca,
    ld_code_data: :ld_cd,
    ld_pool_en: :ld_pe,
    ld_pool_addr: :ld_pa,
    ld_pool_data: :ld_pd,
    boot_en: :boot0,
    boot_pc: :ent0,
    ring_w_en: :a_en,
    ring_w_head: :a_head,
    ring_w_kind: :a_kind,
    ring_w_deng: :a_deng,
    ring_w_word: :a_word,
    ring_w_len: :a_len,
    ring_w_ready: :a_ready,
    ring_r_valid: :b_valid,
    ring_r_head: :b_rhead,
    ring_r_kind: :b_rkind,
    ring_r_deng: :b_rdeng,
    ring_r_word: :b_rword,
    ring_r_len: :b_rlen,
    ring_r_pop: :b_pop,
    nm_q_name: :nm0_qn,
    nm_q_hit: :nm0_qh,
    nm_q_eng: :nm0_qe,
    nm_q_slot: :nm0_qs,
    nm_q_serial: :nm0_qr,
    nm_name_taken: :nm0_tk,
    nm_pid_taken: :nm0_pt,
    nm_full: :nm0_fl,
    nm_w_en: :nm0_wen,
    nm_w_eng: :nm0_we,
    nm_w_slot: :nm0_ws,
    nm_w_serial: :nm0_wr,
    nm_clr_en: :nm0_clr,
    nm_die: :nm0_die,
    nm_die_pid: :nm0_dpid,
    nm_probe_slot: :nm0_ps,
    nm_probe_state: :nm0_pst,
    nm_probe_serial: :nm0_pser,
    peer_probe_slot: :nm1_ps,
    peer_probe_state: :nm1_pst,
    peer_probe_serial: :nm1_pser,
    halt_in: :vm_halt,
    halt_req: :h0,
    out_valid: :ov0,
    out_data: :od0,
    idle: :idle0,
    faulted: :flt0,
    fault_reason: :fr0,
    fault_slot: :fs0,
    fault_count: :fc0,
    dbg_occ: :occ0,
    dbg_qcount: :qc0,
    dbg_swaps: :sw0,
    dbg_spawns: :sp0,
    dbg_deaths: :dt0,
    dbg_x_seat: :xs0,
    dbg_x_en: :xe0,
    dbg_pc: :pc0,
    dbg_st0: :s00,
    dbg_st1: :s01,
    dbg_st2: :s02,
    dbg_st3: :s03

  instance :eng1, PicoBEAM.RTL.BarrelEngine,
    N_ENG: 2,
    clk: :clk_12,
    rst: :eng_rst,
    eng_id: 1,
    ld_code_en: :ld_ce,
    ld_code_addr: :ld_ca,
    ld_code_data: :ld_cd,
    ld_pool_en: :ld_pe,
    ld_pool_addr: :ld_pa,
    ld_pool_data: :ld_pd,
    boot_en: :boot1,
    boot_pc: :ent1,
    ring_w_en: :b_en,
    ring_w_head: :b_head,
    ring_w_kind: :b_kind,
    ring_w_deng: :b_deng,
    ring_w_word: :b_word,
    ring_w_len: :b_len,
    ring_w_ready: :b_ready,
    ring_r_valid: :a_valid,
    ring_r_head: :a_rhead,
    ring_r_kind: :a_rkind,
    ring_r_deng: :a_rdeng,
    ring_r_word: :a_rword,
    ring_r_len: :a_rlen,
    ring_r_pop: :a_pop,
    nm_q_name: :nm1_qn,
    nm_q_hit: :nm1_qh,
    nm_q_eng: :nm1_qe,
    nm_q_slot: :nm1_qs,
    nm_q_serial: :nm1_qr,
    nm_name_taken: :nm1_tk,
    nm_pid_taken: :nm1_pt,
    nm_full: :nm1_fl,
    nm_w_en: :nm1_wen,
    nm_w_eng: :nm1_we,
    nm_w_slot: :nm1_ws,
    nm_w_serial: :nm1_wr,
    nm_clr_en: :nm1_clr,
    nm_die: :nm1_die,
    nm_die_pid: :nm1_dpid,
    nm_probe_slot: :nm1_ps,
    nm_probe_state: :nm1_pst,
    nm_probe_serial: :nm1_pser,
    peer_probe_slot: :nm0_ps,
    peer_probe_state: :nm0_pst,
    peer_probe_serial: :nm0_pser,
    halt_in: :vm_halt,
    halt_req: :h1,
    out_valid: :ov1,
    out_data: :od1,
    idle: :idle1,
    faulted: :flt1,
    fault_reason: :fr1,
    fault_slot: :fs1,
    fault_count: :fc1,
    dbg_occ: :occ1,
    dbg_qcount: :qc1,
    dbg_swaps: :sw1,
    dbg_spawns: :sp1,
    dbg_deaths: :dt1,
    dbg_x_seat: :xs1,
    dbg_x_en: :xe1,
    dbg_pc: :pc1,
    dbg_st0: :s10,
    dbg_st1: :s11,
    dbg_st2: :s12,
    dbg_st3: :s13

  instance :ul, PicoBEAM.RTL.UartLoader,
    DIV: UDIV,
    clk: :clk_12,
    rst: :rst,
    rx: :ftdi_txd,
    code_en: :ul_ce,
    code_addr: :ul_ca,
    code_data: :ul_cd,
    pool_en: :ul_pe,
    pool_addr: :ul_pa,
    pool_data: :ul_pd,
    entry0: :ul_e0,
    entry1: :ul_e1,
    img_done: :ul_done,
    receiving: :ul_recv,
    store_en: :ul_store,
    store_idx: :ul_sidx,
    store_byte: :ul_sbyte,
    img_len: :ul_len

  instance :dbg, PicoBEAM.RTL.DbgUart,
    clk: :clk_12,
    rst: :rst,
    pc: :pc0,
    sstate: :s00,
    flags: :dbg_flags,
    fr: :occ_both,
    outv: :out_l,
    fp: :sd_state,
    sdst: :s10,
    rt1: :sp0,
    rt2: 0,
    rcnt: :qc4,
    rtl: :deaths_both,
    ocnt: :wr_nib,
    frr: :fr0,
    fcnt: :fcnt_both,
    txd: :ftdi_rxd
end
