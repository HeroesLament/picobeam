defmodule PicoBEAM.RTL.Timer do
  @moduledoc """
  M5 — per-process receive timeouts: the wheel behind `recv_waitt`.

  `notes/17` called this "the one genuinely new subsystem", and it is
  the only part of the machine that measures rather than counts.

  ## One deadline per process, swept one slot per cycle

  A blocked process may be EVICTED — `notes/17`'s whole eviction rule
  exists because a blocked resident must give up its seat — so the
  deadline cannot live in a context. It lives per SLOT, alongside the
  process, and survives being swapped out.

  The sweep visits one slot per cycle. A timeout is therefore detected
  within **32 cycles of expiry** — 34 since the expiry test was
  pipelined two deep — which at 12 MHz is 2.8 µs: a stateable bound,
  which is the only kind this machine is interested in. Checking all 32
  in parallel would cost 32 comparators against a 32-bit counter to buy
  a latency nobody has asked for.

  The pipe costs two cycles of a bound that was already 32, and buys a
  path split in half: the distributed-RAM read of `deadlines` and the
  32-bit subtract used to be one combinational chain. It is written
  with EHDL's `pipeline` macro — see the declaration below for what
  that does and does not carry.

  ## Wraparound is handled by subtraction, not by comparison

  `now` free-runs and wraps every 2^32 cycles — six minutes at 12 MHz,
  which is not a hypothetical. So expiry is not `now >= deadline`,
  which breaks the moment the counter wraps past a deadline set before
  it. It is `(now - deadline)` read as a SIGNED 32-bit value being
  non-negative, which is correct across any single wrap and is exactly
  one subtraction and one bit test.

  The cost is a stated ceiling: a delay must be under 2^31 cycles
  (~3 minutes at 12 MHz). A longer wait is a counting loop over shorter
  ones, which is what a program wanting minutes should be doing anyway.

  ## Cancellation is the common case

  Most receives with a timeout get their message. So `cancel` — the
  message-arrival path telling the wheel to forget a slot — has to be
  as cheap as arming, and it is: both are one bit of a 32-bit valid
  mask. Nothing is scanned to find the entry, because the slot IS the
  index.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # arm: this slot is blocking with a deadline `delay` cycles out, and
  # if it expires the process resumes at `pc` rather than where it was
  input :arm_en, 1
  input :arm_slot, 5
  input :arm_delay, 32
  input :arm_pc, 12

  # the message came first
  input :cancel_en, 1
  input :cancel_slot, 5

  output :fire_en, 1
  output :fire_slot, 5
  output :fire_pc, 12
  input :fire_ready, 1

  output :now, 32
  output :armed, 32

  memory :deadlines, width: 32, depth: 32
  memory :tpcs, width: 12, depth: 32

  wire :cyc, 32, init: 0
  wire :tval, 32, init: 0
  wire :sweep, 5, init: 0
  wire :r_fire, 1, init: 0
  wire :r_slot, 5, init: 0
  wire :r_pc, 12, init: 0

  wire :expired, 1
  wire :is_armed, 1
  wire :hit, 1

  # the slot index, carried alongside the sample flowing down the pipe.
  # `pipeline` balances the operands its OWN stages read; it carries no
  # tag of its own, so the index that says WHICH slot a result belongs
  # to is delayed here by hand, to the same depth.
  wire :sw_d1, 5, init: 0
  wire :sw_d2, 5, init: 0

  # The expiry test, as a two-stage feed-forward pipe: read the
  # deadline, then subtract. It is `pipeline`'s first use in this
  # project, and the reason it fits where nothing else does is that the
  # sweep is the only STREAMING datapath in the machine — one slot per
  # cycle, no feedback, and a consumer that could not care less about
  # two cycles of latency when the sweep's own granularity is 32.
  #
  # The macro delays `cyc` by one to meet the subtract, which is the
  # part that would otherwise be hand-written and mis-aligned. Both
  # memory reads stay in stage ONE: a memory read in a later stage has
  # its memory NAME rewritten to a delay tap and fails elaboration with
  # `Unknown signal or parameter`. Loud, not silent — but a trap.
  pipeline :expiry, clock: :clk, reset: :rst do
    stage do p_dl = deadlines[sweep] end
    stage do p_diff = cyc - p_dl end
  end

  comb do
    now = cyc
    armed = tval
    fire_en = r_fire
    fire_slot = r_slot
    fire_pc = r_pc

    # `p_diff` belongs to the slot the sweep visited two cycles ago, so
    # every companion here is indexed by `sw_d2`, not by `sweep`.
    #
    # `is_armed` is deliberately NOT pipelined. A cancel that lands in
    # the two cycles between reading a deadline and testing it must
    # still win — that is the tie-break the write funnel below is built
    # around, and a stale armed bit would turn it into a spurious wake.
    # Reading `tval` fresh at the output keeps cancellation the winner
    # it was when this was one cycle deep.
    is_armed = band(tval >>> sw_d2, 1)
    # signed non-negative: correct across a wrap of `cyc`
    expired = bnot(p_diff[31])
    hit = band(is_armed, band(expired, fire_ready))
  end

  on :clk do
    r_fire = 0

    if rst == 1 do
      cyc = 0
      tval = 0
      sweep = 0
    else
      cyc = cyc + 1

      sw_d1 = sweep
      sw_d2 = sw_d1

      if hit == 1 do
        r_fire = 1
        r_slot = sw_d2
        r_pc = tpcs[sw_d2]
      end

      # The sweep advances whether or not this slot fired: a slot that
      # fires is disarmed in the same cycle, so lingering on it would
      # only re-examine an empty entry.
      sweep = sweep + 1

      # ONE write site for the valid mask. Arming, cancelling and
      # firing all touch it, and they are allowed to collide: a message
      # that lands in the same cycle a deadline expires should CANCEL,
      # because the mailbox already has the message and the receive
      # will succeed. Ordering here is the tie-break, and it is the one
      # that does not lose a message.
      if arm_en == 1 do
        deadlines[arm_slot] = cyc + arm_delay
        tpcs[arm_slot] = arm_pc
        tval = bor(tval, 1 <<< arm_slot)
      end

      if hit == 1 do
        tval = band(tval, bnot(1 <<< sw_d2))
      end

      if cancel_en == 1 do
        tval = band(tval, bnot(1 <<< cancel_slot))
      end
    end
  end
end
