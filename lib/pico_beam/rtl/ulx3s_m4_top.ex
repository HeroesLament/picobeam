defmodule PicoBEAM.RTL.Ulx3sM4Top do
  @moduledoc """
  M4 exit demo on the ULX3S: processes talking to each other.

  Two programs in one bitstream, selected by holding FIRE2 through a
  FIRE1 reset (the M3 top's convention):

  * **A — ping-pong, forever.** The root takes its own pid with `self`,
    hands it to a spawned `pong` server, and then bounces a counter
    back and forth. Every 64 round trips it bumps a block counter and
    `out`s it, so the LEDs are a binary counter whose speed IS the
    message rate. Nothing ever halts.
  * **B — eviction.** Five processes block on `receive` with only four
    seats, so blocked residents must be unseated for the root to keep
    running; the root then wakes exactly one of them with a message and
    that process — evicted, off-seat, blocked — is re-queued, re-seated,
    restored, and resumed. It reports 99 and exits, leaving four still
    waiting.

  ## The UART oracle, aimed at messages

      pPPP S F RR AAA LLL C O OO WD

      PPP  pc in X            AAA  sends (12 bits, wrapping)
      S    seat 0 state       LLL  takes (12 bits, wrapping)
      F    {idle,fault,       C    run-queue depth
            x_en,out_seen}    O    evictions
      RR   proc-table         OO   last out byte
           occupancy          W    deaths
                              D    seat 3 state

  `AAA` and `LLL` climbing together, and staying equal, is the demo:
  every message sent is a message taken. `O` counting up in demo B is
  the eviction rule doing its job.
  """

  use Hw.Component

  @asm PicoBEAM.Asm.assemble(%{
         # ---- A: ping-pong, forever ------------------------------------
         main:
           {0,
            [
              [{:self, 1}],
              [{:arg, 0, 1}],
              [{:spawn, 2, :pong, 1}],
              [{:ldi, 3, 0}],
              [{:ldi, 4, 1}],
              [{:ldi, 5, 0}],
              :outer,
              [{:ldi, 6, 64}],
              :inner,
              [{:send, 2, 3}],
              :rx,
              [{:recv_start}],
              [{:recv_wait}],
              [{:recv_peek, 7, :rx}],
              [{:recv_take, 7}],
              [{:sub, 6, 6, 4}],
              [{:cmpeq, 8, 6, 5}],
              [{:biff, 8, :inner}],
              [{:add, 3, 3, 4}],
              [{:out, 3}],
              [{:jmp, :outer}]
            ]},
         pong:
           {1,
            [
              :pl,
              [{:recv_start}],
              [{:recv_wait}],
              [{:recv_peek, 1, :pl}],
              [{:recv_take, 1}],
              [{:send, 0, 1}],
              [{:jmp, :pl}]
            ]},

         # ---- B: eviction ----------------------------------------------
         evmain:
           {0,
            [
              [{:ldi, 3, 1}],
              [{:ldi, 5, 0}],
              [{:ldi, 1, 5}],
              [{:arg, 0, 1}],
              [{:spawn, 9, :waiter, 1}],
              [{:sub, 1, 1, 3}],
              :eloop,
              [{:arg, 0, 1}],
              [{:spawn, 2, :waiter, 1}],
              [{:sub, 1, 1, 3}],
              [{:cmpeq, 4, 1, 5}],
              [{:bift, 4, :edone}],
              [{:jmp, :eloop}],
              :edone,
              [{:ldi, 6, 500}],
              :edelay,
              [{:sub, 6, 6, 3}],
              [{:cmpeq, 7, 6, 5}],
              [{:biff, 7, :edelay}],
              [{:ldi, 8, 99}],
              [{:send, 9, 8}],
              [{:halt}]
            ]},
         waiter:
           {1,
            [
              :wl,
              [{:recv_start}],
              [{:recv_wait}],
              [{:recv_peek, 1, :wl}],
              [{:recv_take, 1}],
              [{:out, 1}],
              [{:halt}]
            ]},

         # ---- C: fixed point -------------------------------------------
         # Five ticks of the Q12 cubic Hermite from notes/20. The LEDs
         # carry eight bits, so the program checks ITSELF and reports a
         # score: 0xA0 plus 1 if the plain sum of the five results is
         # what `machine.ex` computes, plus 2 if the TICK-WEIGHTED sum
         # is. 0xA3 means both. The weighted sum is there so that two
         # results swapping places, or compensating errors, still show.
         # (`scripts/tb_fixed.v` checks all five values individually
         # against the model; silicon only has to confirm sim.)
         fxmain:
           {0,
            [
              [{:ldi, 1, 2000}],
              [{:ldi, 2, 20}],
              [{:mul, 3, 1, 2}],
              [{:ldi, 2, 4}],
              [{:mul, 4, 1, 2}],
              [{:ldi, 2, -2}],
              [{:mul, 5, 1, 2}],
              [{:ldi, 6, 0}],
              [{:ldi, 7, 0}],
              [{:ldi, 8, 1024}],
              [{:ldi, 9, 0}],
              [{:ldi, 10, 1}],
              [{:ldi, 13, 0}],
              [{:ldi, 14, 0}],
              :fxloop,
              [{:arg, 0, 6}],
              [{:arg, 1, 4}],
              [{:arg, 2, 3}],
              [{:arg, 3, 5}],
              [{:arg, 4, 7}],
              [{:call, 11, :hermite, 5}],
              [{:add, 13, 13, 11}],
              [{:add, 9, 9, 10}],
              [{:mul, 12, 11, 9}],
              [{:add, 14, 14, 12}],
              [{:add, 7, 7, 8}],
              [{:ldi, 2, 5}],
              [{:cmpeq, 15, 9, 2}],
              [{:biff, 15, :fxloop}],
              # sum == 103749 = 2000 * 51 + 1749
              [{:ldi, 1, 2000}],
              [{:ldi, 2, 51}],
              [{:mul, 3, 1, 2}],
              [{:ldi, 2, 1749}],
              [{:add, 3, 3, 2}],
              [{:cmpeq, 4, 13, 3}],
              [{:ldi, 5, 0}],
              [{:biff, 4, :fxw}],
              [{:ldi, 5, 1}],
              :fxw,
              # weighted == 418372 = 2000 * 209 + 372
              [{:ldi, 2, 209}],
              [{:mul, 6, 1, 2}],
              [{:ldi, 2, 372}],
              [{:add, 6, 6, 2}],
              [{:cmpeq, 4, 14, 6}],
              [{:ldi, 7, 0}],
              [{:biff, 4, :fxr}],
              [{:ldi, 7, 2}],
              :fxr,
              [{:add, 5, 5, 7}],
              [{:ldi, 2, 160}],
              [{:add, 5, 5, 2}],
              :fxspin,
              [{:out, 5}],
              [{:jmp, :fxspin}]
            ]},

         hermite:
           {5,
            [
              [{:mulsr, 5, 4, 4, 12}],
              [{:mulsr, 6, 5, 4, 12}],
              [{:add, 7, 5, 5}],
              [{:add, 7, 7, 5}],
              [{:sub, 7, 7, 6}],
              [{:sub, 7, 7, 6}],
              [{:sub, 8, 4, 5}],
              [{:sub, 8, 8, 5}],
              [{:add, 8, 8, 6}],
              [{:sub, 9, 6, 5}],
              [{:sub, 10, 2, 0}],
              [{:mulsr, 11, 10, 7, 12}],
              [{:add, 11, 11, 0}],
              [{:mulsr, 12, 1, 8, 12}],
              [{:add, 11, 11, 12}],
              [{:mulsr, 13, 3, 9, 12}],
              [{:add, 11, 11, 13}],
              [{:ret, 11}]
            ]}
       })

  @img PicoBEAM.Encoding.image(@asm, :main)
  @entry_ping @img.entry
  @entry_evict @img.bases.evmain
  @entry_fixed @img.bases.fxmain

  # three programs no longer fit 64 bundles; the ROM is 72 x 128, which
  # is the same four EBRs it was already spending
  if length(@img.image) > 128, do: raise("M4 demo image exceeds the 128-bundle ROM")
  @image_words @img.image ++ List.duplicate(0, 128 - length(@img.image))

  @doc """
  The assembled demo programs, so a test or a script can run the very
  bundles the bitstream carries on the reference model — the bitstream
  and the oracle stay one artifact.
  """
  def demo_asm, do: @asm
  def demo_entries,
    do: %{ping: @entry_ping, evict: @entry_evict, fixed: @entry_fixed}

  param :ENTRY_PING, default: @entry_ping
  param :ENTRY_EVICT, default: @entry_evict
  param :ENTRY_FIXED, default: @entry_fixed

  clock :clk_25mhz, freq: 25.0

  input :btn1, 1
  input :btn2, 1
  input :btn3, 1

  output :led, 8
  output :wifi_en, 1
  output :wifi_gpio0, 1
  output :ftdi_rxd, 1

  wire :clk_48, 1
  wire :clk_12, 1
  wire :pll_locked, 1
  wire :boot_rst, 1

  memory :rom, width: 72, depth: 128, sync_read: :clk_12, init: @image_words

  wire :bst, 2, init: 0
  wire :ld_i, 7, init: 0
  wire :ld_i_d, 7, init: 0
  wire :ld_en_d, 1, init: 0
  wire :settle, 4, init: 0
  wire :sel_ev, 1, init: 0
  wire :sel_fx, 1, init: 0
  wire :rom_q, 72
  wire :ld_addr9, 12
  wire :boot_en, 1
  wire :boot_pc_w, 12
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
  wire :eng_fc, 8
  wire :eng_fs, 5
  wire :occ, 6
  wire :qcnt, 6
  wire :swaps, 8
  wire :spawns, 12
  wire :deaths, 12
  wire :sends, 12
  wire :recvs, 12
  wire :scan, 6
  wire :evicts, 8
  wire :x_seat, 2
  wire :x_en, 1
  wire :x_pc, 9
  wire :st0, 5
  wire :st1, 5
  wire :st2, 5
  wire :st3, 5

  wire :seat_act, 4
  wire :led_r, 8, init: 0
  wire :out_l, 8, init: 0
  wire :out_seen, 1, init: 0
  wire :dbg_flags, 4
  wire :occ8, 8
  wire :qcnt4, 4
  wire :ev4, 4

  comb do
    wifi_gpio0 = 1
    wifi_en = 0
    boot_rst = bor(btn1, bnot(pll_locked))
    eng_rst = bor(boot_rst, bst == 0)
    rom_q = rom[ld_i[6..0]]
    ld_addr9 = ld_i_d[6..0]
    boot_en = bst == 2
    boot_pc_w =
      sel_fx * ENTRY_FIXED +
        bnot(sel_fx) * (sel_ev * ENTRY_EVICT + bnot(sel_ev) * ENTRY_PING)

    seat_act =
      band(x_en, x_seat == 0) * 1 + band(x_en, x_seat == 1) * 2 +
        band(x_en, x_seat == 2) * 4 + band(x_en, x_seat == 3) * 8

    led = led_r
    no_halt = 0
    dbg_flags = eng_idle * 8 + eng_flt * 4 + x_en * 2 + out_seen
    occ8 = occ
    qcnt4 = qcnt[3..0]
    ev4 = evicts[3..0]
  end

  on :clk_12 do
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
        sel_ev = btn2
        sel_fx = btn3

        if ld_i == 127 do
          bst = 1
          settle = 0
        else
          ld_i = ld_i + 1
        end
      end

      if bst == 1 do
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

      # before the first `out`, show liveness (the seat comb and the
      # spawn count); after it, show the value the program reported —
      # in ping-pong that is a counter whose speed is the message rate
      if out_seen == 1 do
        led_r = out_l
      else
        led_r = spawns[3..0] * 16 + seat_act
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
    # one engine, no ring, no literal-pool loader on this top. These
    # inputs arrived after M4 (the ring in notes/49, the pool later) and
    # were left unbound: the emitter declares the nets and drives
    # nothing, so ring_r_valid simulated as X into the ingress and every
    # tb_m4_top variant failed. Tied off the way the single-engine
    # benches tie them.
    eng_id: 0,
    ring_r_valid: 0,
    ring_r_head: 0,
    ring_r_kind: 0,
    ring_r_deng: 0,
    ring_r_word: 0,
    ring_r_len: 0,
    ring_w_ready: 1,
    ld_pool_en: 0,
    ld_pool_addr: 0,
    ld_pool_data: 0,
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
    fault_slot: :eng_fs,
    fault_count: :eng_fc,
    dbg_occ: :occ,
    dbg_qcount: :qcnt,
    dbg_swaps: :swaps,
    dbg_spawns: :spawns,
    dbg_deaths: :deaths,
    dbg_sends: :sends,
    dbg_recvs: :recvs,
    dbg_scan: :scan,
    dbg_evicts: :evicts,
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
    # `fr` is the CC field: occupancy. It has been occupancy since M3;
    # what changed is that the format string no longer claims it is the
    # fault reason, which now has its own field.
    fr: :occ8,
    outv: :out_l,
    fp: :deaths,
    sdst: :st3,
    rt1: :sends,
    rt2: 0,
    rcnt: :qcnt4,
    rtl: :recvs,
    ocnt: :ev4,
    frr: :eng_fr,
    fcnt: :eng_fc,
    txd: :ftdi_rxd
end
