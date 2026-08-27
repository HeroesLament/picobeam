defmodule PicoBEAM.RTL.Sequencer do
  @moduledoc """
  M2 scaffold — the engine's phase FSM (one context; the barrel replaces
  this rotation at M3).

  Phase shape, mirroring the reference model's step order
  (`Machine.execute_bundle` then `commit` then control):

      boot ──▶ fetch ──▶ exec ──┬─▶ fetch            (fall-through / branch)
                                ├─▶ wb2 ──▶ fetch / call_wait / ret_wait / halted
                                ├─▶ call_wait ──▶ fetch   (window drain + jump)
                                ├─▶ ret_wait ──▶ ret_fill ──▶ fetch
                                ├─▶ fault                 (latched; die path is M3)
                                └─▶ halted

  ## The wb2 state (heap-op pass, 2026-08-22)

  Heap-bank and literal-pool reads are SYNC: a bundle containing a heap
  op or `ldc` gets one extra cycle (`wb2`) in which the late result is
  written to its destination through window port 0 (the engine owns
  that mux). A bundle can legally carry a heap op AND a system op, so
  exec latches the pending control decision (`pend_call/ret/halt`) and
  wb2 re-dispatches it — pc arithmetic still happens at exec, and the
  bundle stays on the code store's output through wb2 because pc only
  moves when the control path says so. At M2 a heap op therefore costs
  exec + wb2 = 2 cycles; the M3 barrel overlays other contexts on the
  wb2 slot, which is where that cycle goes to die.

  ## The ret path (call/ret pass, 2026-08-22)

  `ret` cannot pop while the caller's frame is still DRAINING into frame
  RAM (a callee can return in under 16 cycles), so exec parks in
  `ret_wait` until `window_ready`, then strobes `pop_en` and runs
  `ret_fill` for 18 cycles: indices 0..15 presented on `fill_en`/
  `fill_idx` (the engine delays the window write one cycle behind them —
  frame RAM reads are sync), cycle 16 covers the last delayed write, and
  cycle 17 raises `dest_wr` — the engine writes the latched return value
  into the caller's dest register (`FrameRam.ret_dest_out`) — while pc
  redirects to `ret_pc_in` (the popped link). Ret therefore costs ~19
  cycles against call's 1 + background drain; the asymmetry is logged in
  `notes/15` and is exactly what a hot/cold frame-cache optimization
  would attack later, not now.

  `fetch` presents `pc` to the code store; the sync read registers the
  bundle during that cycle, so `exec` sees it one cycle later — a 2-cycle
  bundle at M2. The M3 barrel overlays T contexts on these phases so the
  pipeline is full again; the phase *structure* is what this scaffold
  fixes, not the cycle count.

  Classification inputs (`is_call` etc.) come from the Engine's opcode
  table lookup, not from Decode — the binary opcode assignment is still
  pending (see `PicoBEAM.RTL.Decode`), and this keeps the FSM indifferent
  to it. Faults latch: with no process table yet there is nobody to die
  in favor of; M3 turns the latch into the exit-signal path
  (`notes/13-supervision.md`).

  Hand-rolled state register + `hdl_case` rather than the `fsm` macro:
  every write stays in one `on :clk` block (single-driver by
  construction), which is the RegFIFO16 idiom this repo trusts.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # classification of the bundle now in exec (from the Engine's op table)
  input :is_jump, 1
  input :pc_target, 9
  input :is_call, 1
  input :is_ret, 1
  input :is_halt, 1
  input :fault_in, 1
  input :fault_reason_in, 8

  # a heap op or ldc in the bundle: run the wb2 late-write-back cycle
  input :has_wb2, 1

  # window handshake
  input :window_ready, 1

  # the popped link's resume address (FrameRam.ret_pc_out)
  input :ret_pc_in, 9

  # strobes / state out
  output :pc, 9
  output :exec_en, 1
  output :call_commit, 1
  output :fill_en, 1
  output :fill_idx, 4
  output :pop_en, 1
  # the link to record on call: the bundle after this one
  output :link_pc, 9
  # ret_fill's final cycle: write the latched return value to the dest reg
  output :dest_wr, 1
  # the wb2 late-write-back cycle is now
  output :wb2_en, 1
  # raw FSM state, for the debug UART
  output :sstate, 4
  output :halted, 1
  output :faulted, 1
  output :fault_reason, 8

  # states: 0 boot, 1 fetch, 2 exec, 3 call_wait, 4 ret_fill, 5 fault,
  # 6 halted, 7 ret_wait, 8 wb2
  wire :state, 4, init: 0
  wire :pc_r, 9, init: 0
  wire :fill_i, 5, init: 0
  wire :freason, 8, init: 0
  wire :pend_call, 1, init: 0
  wire :pend_ret, 1, init: 0
  wire :pend_halt, 1, init: 0

  comb do
    pc = pc_r
    link_pc = pc_r + 1
    fault_reason = freason
    exec_en = state == 2
    halted = state == 6
    faulted = state == 5
    fill_en = band(state == 4, fill_i < 16)
    fill_idx = fill_i[3..0]
    dest_wr = band(state == 4, fill_i == 17)
    wb2_en = state == 8
    sstate = state

    # COMBINATIONAL commit pulses, asserted in the same cycle the state
    # machine commits — so FrameRam samples the link (pc_r + 1) and the
    # engine's call_dest BEFORE the pc redirect and the bundle register
    # move on. These were registered pulses once: the link store then
    # captured callee_pc + 1 and a garbage dest, one cycle late — found
    # on first silicon via the ret-target UART trace (rt1 = 6, not 3).
    call_commit = band(state == 3, window_ready)
    pop_en = band(state == 7, window_ready)
  end

  on :clk do
    if rst == 1 do
      state = 0
      pc_r = 0
      fill_i = 0
      freason = 0
      pend_call = 0
      pend_ret = 0
      pend_halt = 0
    else
      hdl_case <<state::4>> do
        # boot
        <<0::4>> ->
          state = 1

        # fetch: pc is on the code store's address this cycle
        <<1::4>> ->
          state = 2

        # exec: bundle is registered out of the sync read; execute+commit.
        # With a wb2 op aboard, the control decision is LATCHED and the
        # wb2 state re-dispatches it; pc arithmetic still happens here.
        <<2::4>> ->
          if fault_in == 1 do
            freason = fault_reason_in
            state = 5
          else
            if has_wb2 == 1 do
              pend_call = is_call
              pend_ret = is_ret
              pend_halt = is_halt

              if is_call == 0 and is_ret == 0 and is_halt == 0 do
                if is_jump == 1 do
                  pc_r = pc_target
                else
                  pc_r = pc_r + 1
                end
              end

              state = 8
            else
              if is_halt == 1 do
                state = 6
              else
                if is_ret == 1 do
                  # cannot pop while the caller's frame is still draining
                  state = 7
                else
                  if is_call == 1 do
                    state = 3
                  else
                    if is_jump == 1 do
                      pc_r = pc_target
                    else
                      pc_r = pc_r + 1
                    end

                    state = 1
                  end
                end
              end
            end
          end

        # call_wait: hold until the spill buffer is free, then commit the
        # window exchange and jump to the callee
        <<3::4>> ->
          if window_ready == 1 do
            pc_r = pc_target
            state = 1
          end

        # ret_fill: 0..15 present read indices, 16 covers the last delayed
        # write, 17 is the dest write + pc redirect to the popped link
        <<4::4>> ->
          if fill_i == 17 do
            fill_i = 0
            pc_r = ret_pc_in
            state = 1
          else
            fill_i = fill_i + 1
          end

        # fault: latched (M3 replaces with the die/exit-signal path)
        <<5::4>> ->
          state = 5

        # halted
        <<6::4>> ->
          state = 6

        # ret_wait: pop only once the drain has finished
        <<7::4>> ->
          if window_ready == 1 do
            fill_i = 0
            state = 4
          end

        # wb2: the late write-back lands (engine's port-0 mux); then the
        # latched control decision, if any
        <<8::4>> ->
          pend_call = 0
          pend_ret = 0
          pend_halt = 0

          if pend_halt == 1 do
            state = 6
          else
            if pend_ret == 1 do
              state = 7
            else
              if pend_call == 1 do
                state = 3
              else
                state = 1
              end
            end
          end

        <<9::4>> -> state = 0
        <<10::4>> -> state = 0
        <<11::4>> -> state = 0
        <<12::4>> -> state = 0
        <<13::4>> -> state = 0
        <<14::4>> -> state = 0
        <<15::4>> -> state = 0
      end
    end
  end
end
