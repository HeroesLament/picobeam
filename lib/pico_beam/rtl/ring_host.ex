defmodule PicoBEAM.RTL.RingHost do
  @moduledoc """
  The host as ring node 15: routing between the two engines, their two
  links, and a host-in / host-out queue pair (`RingLink`s in `M5Core`).

  A two-node ring needed no routing: a link IS its destination, and an
  engine's ingress never reads `r_deng`. A third node does. This block
  sits between the engines and the links and does it packet by packet;
  a packet is a head (kind, dest engine, dest pid, `len`) and `len`
  payload flits, contiguous on one producer.

  ## Egress: the split

  Engine k's writes go to its link, or to host-out when the packet's
  head says `deng == 15`. The decision is made from the head and
  latched (`h0`/`h1`) for the payload. Host-out has two producers, so it
  is owned a packet at a time (`own`, `oleft`).

  The engine gates `w_en` with `w_ready` combinationally, and its
  `w_head`/`w_deng` come from state that may see readiness too, so an
  engine's ready must not depend on its own head. It does not: ready is
  the AND of both destinations (link ready, host-out ready and not owned
  by the other engine). An engine therefore stalls for a few cycles when
  host-out is full or busy even if this packet was for its link; that is
  the price of a loop-free split, and the ring already treats a full
  queue as backpressure. Engine 1's ready also yields to engine 0
  starting a host packet in the same cycle; engine 0's ready never looks
  at engine 1, so that is loop-free too.

  ## Ingress: the merge

  Each engine reads from its link or from host-in. A reader locks to a
  source at a head and releases after `len` pops; host-in heads go only
  to the engine their `deng` names, so the two readers never contend for
  the same packet. The link wins when both have a packet waiting.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # ---- engine egress (from the engines' ring_w_*)
  input :e0w_en, 1
  input :e0w_head, 1
  input :e0w_kind, 4
  input :e0w_deng, 4
  input :e0w_word, 36
  input :e0w_len, 7
  output :e0w_ready, 1
  input :e1w_en, 1
  input :e1w_head, 1
  input :e1w_kind, 4
  input :e1w_deng, 4
  input :e1w_word, 36
  input :e1w_len, 7
  output :e1w_ready, 1

  # ---- link A (engine 0 -> engine 1) and link B (engine 1 -> engine 0), write side
  output :a_en, 1
  output :a_head, 1
  output :a_kind, 4
  output :a_deng, 4
  output :a_word, 36
  output :a_len, 7
  input :a_ready, 1
  output :b_en, 1
  output :b_head, 1
  output :b_kind, 4
  output :b_deng, 4
  output :b_word, 36
  output :b_len, 7
  input :b_ready, 1

  # ---- host-out queue, write side
  output :ho_en, 1
  output :ho_head, 1
  output :ho_kind, 4
  output :ho_deng, 4
  output :ho_word, 36
  output :ho_len, 7
  input :ho_ready, 1

  # ---- link A / link B / host-in, read side
  input :a_valid, 1
  input :a_rhead, 1
  input :a_rkind, 4
  input :a_rdeng, 4
  input :a_rword, 36
  input :a_rlen, 7
  output :a_pop, 1
  input :b_valid, 1
  input :b_rhead, 1
  input :b_rkind, 4
  input :b_rdeng, 4
  input :b_rword, 36
  input :b_rlen, 7
  output :b_pop, 1
  input :hi_valid, 1
  input :hi_rhead, 1
  input :hi_rkind, 4
  input :hi_rdeng, 4
  input :hi_rword, 36
  input :hi_rlen, 7
  output :hi_pop, 1

  # ---- engine ingress (to the engines' ring_r_*)
  output :e0r_valid, 1
  output :e0r_head, 1
  output :e0r_kind, 4
  output :e0r_deng, 4
  output :e0r_word, 36
  output :e0r_len, 7
  input :e0r_pop, 1
  output :e1r_valid, 1
  output :e1r_head, 1
  output :e1r_kind, 4
  output :e1r_deng, 4
  output :e1r_word, 36
  output :e1r_len, 7
  input :e1r_pop, 1

  # egress state
  wire :h0, 1, init: 0
  wire :h1, 1, init: 0
  wire :own, 2, init: 0
  wire :oleft, 7, init: 0
  # ingress state: 0 none, 1 link, 2 host-in
  wire :src0, 2, init: 0
  wire :left0, 7, init: 0
  wire :src1, 2, init: 0
  wire :left1, 7, init: 0

  wire :e0_hhd, 1
  wire :e1_hhd, 1
  wire :e0_th, 1
  wire :e1_th, 1
  wire :e0_hgo, 1
  wire :e1_hgo, 1
  wire :e0_hstart, 1
  wire :hi_for0, 1
  wire :hi_for1, 1
  wire :s0l, 1
  wire :s0h, 1
  wire :s1l, 1
  wire :s1h, 1

  comb do
    # ---- egress
    e0_hhd = band(e0w_head, e0w_deng == 15)
    e1_hhd = band(e1w_head, e1w_deng == 15)
    e0_th = if e0w_head == 1, do: e0_hhd, else: h0
    e1_th = if e1w_head == 1, do: e1_hhd, else: h1
    e0_hstart = band(own == 0, band(e0w_en, e0_hhd))

    e0w_ready = band(a_ready, band(ho_ready, own != 2))
    e1w_ready = band(b_ready, band(ho_ready, band(own != 1, bnot(e0_hstart))))

    e0_hgo = band(e0w_en, e0_th)
    e1_hgo = band(e1w_en, e1_th)

    a_en = band(e0w_en, bnot(e0_th))
    a_head = e0w_head
    a_kind = e0w_kind
    a_deng = e0w_deng
    a_word = e0w_word
    a_len = e0w_len
    b_en = band(e1w_en, bnot(e1_th))
    b_head = e1w_head
    b_kind = e1w_kind
    b_deng = e1w_deng
    b_word = e1w_word
    b_len = e1w_len

    # ownership makes the two exclusive
    ho_en = bor(e0_hgo, e1_hgo)
    ho_head = if e0_hgo == 1, do: e0w_head, else: e1w_head
    ho_kind = if e0_hgo == 1, do: e0w_kind, else: e1w_kind
    ho_deng = if e0_hgo == 1, do: e0w_deng, else: e1w_deng
    ho_word = if e0_hgo == 1, do: e0w_word, else: e1w_word
    ho_len = if e0_hgo == 1, do: e0w_len, else: e1w_len

    # ---- ingress: engine 0 reads link B or host-in (deng 0), engine 1
    # reads link A or host-in (deng 1)
    hi_for0 = band(hi_valid, band(hi_rhead, hi_rdeng == 0))
    hi_for1 = band(hi_valid, band(hi_rhead, hi_rdeng == 1))

    s0l = if src0 == 0, do: b_valid, else: src0 == 1
    s0h = if src0 == 0, do: band(bnot(b_valid), hi_for0), else: src0 == 2
    s1l = if src1 == 0, do: a_valid, else: src1 == 1
    s1h = if src1 == 0, do: band(bnot(a_valid), hi_for1), else: src1 == 2

    e0r_valid = bor(band(s0l, b_valid), band(s0h, hi_valid))
    e0r_head = if s0h == 1, do: hi_rhead, else: b_rhead
    e0r_kind = if s0h == 1, do: hi_rkind, else: b_rkind
    e0r_deng = if s0h == 1, do: hi_rdeng, else: b_rdeng
    e0r_word = if s0h == 1, do: hi_rword, else: b_rword
    e0r_len = if s0h == 1, do: hi_rlen, else: b_rlen
    e1r_valid = bor(band(s1l, a_valid), band(s1h, hi_valid))
    e1r_head = if s1h == 1, do: hi_rhead, else: a_rhead
    e1r_kind = if s1h == 1, do: hi_rkind, else: a_rkind
    e1r_deng = if s1h == 1, do: hi_rdeng, else: a_rdeng
    e1r_word = if s1h == 1, do: hi_rword, else: a_rword
    e1r_len = if s1h == 1, do: hi_rlen, else: a_rlen

    b_pop = band(e0r_pop, s0l)
    a_pop = band(e1r_pop, s1l)
    hi_pop = bor(band(e0r_pop, s0h), band(e1r_pop, s1h))
  end

  on :clk do
    if rst == 1 do
      h0 = 0
      h1 = 0
      own = 0
      oleft = 0
      src0 = 0
      left0 = 0
      src1 = 0
      left1 = 0
    else
      # ---- egress: which way this engine's current packet goes
      if band(e0w_en, e0w_head) == 1 do
        h0 = e0_hhd
      end

      if band(e1w_en, e1w_head) == 1 do
        h1 = e1_hhd
      end

      # ---- host-out ownership, a packet at a time
      if own == 0 do
        if band(e0w_en, e0_hhd) == 1 do
          oleft = e0w_len

          if e0w_len != 0 do
            own = 1
          end
        else
          if band(e1w_en, e1_hhd) == 1 do
            oleft = e1w_len

            if e1w_len != 0 do
              own = 2
            end
          end
        end
      else
        if bor(band(own == 1, band(e0w_en, bnot(e0w_head))),
             band(own == 2, band(e1w_en, bnot(e1w_head)))) == 1 do
          oleft = oleft - 1

          if oleft == 1 do
            own = 0
          end
        end
      end

      # ---- ingress locks: taken at a head, released after `len` pops
      if e0r_pop == 1 do
        if src0 == 0 do
          left0 = e0r_len

          if e0r_len != 0 do
            src0 = s0h * 2 + bnot(s0h) * 1
          end
        else
          left0 = left0 - 1

          if left0 == 1 do
            src0 = 0
          end
        end
      end

      if e1r_pop == 1 do
        if src1 == 0 do
          left1 = e1r_len

          if e1r_len != 0 do
            src1 = s1h * 2 + bnot(s1h) * 1
          end
        else
          left1 = left1 - 1

          if left1 == 1 do
            src1 = 0
          end
        end
      end
    end
  end
end
