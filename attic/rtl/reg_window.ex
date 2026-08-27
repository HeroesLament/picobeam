defmodule PicoBEAM.RTL.RegWindow do
  @moduledoc """
  Probe C / M2 — the clean-on-call register window unit, LIW shape.

  This is the component Q1 + Q4a made the hardest sizing item in the engine
  (`notes/08-open-questions.md`), and the first thing M2 synthesizes: its
  LUT/FF/fmax numbers price the 3-slot bundle's register file directly,
  against `PicoBEAM.RTL.RegWindowNarrow` (the 2R1W sequential-slot shape)
  as the control.

  ## Structure — three frames of flops, JOP's stack cache as a frame cache

  Only the TOP window is read-addressable (reads always target the current
  window's r0..r15; `arg` writes through to the next; `ret`'s cross-window
  write is the instantiator's fill path). So the resident register file is
  exactly:

    * `c0..c15`  — the CURRENT window (all 6 read ports, all 3 write ports)
    * `s0..s15`  — the STAGING window (`arg` writes land here)
    * `p0..p15`  — the SPILL buffer (the frame `call` just pushed out,
                   drained to frame RAM in the background)

  `op_call` is a one-cycle parallel exchange: `p <= c`, `c <= s`. The spill
  buffer then drains autonomously — one word per cycle on `spill_*` — to
  the frame-RAM BRAM the instantiator owns (port-B spirit, Q4b: background
  work never bills the mutator). `ready` drops while draining; a second
  `call` before `ready` is the stall case and the engine sequencer must
  hold it. This bounds resident frames at a CONSTANT (2 full + 1 draining),
  which is resolution (1) of the swap-cost tension in `notes/14-m1-status.md`:
  a context switch moves a fixed number of frames, and the ±0 jitter claim
  of `notes/05-determinism.md` survives.

  ## Fill (ret) is the instantiator's

  On `ret`, the engine stalls the context and streams the caller's frame
  from frame RAM back into `c*` through the ordinary write ports (they are
  idle during a stall), then applies the recorded-destination write. No
  fourth write port exists — adding one here would inflate the probe above
  the real design.

  ## Sequencing contract (matches the reference model's commit order)

  `op_call` must not coincide with `wr_*`/`arg_*` strobes: the engine
  sequencer applies bundle writes, then staging, then control — the same
  order `PicoBEAM.Machine.execute_bundle/commit` fixes. This keeps the
  push path bypass-free.

  ## Not yet here

  One context only. The barrel (M3) multiplies the frames by T or moves
  them into LUT-RAM indexed by context — that fork is exactly what this
  probe's numbers decide.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # -- 6 read ports (3 slots x 2 operands), combinational from current window
  input :rd_addr0, 4
  input :rd_addr1, 4
  input :rd_addr2, 4
  input :rd_addr3, 4
  input :rd_addr4, 4
  input :rd_addr5, 4
  output :rd_data0, 36
  output :rd_data1, 36
  output :rd_data2, 36
  output :rd_data3, 36
  output :rd_data4, 36
  output :rd_data5, 36

  # -- 3 write ports into the current window (one per slot; the assembler's
  # -- bundle contract guarantees no two ports address the same register)
  input :wr_en0, 1
  input :wr_addr0, 4
  input :wr_data0, 36
  input :wr_en1, 1
  input :wr_addr1, 4
  input :wr_data1, 36
  input :wr_en2, 1
  input :wr_addr2, 4
  input :wr_data2, 36

  # -- 3 arg ports into the staging window (arg i, rs — write-through)
  input :arg_en0, 1
  input :arg_idx0, 4
  input :arg_data0, 36
  input :arg_en1, 1
  input :arg_idx1, 4
  input :arg_data1, 36
  input :arg_en2, 1
  input :arg_idx2, 4
  input :arg_data2, 36

  # -- call: push current into the spill buffer, promote staging
  input :op_call, 1
  # -- tailcall: promote staging WITHOUT a push (window reuse) — no spill,
  # -- no drain, no ready gate; the model's tailcall commit made physical
  input :op_tail, 1

  # -- background drain of the spill buffer toward frame RAM
  output :spill_valid, 1
  output :spill_idx, 4
  output :spill_data, 36
  output :ready, 1

  wire :c0, 36, init: 0
  wire :c1, 36, init: 0
  wire :c2, 36, init: 0
  wire :c3, 36, init: 0
  wire :c4, 36, init: 0
  wire :c5, 36, init: 0
  wire :c6, 36, init: 0
  wire :c7, 36, init: 0
  wire :c8, 36, init: 0
  wire :c9, 36, init: 0
  wire :c10, 36, init: 0
  wire :c11, 36, init: 0
  wire :c12, 36, init: 0
  wire :c13, 36, init: 0
  wire :c14, 36, init: 0
  wire :c15, 36, init: 0

  wire :s0, 36, init: 0
  wire :s1, 36, init: 0
  wire :s2, 36, init: 0
  wire :s3, 36, init: 0
  wire :s4, 36, init: 0
  wire :s5, 36, init: 0
  wire :s6, 36, init: 0
  wire :s7, 36, init: 0
  wire :s8, 36, init: 0
  wire :s9, 36, init: 0
  wire :s10, 36, init: 0
  wire :s11, 36, init: 0
  wire :s12, 36, init: 0
  wire :s13, 36, init: 0
  wire :s14, 36, init: 0
  wire :s15, 36, init: 0

  wire :p0, 36, init: 0
  wire :p1, 36, init: 0
  wire :p2, 36, init: 0
  wire :p3, 36, init: 0
  wire :p4, 36, init: 0
  wire :p5, 36, init: 0
  wire :p6, 36, init: 0
  wire :p7, 36, init: 0
  wire :p8, 36, init: 0
  wire :p9, 36, init: 0
  wire :p10, 36, init: 0
  wire :p11, 36, init: 0
  wire :p12, 36, init: 0
  wire :p13, 36, init: 0
  wire :p14, 36, init: 0
  wire :p15, 36, init: 0

  # drain counter: 16 = idle/ready, 0..15 = word being presented
  wire :drain_cnt, 5, init: 16

  comb do
    ready = drain_cnt == 16
    spill_valid = drain_cnt < 16
    spill_idx = drain_cnt[3..0]

    # All arms explicit in every mux — the RegFIFO16 lesson (2026-08-03):
    # an hdl_case no-match yields 0, it does not retain the default.
    rd_data0 = c0

    hdl_case <<rd_addr0::4>> do
      <<0::4>> -> rd_data0 = c0
      <<1::4>> -> rd_data0 = c1
      <<2::4>> -> rd_data0 = c2
      <<3::4>> -> rd_data0 = c3
      <<4::4>> -> rd_data0 = c4
      <<5::4>> -> rd_data0 = c5
      <<6::4>> -> rd_data0 = c6
      <<7::4>> -> rd_data0 = c7
      <<8::4>> -> rd_data0 = c8
      <<9::4>> -> rd_data0 = c9
      <<10::4>> -> rd_data0 = c10
      <<11::4>> -> rd_data0 = c11
      <<12::4>> -> rd_data0 = c12
      <<13::4>> -> rd_data0 = c13
      <<14::4>> -> rd_data0 = c14
      <<15::4>> -> rd_data0 = c15
    end

    rd_data1 = c0

    hdl_case <<rd_addr1::4>> do
      <<0::4>> -> rd_data1 = c0
      <<1::4>> -> rd_data1 = c1
      <<2::4>> -> rd_data1 = c2
      <<3::4>> -> rd_data1 = c3
      <<4::4>> -> rd_data1 = c4
      <<5::4>> -> rd_data1 = c5
      <<6::4>> -> rd_data1 = c6
      <<7::4>> -> rd_data1 = c7
      <<8::4>> -> rd_data1 = c8
      <<9::4>> -> rd_data1 = c9
      <<10::4>> -> rd_data1 = c10
      <<11::4>> -> rd_data1 = c11
      <<12::4>> -> rd_data1 = c12
      <<13::4>> -> rd_data1 = c13
      <<14::4>> -> rd_data1 = c14
      <<15::4>> -> rd_data1 = c15
    end

    rd_data2 = c0

    hdl_case <<rd_addr2::4>> do
      <<0::4>> -> rd_data2 = c0
      <<1::4>> -> rd_data2 = c1
      <<2::4>> -> rd_data2 = c2
      <<3::4>> -> rd_data2 = c3
      <<4::4>> -> rd_data2 = c4
      <<5::4>> -> rd_data2 = c5
      <<6::4>> -> rd_data2 = c6
      <<7::4>> -> rd_data2 = c7
      <<8::4>> -> rd_data2 = c8
      <<9::4>> -> rd_data2 = c9
      <<10::4>> -> rd_data2 = c10
      <<11::4>> -> rd_data2 = c11
      <<12::4>> -> rd_data2 = c12
      <<13::4>> -> rd_data2 = c13
      <<14::4>> -> rd_data2 = c14
      <<15::4>> -> rd_data2 = c15
    end

    rd_data3 = c0

    hdl_case <<rd_addr3::4>> do
      <<0::4>> -> rd_data3 = c0
      <<1::4>> -> rd_data3 = c1
      <<2::4>> -> rd_data3 = c2
      <<3::4>> -> rd_data3 = c3
      <<4::4>> -> rd_data3 = c4
      <<5::4>> -> rd_data3 = c5
      <<6::4>> -> rd_data3 = c6
      <<7::4>> -> rd_data3 = c7
      <<8::4>> -> rd_data3 = c8
      <<9::4>> -> rd_data3 = c9
      <<10::4>> -> rd_data3 = c10
      <<11::4>> -> rd_data3 = c11
      <<12::4>> -> rd_data3 = c12
      <<13::4>> -> rd_data3 = c13
      <<14::4>> -> rd_data3 = c14
      <<15::4>> -> rd_data3 = c15
    end

    rd_data4 = c0

    hdl_case <<rd_addr4::4>> do
      <<0::4>> -> rd_data4 = c0
      <<1::4>> -> rd_data4 = c1
      <<2::4>> -> rd_data4 = c2
      <<3::4>> -> rd_data4 = c3
      <<4::4>> -> rd_data4 = c4
      <<5::4>> -> rd_data4 = c5
      <<6::4>> -> rd_data4 = c6
      <<7::4>> -> rd_data4 = c7
      <<8::4>> -> rd_data4 = c8
      <<9::4>> -> rd_data4 = c9
      <<10::4>> -> rd_data4 = c10
      <<11::4>> -> rd_data4 = c11
      <<12::4>> -> rd_data4 = c12
      <<13::4>> -> rd_data4 = c13
      <<14::4>> -> rd_data4 = c14
      <<15::4>> -> rd_data4 = c15
    end

    rd_data5 = c0

    hdl_case <<rd_addr5::4>> do
      <<0::4>> -> rd_data5 = c0
      <<1::4>> -> rd_data5 = c1
      <<2::4>> -> rd_data5 = c2
      <<3::4>> -> rd_data5 = c3
      <<4::4>> -> rd_data5 = c4
      <<5::4>> -> rd_data5 = c5
      <<6::4>> -> rd_data5 = c6
      <<7::4>> -> rd_data5 = c7
      <<8::4>> -> rd_data5 = c8
      <<9::4>> -> rd_data5 = c9
      <<10::4>> -> rd_data5 = c10
      <<11::4>> -> rd_data5 = c11
      <<12::4>> -> rd_data5 = c12
      <<13::4>> -> rd_data5 = c13
      <<14::4>> -> rd_data5 = c14
      <<15::4>> -> rd_data5 = c15
    end

    spill_data = p0

    hdl_case <<spill_idx::4>> do
      <<0::4>> -> spill_data = p0
      <<1::4>> -> spill_data = p1
      <<2::4>> -> spill_data = p2
      <<3::4>> -> spill_data = p3
      <<4::4>> -> spill_data = p4
      <<5::4>> -> spill_data = p5
      <<6::4>> -> spill_data = p6
      <<7::4>> -> spill_data = p7
      <<8::4>> -> spill_data = p8
      <<9::4>> -> spill_data = p9
      <<10::4>> -> spill_data = p10
      <<11::4>> -> spill_data = p11
      <<12::4>> -> spill_data = p12
      <<13::4>> -> spill_data = p13
      <<14::4>> -> spill_data = p14
      <<15::4>> -> spill_data = p15
    end
  end

  on :clk do
    if rst == 1 do
      drain_cnt = 16
    else
      if op_call == 1 do
        # one-cycle frame exchange: push current, promote staging
        p0 = c0
        p1 = c1
        p2 = c2
        p3 = c3
        p4 = c4
        p5 = c5
        p6 = c6
        p7 = c7
        p8 = c8
        p9 = c9
        p10 = c10
        p11 = c11
        p12 = c12
        p13 = c13
        p14 = c14
        p15 = c15
        c0 = s0
        c1 = s1
        c2 = s2
        c3 = s3
        c4 = s4
        c5 = s5
        c6 = s6
        c7 = s7
        c8 = s8
        c9 = s9
        c10 = s10
        c11 = s11
        c12 = s12
        c13 = s13
        c14 = s14
        c15 = s15
        drain_cnt = 0
      else
        if drain_cnt < 16 do
          drain_cnt = drain_cnt + 1
        end

        if op_tail == 1 do
          # window reuse: staging becomes current, nothing spills. The
          # else arm suppresses same-bundle register writes and arg
          # stages — the model's tailcall commit replaces the window,
          # so they are moot by definition.
          c0 = s0
          c1 = s1
          c2 = s2
          c3 = s3
          c4 = s4
          c5 = s5
          c6 = s6
          c7 = s7
          c8 = s8
          c9 = s9
          c10 = s10
          c11 = s11
          c12 = s12
          c13 = s13
          c14 = s14
          c15 = s15
        else
        # write ports (mutually exclusive addresses by the bundle contract)
        if wr_en0 == 1 and wr_addr0 == 0, do: c0 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 1, do: c1 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 2, do: c2 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 3, do: c3 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 4, do: c4 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 5, do: c5 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 6, do: c6 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 7, do: c7 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 8, do: c8 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 9, do: c9 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 10, do: c10 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 11, do: c11 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 12, do: c12 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 13, do: c13 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 14, do: c14 = wr_data0
        if wr_en0 == 1 and wr_addr0 == 15, do: c15 = wr_data0

        if wr_en1 == 1 and wr_addr1 == 0, do: c0 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 1, do: c1 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 2, do: c2 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 3, do: c3 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 4, do: c4 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 5, do: c5 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 6, do: c6 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 7, do: c7 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 8, do: c8 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 9, do: c9 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 10, do: c10 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 11, do: c11 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 12, do: c12 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 13, do: c13 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 14, do: c14 = wr_data1
        if wr_en1 == 1 and wr_addr1 == 15, do: c15 = wr_data1

        if wr_en2 == 1 and wr_addr2 == 0, do: c0 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 1, do: c1 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 2, do: c2 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 3, do: c3 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 4, do: c4 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 5, do: c5 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 6, do: c6 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 7, do: c7 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 8, do: c8 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 9, do: c9 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 10, do: c10 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 11, do: c11 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 12, do: c12 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 13, do: c13 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 14, do: c14 = wr_data2
        if wr_en2 == 1 and wr_addr2 == 15, do: c15 = wr_data2

        # arg ports into staging
        if arg_en0 == 1 and arg_idx0 == 0, do: s0 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 1, do: s1 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 2, do: s2 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 3, do: s3 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 4, do: s4 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 5, do: s5 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 6, do: s6 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 7, do: s7 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 8, do: s8 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 9, do: s9 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 10, do: s10 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 11, do: s11 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 12, do: s12 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 13, do: s13 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 14, do: s14 = arg_data0
        if arg_en0 == 1 and arg_idx0 == 15, do: s15 = arg_data0

        if arg_en1 == 1 and arg_idx1 == 0, do: s0 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 1, do: s1 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 2, do: s2 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 3, do: s3 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 4, do: s4 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 5, do: s5 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 6, do: s6 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 7, do: s7 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 8, do: s8 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 9, do: s9 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 10, do: s10 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 11, do: s11 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 12, do: s12 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 13, do: s13 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 14, do: s14 = arg_data1
        if arg_en1 == 1 and arg_idx1 == 15, do: s15 = arg_data1

        if arg_en2 == 1 and arg_idx2 == 0, do: s0 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 1, do: s1 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 2, do: s2 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 3, do: s3 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 4, do: s4 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 5, do: s5 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 6, do: s6 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 7, do: s7 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 8, do: s8 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 9, do: s9 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 10, do: s10 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 11, do: s11 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 12, do: s12 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 13, do: s13 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 14, do: s14 = arg_data2
        if arg_en2 == 1 and arg_idx2 == 15, do: s15 = arg_data2
        end
      end
    end
  end
end
