defmodule PicoBEAM.RTL.RingLink do
  @moduledoc """
  M6 — one hop of the ring: a FIFO between two engines.

  `notes/12` is emphatic that this is **the only thing between
  engines**. There is no shared heap, no shared mailbox and no shared
  proc table; an engine is a node, not a scheduler thread, and the ring
  is its distribution channel. Everything that crosses it is COPIED.

  ## What a packet looks like

      [ head: kind, dest_eng, dest_pid, len: N ]  [ flit 0 ] ... [ flit N-1 ]

  `kind` says what the packet IS. `notes/12` lists what has to cross:
  messages, exit signals, DOWN, and link/unlink/monitor registrations —
  and hardware adds one the model does not need, because the model can
  place a spawn on another engine by writing its table directly and
  hardware cannot:

      0 message      1 spawn_req    2 spawn_rsp
      3 link_req     4 unlink_req   5 monitor_req
      6 exit_signal  7 down_signal  8 noproc_rsp

  `dest_eng` is forwarding information. With two engines a link IS its
  destination and the field is redundant, but a ring of three or more
  has to be able to pass a packet along, and a format that cannot say
  where a packet is going is a format that has to be repainted later.

  The head carries the destination PID rather than a slot index,
  because the far end has to make the incarnation check itself: this
  engine's `ProcTable` knows nothing about another engine's slots, and
  a 6-bit slot recycles fast enough that shipping one alone would be
  the ABA bug `notes/13` designed the 22-bit serial to prevent.

  `len` rides the head so the receiver can stamp the mailbox entry
  before the payload has finished arriving — the same shape the
  serialiser's own enqueue uses.

  ## Depth, and what happens when it fills

  32 entries. A full ring applies BACKPRESSURE to the sender, which is
  the opposite of the rule for a full mailbox (`notes/12`'s Q7: a full
  mailbox kills the receiver, because backpressure there would leak one
  process's slowness into another's WCET).

  The difference is deliberate. A mailbox is per-process and its
  fullness is one process's fault. The ring is shared infrastructure
  and its fullness is nobody's; stalling the sender for a few cycles is
  a bounded delay, while killing somebody for it would make the victim
  a function of unrelated traffic. A sender parked on a full ring is
  parked exactly the way a sender parked on a busy serialiser is.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # in
  input :w_en, 1
  input :w_head, 1
  input :w_kind, 4
  input :w_deng, 4
  input :w_word, 36
  input :w_len, 7
  output :w_ready, 1

  # out
  output :r_valid, 1
  output :r_head, 1
  output :r_kind, 4
  output :r_deng, 4
  output :r_word, 36
  output :r_len, 7
  input :r_pop, 1

  output :depth, 6

  param :DEPTH, default: 32

  memory :fifo, width: 52, depth: 32

  wire :head, 5, init: 0
  wire :tail, 5, init: 0
  wire :cnt, 6, init: 0
  wire :q, 52

  comb do
    q = fifo[head]
    r_word = q[35..0]
    r_len = q[42..36]
    r_deng = q[46..43]
    r_kind = q[50..47]
    r_head = q[51]
    r_valid = cnt != 0
    w_ready = cnt != DEPTH
    depth = cnt
  end

  on :clk do
    if rst == 1 do
      head = 0
      tail = 0
      cnt = 0
    else
      # one write site: the push
      if band(w_en, cnt != DEPTH) == 1 do
        fifo[tail] =
          w_head * 0x8000000000000 + w_kind * 0x800000000000 +
            w_deng * 0x80000000000 + w_len * 0x1000000000 + w_word
        tail = tail + 1
      end

      if band(r_pop, cnt != 0) == 1 do
        head = head + 1
      end

      # the count moves by the net of the two, so a push and a pop in
      # the same cycle leave it alone — which is what makes a full ring
      # drain while it is still being written to
      if band(band(w_en, cnt != DEPTH), bnot(band(r_pop, cnt != 0))) == 1 do
        cnt = cnt + 1
      end

      if band(band(r_pop, cnt != 0), bnot(band(w_en, cnt != DEPTH))) == 1 do
        cnt = cnt - 1
      end
    end
  end
end
