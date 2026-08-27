defmodule PicoBEAM.RTL.Ulx3sTop do
  @moduledoc """
  The MVP board top: picoBEAM boots from microSD on a real ULX3S.

      25 MHz osc ─▶ PLL (CLKOS = 432/36 = 12 MHz exact) ─▶ everything
      SdBoot ── SPI ──▶ microSD (raw image at LBA 8192)
             └─ side-door ──▶ Engine (held in reset until done)

  12 MHz is deliberate: the calibration log puts the un-barreled
  engine's fmax at ~24–31 MHz, so half that is comfortable margin for
  first silicon. The barrel (M3) is the timing fix; this top is the
  proof-of-boot, not the speed run.

  ## Pins (see `priv/ulx3s_pb.lpf` — picobeam's own minimal LPF)

      led[7:0]   while loading: {busy, err[2:0], state_dbg[3:0]}
                 after boot:    the program's `out` byte
                 (fib(10) = 55 = 0b0011_0111)
      btn[1]     (FIRE1) hold to re-run the whole boot
      sd_*       SPI mode: sd_clk, sd_cmd = MOSI, sd_d0 = MISO,
                 sd_d3 = CS_n; d1/d2 untouched (card pullups)
      wifi_gpio0 driven 1 — keeps the ESP32 from resetting the board

  Status legibility on error: `led = 1_eee_ssss` frozen with the error
  code and the loader state that died.
  """

  use Hw.Component

  clock :clk_25mhz, freq: 25.0

  input :btn1, 1
  # FIRE2: hold to show the last byte the card sent (debug view)
  input :btn2, 1
  input :sd_d0, 1

  output :sd_clk, 1
  output :sd_cmd, 1
  output :sd_d3, 1
  # SPI mode: DAT1/DAT2 held high (d2 has NO board pullup), and the
  # ESP32 held in RESET — the microSD lines are shared with its GPIO
  # 12–15, and stock ESP32 firmware mounts the card at boot and wrecks
  # the FPGA's SPI conversation (observed on first silicon as error 1:
  # CMD0 answered by nothing but 0xFF).
  output :sd_d1, 1
  output :sd_d2, 1
  output :wifi_en, 1
  output :led, 8
  output :wifi_gpio0, 1
  # debug UART to the FTDI (the board's "ftdi_rxd" is FPGA->host)
  output :ftdi_rxd, 1

  wire :clk_48, 1
  wire :clk_12, 1
  wire :pll_locked, 1

  wire :boot_rst, 1
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

  wire :eng_rst, 1
  wire :eng_out_v, 1
  wire :eng_out, 36
  wire :eng_halt, 1
  wire :eng_fault, 1
  wire :eng_fr, 8
  wire :eng_pc, 9

  wire :led_r, 8, init: 0
  wire :out_seen, 1, init: 0
  wire :out_l, 16, init: 0
  # top-side oracle probes: does eng_out_v pulse HERE, and does the
  # unconditional latch capture the value?
  wire :tcnt, 4, init: 0
  wire :tcn2, 4, init: 0
  wire :tvo, 8, init: 0
  wire :dbg_flags, 4
  wire :eng_sst, 4
  wire :eng_rdy, 1
  wire :eng_fp, 6
  wire :eng_rt1, 9
  wire :eng_rt2, 9
  wire :eng_rcnt, 4
  wire :eng_rtl, 9
  wire :eng_ocnt, 4
  wire :eng_lrv, 8
  wire :eng_fnz, 4
  wire :eng_snz, 4
  wire :eng_frv, 8
  wire :eng_rvnz, 4
  # 1 Hz-ish blink divider: the pc-view blinks, the out-view is steady,
  # so the two are distinguishable at a glance
  wire :blink, 23, init: 0

  comb do
    wifi_gpio0 = 1
    wifi_en = 0
    sd_d1 = 1
    sd_d2 = 1
    boot_rst = bor(btn1, bnot(pll_locked))
    eng_rst = bor(boot_rst, bnot(sd_done))
    led = led_r
    dbg_flags = eng_halt * 8 + eng_fault * 4 + eng_rdy * 2 + out_seen
  end

  on :clk_12 do
    blink = blink + 1

    # unconditional top-side observers of the engine's out pulse
    if eng_out_v == 1 do
      tvo = eng_out[7..0]

      if tcnt != 15 do
        tcnt = tcnt + 1
      end

      if sd_done == 1 do
        if tcn2 != 15 do
          tcn2 = tcn2 + 1
        end
      end
    end

    if btn2 == 1 do
      # debug view: before boot completes, the last byte the card sent;
      # after, the engine's fault reason (reserved-atom index)
      led_r = bor(sd_done, 0) * eng_fr + bnot(sd_done) * sd_lrx
      out_seen = 0
    else
      if sd_done == 1 do
        if eng_out_v == 1 do
          # the program spoke: show its byte, sticky
          led_r = eng_out[7..0]
          out_l = eng_out[15..0]
          out_seen = 1
        else
          if out_seen == 0 do
            # engine running/dead without output: {halt, fault, pc[5:0]},
            # BLINKING — a steady display always means the out byte
            led_r = blink[22] * (eng_halt * 128 + eng_fault * 64 + eng_pc[5..0])
          end
        end
      else
        # bit7: busy while loading, LIVE MISO LEVEL once frozen in error
        led_r = bor(sd_busy, sd_d0) * 128 + sd_err * 16 + sd_state
      end
    end
  end

  instance :pll, ULX3S.PLL,
    CLKOP_DIV: 9,
    CLKOS_DIV: 36,
    CLKOP_CPHASE: 8,
    CLKOS_CPHASE: 35,
    clk_in: :clk_25mhz,
    clk_out0: :clk_48,
    clk_out1: :clk_12,
    locked: :pll_locked,
    phase_dir: 0,
    phase_step: 0

  instance :sd, PicoBEAM.RTL.SdBoot,
    LBA: 8192,
    clk: :clk_12,
    rst: :boot_rst,
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
    busy: :sd_busy,
    done: :sd_done,
    err: :sd_err,
    state_dbg: :sd_state,
    last_rx: :sd_lrx

  instance :engine, PicoBEAM.RTL.Engine,
    clk: :clk_12,
    rst: :eng_rst,
    ld_code_en: :sd_ce,
    ld_code_addr: :sd_ca,
    ld_code_data: :sd_cd,
    ld_pool_en: :sd_pe,
    ld_pool_addr: :sd_pa,
    ld_pool_data: :sd_pd,
    out_valid: :eng_out_v,
    out_data: :eng_out,
    halted: :eng_halt,
    faulted: :eng_fault,
    fault_reason: :eng_fr,
    pc_dbg: :eng_pc,
    dbg_state: :eng_sst,
    dbg_ready: :eng_rdy,
    dbg_fp: :eng_fp,
    dbg_rt1: :eng_rt1,
    dbg_rt2: :eng_rt2,
    dbg_rcnt: :eng_rcnt,
    dbg_rtl: :eng_rtl,
    dbg_ocnt: :eng_ocnt,
    dbg_lrv: :eng_lrv,
    dbg_fnz: :eng_fnz,
    dbg_snz: :eng_snz,
    dbg_frv: :eng_frv,
    dbg_rvnz: :eng_rvnz

  instance :dbg, PicoBEAM.RTL.DbgUart,
    clk: :clk_12,
    rst: :boot_rst,
    pc: :eng_pc,
    sstate: :eng_sst,
    flags: :dbg_flags,
    fr: :eng_fr,
    outv: :eng_lrv,
    fp: :eng_rvnz,
    sdst: :eng_snz,
    rt1: :eng_rt1,
    rt2: :eng_rt2,
    rcnt: :eng_rcnt,
    rtl: :eng_rtl,
    ocnt: :eng_ocnt,
    txd: :ftdi_rxd
end
