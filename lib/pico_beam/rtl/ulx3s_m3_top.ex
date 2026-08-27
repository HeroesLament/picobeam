defmodule PicoBEAM.RTL.Ulx3sM3Top do
  @moduledoc """
  M3 exit demo on the ULX3S: `DemoSpawn` running on the barrel engine.

      25 MHz osc ─▶ PLL (CLKOS = 432/36 = 12 MHz exact)
      ROM ── loader side-door ──▶ BarrelEngine ──▶ LEDs + debug UART

  The image is baked into a ROM rather than read from microSD: M2 proved
  the SD path, and a ROM keeps the build→flash→observe loop to a single
  `fujprog` with no card handling. (`SdBoot` drops back in unchanged
  when the image outgrows the ROM — the side-door contract is identical.)

  ## The LEDs are an instrument, not a status light

  `led[3:0]` carry the RAW per-seat execute strobes — seat k's LED is
  high exactly on the cycles seat k retires a bundle. At 12 MHz with
  T = 4 that is a 3 MHz square wave per seat, 90° apart: **the 1/T comb,
  directly on a scope**, which is the M3 exit demo's evidence. To the
  naked eye they are simply four dim, equal glows — which is itself the
  fairness claim, visible without instruments.

  `led[7:4]` show the spawn count climbing; in demo A, hold FIRE2 after
  boot to swap in the last `out` byte instead. In demo B the LEDs always
  show the comb — FIRE2 is held there to select the demo, so it cannot
  also mean "change the view".

  ## Two demos, one bitstream

  Hold FIRE2 while the ROM loads (i.e. through a FIRE1 reset) and the
  root starts at demo B, the six-spinner comb; release it and you get
  demo A, a thousand spawns. They need different programs because they
  prove different things: A proves the machine creates and reaps a
  thousand processes without leaking a slot, B keeps four seats
  saturated so the rotation is visible on a scope.

  ## The UART oracle, re-aimed at the barrel

      pPPP S F RR AAA LLL C O OO WD

      PPP  pc in X            AAA  spawns so far (12 bits)
      S    seat 0 state       LLL  deaths so far (12 bits)
      F    {idle,fault,       C    run-queue depth
            x_en,out_seen}    O    seat 2 state
      RR   proc-table         OO   last out byte
           occupancy          W    seat 1 state
                              D    seat 3 state

  `AAA` and `LLL` racing each other up to 3e8 (1000) IS the demo: the
  root creating processes as fast as the machine reaps them.

  Watching all four seat states at once is what makes a barrel
  debuggable: a wedged context shows up as a state that stops changing
  while the others rotate.
  """

  use Hw.Component

  @spawn_count 1000

  @asm PicoBEAM.Asm.assemble(%{
         # ---- A: a thousand spawns -------------------------------------
         # The root creates @spawn_count processes, each of which does
         # nothing but die. The delay loop between spawns is load-bearing:
         # a 32-slot proc table plus a ~17-turn seat-in makes reaping
         # slower than spawning, and an unthrottled root fills the table
         # and takes `:system_limit` on itself. Backpressure is the
         # PROGRAM's job — mechanism in gates, policy in code (notes/13).
         main:
           {0,
            [
              [{:ldi, 1, @spawn_count}],
              [{:ldi, 3, 1}],
              [{:ldi, 5, 0}],
              :loop,
              [{:arg, 0, 1}],
              [{:spawn, 2, :worker, 1}],
              [{:sub, 1, 1, 3}],
              [{:cmpeq, 4, 1, 5}],
              [{:bift, 4, :done}],
              [{:ldi, 6, 12}],
              :delay,
              [{:sub, 6, 6, 3}],
              [{:cmpeq, 7, 6, 5}],
              [{:biff, 7, :delay}],
              [{:jmp, :loop}],
              :done,
              [{:ldi, 8, 85}],
              [{:out, 8}],
              [{:halt}]
            ]},
         worker: {1, [[{:halt}]]},

         # ---- B: the 1/T comb ------------------------------------------
         # Six workers that never exit: four seats stay permanently
         # occupied and two processes stay permanently queued, so the
         # rotation runs under sustained load and the seat LEDs carry a
         # clean comb. Demo A cannot show this — with only a root and one
         # worker alive at a time, the rotation phase-locks onto two
         # seats and the other two idle, which is the barrel's honest
         # behaviour under low process count, not a fault.
         combmain:
           {0,
            [
              [{:ldi, 1, 6}],
              [{:ldi, 3, 1}],
              [{:ldi, 5, 0}],
              :cloop,
              [{:arg, 0, 1}],
              [{:spawn, 2, :spinner, 1}],
              [{:sub, 1, 1, 3}],
              [{:cmpeq, 4, 1, 5}],
              [{:bift, 4, :cdone}],
              [{:jmp, :cloop}],
              :cdone,
              [{:halt}]
            ]},
         spinner:
           {1,
            [
              [{:out, 0}],
              :spin,
              [{:ldi, 2, 1}],
              [{:cmpeq, 3, 2, 2}],
              [{:jmp, :spin}]
            ]}
       })

  @img PicoBEAM.Encoding.image(@asm, :main)
  @entry_spawn @img.entry
  @entry_comb @img.bases.combmain

  if length(@img.image) > 64, do: raise("M3 demo image exceeds the 64-bundle ROM")
  @image_words @img.image ++ List.duplicate(0, 64 - length(@img.image))

  # the two entry points reach the datapath as params: module attributes
  # are compile-time Elixir and do not survive into a `comb` block
  param :ENTRY_SPAWN, default: @entry_spawn
  param :ENTRY_COMB, default: @entry_comb

  clock :clk_25mhz, freq: 25.0

  input :btn1, 1
  input :btn2, 1

  output :led, 8
  output :wifi_en, 1
  output :wifi_gpio0, 1
  output :ftdi_rxd, 1

  wire :clk_48, 1
  wire :clk_12, 1
  wire :pll_locked, 1
  wire :boot_rst, 1

  memory :rom, width: 72, depth: 64, sync_read: :clk_12, init: @image_words

  # boot: stream the ROM through the loader side-door, then create the
  # root process. 0 load · 1 settle · 2 pulse boot_en · 3 running
  wire :bst, 2, init: 0
  wire :ld_i, 7, init: 0
  wire :ld_i_d, 7, init: 0
  wire :ld_en_d, 1, init: 0
  wire :settle, 4, init: 0
  wire :rom_q, 72
  wire :ld_addr9, 9
  wire :boot_en, 1
  wire :boot_pc_w, 9
  wire :sel_comb, 1, init: 0
  wire :eng_rst, 1

  wire :out_v, 1
  wire :out_d, 36
  wire :eng_idle, 1
  # one engine on this board, so the VM-wide halt (`notes/33`) has
  # nobody to tell
  wire :no_halt, 1
  wire :eng_halted, 1
  wire :eng_flt, 1
  wire :eng_fr, 8
  wire :occ, 6
  wire :qcnt, 6
  wire :swaps, 8
  wire :spawns, 12
  wire :deaths, 12
  wire :x_seat, 2
  wire :x_en, 1
  wire :x_pc, 9
  wire :st0, 5
  wire :st1, 5
  wire :st2, 5
  wire :st3, 5

  # the instrument: raw per-seat retire strobes
  wire :seat_act, 4
  wire :led_r, 8, init: 0
  wire :out_l, 8, init: 0
  wire :out_seen, 1, init: 0
  wire :dbg_flags, 4
  wire :occ8, 8
  wire :qcnt4, 4

  comb do
    wifi_gpio0 = 1
    wifi_en = 0
    boot_rst = bor(btn1, bnot(pll_locked))
    eng_rst = bor(boot_rst, bst == 0)
    rom_q = rom[ld_i[5..0]]
    ld_addr9 = ld_i_d[5..0]
    boot_en = bst == 2
    # hold FIRE2 through boot to run demo B (the comb) instead of A
    boot_pc_w = sel_comb * ENTRY_COMB + bnot(sel_comb) * ENTRY_SPAWN

    # seat k's LED is high exactly on the cycles seat k retires a bundle
    seat_act =
      band(x_en, x_seat == 0) * 1 + band(x_en, x_seat == 1) * 2 +
        band(x_en, x_seat == 2) * 4 + band(x_en, x_seat == 3) * 8

    led = led_r
    no_halt = 0
    dbg_flags = eng_idle * 8 + eng_flt * 4 + x_en * 2 + out_seen
    occ8 = occ
    qcnt4 = qcnt[3..0]
  end

  on :clk_12 do
    # ROM reads are sync, so the side-door write trails the index by one
    ld_en_d = band(bst == 0, 1)
    ld_i_d = ld_i

    if boot_rst == 1 do
      bst = 0
      ld_i = 0
      settle = 0
      out_seen = 0
      out_l = 0
    else
      if bst == 0 do
        sel_comb = btn2

        if ld_i == 63 do
          bst = 1
          settle = 0
        else
          ld_i = ld_i + 1
        end
      end

      if bst == 1 do
        # let the last delayed write land and the engine leave reset
        if settle == 7 do
          bst = 2
        else
          settle = settle + 1
        end
      end

      if bst == 2 do
        bst = 3
      end

      if out_v == 1 do
        out_l = out_d[7..0]
        out_seen = 1
      end

      # The LED semantic follows the LATCHED demo choice, not the live
      # button: demo B exists to show the comb, so FIRE2 stays held
      # through it and must not double as a view switch. In demo A,
      # where the interesting number is the result, FIRE2 shows it.
      if sel_comb == 1 do
        led_r = spawns[7..4] * 16 + seat_act
      else
        if btn2 == 1 do
          led_r = out_l
        else
          led_r = spawns[7..4] * 16 + seat_act
        end
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

  instance :engine, PicoBEAM.RTL.BarrelEngine,
    # `notes/53`: no node registry on this top — names are not part of
    # its programs, and tied-off inputs keep the flattened nets driven
    nm_q_hit: 0,
    nm_q_eng: 0,
    nm_q_slot: 0,
    nm_q_serial: 0,
    nm_name_taken: 0,
    nm_pid_taken: 0,
    nm_full: 1,
    nm_probe_state: 0,
    nm_probe_serial: 0,
    peer_probe_slot: 0,
    clk: :clk_12,
    rst: :eng_rst,
    ld_code_en: :ld_en_d,
    ld_code_addr: :ld_addr9,
    ld_code_data: :rom_q,
    boot_en: :boot_en,
    boot_pc: :boot_pc_w,
    out_valid: :out_v,
    out_data: :out_d,
    halt_in: :no_halt,
    halt_req: :eng_halted,
    idle: :eng_idle,
    faulted: :eng_flt,
    fault_reason: :eng_fr,
    dbg_occ: :occ,
    dbg_qcount: :qcnt,
    dbg_swaps: :swaps,
    dbg_spawns: :spawns,
    dbg_deaths: :deaths,
    dbg_x_seat: :x_seat,
    dbg_x_en: :x_en,
    dbg_pc: :x_pc,
    dbg_st0: :st0,
    dbg_st1: :st1,
    dbg_st2: :st2,
    dbg_st3: :st3

  instance :dbg, PicoBEAM.RTL.DbgUart,
    clk: :clk_12,
    rst: :boot_rst,
    pc: :x_pc,
    sstate: :st0,
    flags: :dbg_flags,
    fr: :occ8,
    outv: :out_l,
    fp: :st1,
    sdst: :st3,
    rt1: :spawns,
    rt2: 0,
    rcnt: :qcnt4,
    rtl: :deaths,
    ocnt: :st2,
    txd: :ftdi_rxd
end
