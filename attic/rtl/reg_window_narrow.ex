defmodule PicoBEAM.RTL.RegWindowNarrow do
  @moduledoc """
  Probe C control variant — the same register window unit with the
  SEQUENTIAL-SLOT port count: 2 reads, 1 write, 1 arg port.

  If the engine executed a bundle's slots serially (three microcycles per
  context turn) instead of issuing them together, this is the register
  file it would need. Same three frames, same call exchange, same drain —
  only the port count differs, so `LUT(RegWindow) - LUT(RegWindowNarrow)`
  is the price of the LIW's register-file multiport, isolated. That number,
  against the per-engine budget in `notes/04-fit-model.md`, is one of the
  two facts the Q4a decision was explicitly waiting on M2 to supply (the
  other is the engine's overall LUT total).

  See `PicoBEAM.RTL.RegWindow` for the full design commentary; everything
  there applies here except port count.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  input :rd_addr0, 4
  input :rd_addr1, 4
  output :rd_data0, 36
  output :rd_data1, 36

  input :wr_en0, 1
  input :wr_addr0, 4
  input :wr_data0, 36

  input :arg_en0, 1
  input :arg_idx0, 4
  input :arg_data0, 36

  input :op_call, 1

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

  wire :drain_cnt, 5, init: 16

  comb do
    ready = drain_cnt == 16
    spill_valid = drain_cnt < 16
    spill_idx = drain_cnt[3..0]

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
      end
    end
  end
end
