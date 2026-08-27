defmodule PicoBEAM.RTL.Mailbox do
  @moduledoc """
  M4 — the mailbox and the match unit (`notes/17`).

  32 processes × 64 entries, `{slot:5, idx:6}` → 2048 entries of
  `{word:36}` plus `{valid:1, head:1, len:6, hash:8}`.

  ## Entries are flits, not messages

  A message is a term and a term is 1..63 flits (`PicoBEAM.Serial`), so
  a message occupies CONSECUTIVE entries and the store has to be able
  to tell a message from its own continuation. The first flit carries
  `head = 1`, the whole message's `len`, and the shape hash; every
  other flit carries `head = 0` and nothing else that matters.

  Three things fall out, and each of them is the reason for the bit:

  * **The matcher only ever matches a `head`.** Without that bit, the
    second flit of `{ok, 5}` — a bare `5` — could hash-match a filter
    looking for a fixnum and hand the receiver the inside of somebody
    else's message.
  * **`take` needs `len`** to invalidate and reclaim the whole message,
    which is why the length is stored rather than recomputed.
  * **`free` replaces `full`.** An enqueue of an n-flit message needs n
    contiguous entries, so the fullness probe reports how many are left
    and the send unit compares against the count it is about to write.
    A boolean cannot answer a question whose threshold varies.

  Continuations of a taken message keep `valid = 1` until `head`
  sweeps past them. That is harmless — they have `head = 0`, so the
  scan steps over them and nothing can match them — and it keeps take
  to one cycle instead of `len`.

  ## One command port, and why that is the honest design

  A send and a receive-side step can want the mailbox in the same
  cycle. Rather than duplicate the state or arbitrate, the mailbox
  takes ONE command per cycle and the engine gives enqueue priority:

      0 nop · 1 enqueue · 2 start · 3 peek · 4 take · 5 skip

  Contention costs the scanning process a cycle and never costs
  correctness, because a scan that misses a message arriving mid-scan
  simply finds it on the next `recv_wait`/`peek` round — exactly the
  race BEAM's receive loop already tolerates. Every per-process
  counter therefore has a single write site, the discipline this
  codebase has kept since M2.

  ## The matcher lives here

  `notes/05` claims the scan costs the mutator nothing because it runs
  on the mailbox's own port. `cmd = peek` starts a scan FSM inside this
  unit: it walks from the process's cursor toward its tail, one entry
  per cycle, skipping tombstones, testing each hash against the filter,
  and raises `busy` while it works. The ENGINE parks the scanning
  context, so the other three seats keep executing for the whole scan —
  the barrel's version of "free", and structural rather than measured.

  `scan_len` reports the distance walked, which is the receive-latency
  histogram `notes/05` promised to earn.

  ## Take is a tombstone

  `recv_take` removes at the CURSOR, not the head, which no ring buffer
  does cheaply. So an entry carries a valid bit, take clears it in
  place, and the scan skips invalid entries. Head advances immediately
  when the taken entry WAS the head — the common case, and exact for a
  process that never skips. After skips, tombstones linger below the
  head until it catches up, so a mailbox can report `full` while
  holding fewer than 64 live messages. Conservative, never wrong, and
  cheap; a compaction pass on idle cycles is the obvious later win.

  ## Overflow kills the RECEIVER

  `full` is raised combinationally for an enqueue that has nowhere to
  go, and the engine turns it into `:mailbox_full` on the TARGET, not
  the sender — Q7's answer, because backpressure on a sender would leak
  one process's slowness into another's WCET (`notes/12`).
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  input :cmd, 3
  input :cmd_slot, 5
  input :cmd_word, 36
  input :cmd_hash, 8
  # enqueue: the first flit of a message carries head=1 and the whole
  # message's length; continuations carry head=0
  input :cmd_head, 1
  input :cmd_len, 6
  input :cmd_filter, 8
  # 0 = accept any message (an unfiltered receive)
  input :cmd_filtered, 1

  # The fullness probe is a SEPARATE port, addressed independently of
  # the command. It has to be: `send` decides whether to enqueue from
  # `full`, and if `full` were a function of `cmd` the two would form a
  # combinational loop (found the moment the send unit met the mailbox).
  # The engine drives `q_slot` straight from the decoded pid.
  input :q_slot, 5
  output :full, 1
  # entries still free in the probe slot's ring. `full` is `free == 0`,
  # kept because the immediate path still asks a yes/no question.
  output :free, 7

  # scan status / result
  output :busy, 1
  output :done, 1
  output :hit, 1
  output :hit_word, 36
  output :scan_len, 6
  # where the matched message starts, and how long it is — the
  # deserialiser reads from here, and `take` reclaims this much
  output :hit_idx, 6
  output :hit_len, 6

  # a dedicated flit read port for the rebuild FSM: it walks a matched
  # message while the command port is free to serve someone else's
  # enqueue. Sync read, one cycle.
  input :rf_slot, 5
  input :rf_idx, 6
  output :rf_word, 36

  # per-slot status for the PROBE slot (q_slot), not the command slot:
  # `recv_wait` must ask "have I unseen mail?" about the running
  # process while the command port may be busy with someone else's
  # enqueue. Only one of {send, recv_wait} can be at X in a given cycle
  # (one system op per bundle, one X context per cycle), so the engine
  # muxes q_slot between them with no conflict and no loop.
  output :count, 7
  output :unseen, 1

  memory :words, width: 36, depth: 2048, sync_read: :clk
  # {valid:1, head:1, len:6, hash:8}
  memory :hv, width: 16, depth: 2048, sync_read: :clk

  # per-process ring state (one write site each: one command per cycle)
  memory :heads, width: 6, depth: 32
  memory :tails, width: 6, depth: 32
  # mirror-written replicas for the independent fullness probe
  memory :heads2, width: 6, depth: 32
  memory :tails2, width: 6, depth: 32
  memory :curs2, width: 6, depth: 32
  memory :cnts2, width: 7, depth: 32
  memory :cnts, width: 7, depth: 32
  memory :curs, width: 6, depth: 32

  # entry 36's sweeper cursor (see ProcTable): per-slot counters are
  # memories, and a leftover count is phantom mail in the next program.
  # The 2048-entry flit store needs no sweep — its entries are dead
  # without a nonzero count pointing at them, and `hv` valids are only
  # read under the swept heads/tails window.
  wire :mswp, 5, init: 0

  # scan FSM
  wire :scanning, 1, init: 0
  wire :sc_slot, 5, init: 0
  wire :sc_filter, 8, init: 0
  wire :sc_filtered, 1, init: 0
  wire :sc_i, 6, init: 0
  wire :sc_i_d, 6, init: 0
  wire :sc_live, 1, init: 0
  wire :sc_tail, 6, init: 0
  wire :sc_start, 6, init: 0
  wire :r_done, 1, init: 0
  wire :r_hit, 1, init: 0
  wire :r_len, 6, init: 0
  wire :r_idx, 6, init: 0
  wire :r_mlen, 6, init: 0
  # the matched word must be LATCHED at the hit cycle: the entry store
  # is a sync read, so its output has already moved on by the time the
  # parked context is resumed and reads the result
  wire :r_word, 36, init: 0

  wire :is_enq, 1
  wire :is_start, 1
  wire :is_peek, 1
  wire :is_take, 1
  wire :is_skip, 1

  wire :q_head, 6
  wire :q_tail, 6
  wire :q_cnt, 7
  wire :q_cur, 6
  wire :probe_addr, 11
  wire :hv_q, 16
  wire :probe_valid, 1
  wire :probe_head, 1
  wire :probe_mlen, 6
  wire :probe_hash, 8
  wire :probe_match, 1
  wire :probe_word, 36
  wire :sc_at_end, 1
  wire :sc_step_hit, 1
  wire :sc_rem, 6
  wire :probe_incomplete, 1
  wire :sc_stop_inc, 1

  wire :hv_we, 1
  wire :hv_addr, 11
  wire :hv_data, 16
  wire :used, 6
  wire :cur_we, 1
  wire :cur_addr, 5
  wire :sc_park, 1
  wire :cur_data, 6

  comb do
    is_enq = cmd == 1
    is_start = cmd == 2
    is_peek = cmd == 3
    is_take = cmd == 4
    is_skip = cmd == 5

    q_head = heads[cmd_slot]
    q_tail = tails[cmd_slot]
    q_cnt = cnts[cmd_slot]
    q_cur = curs[cmd_slot]

    count = cnts2[q_slot]
    # messages the receive loop has not yet examined
    unseen = curs2[q_slot] != tails2[q_slot]
    # one entry is always held back so head == tail means empty rather
    # than ambiguous; tombstones below head count as used, deliberately
    used = tails2[q_slot] - heads2[q_slot]
    free = 63 - used
    full = free == 0

    busy = scanning
    done = r_done
    hit = r_hit
    scan_len = r_len

    # the scan probes one entry per cycle; the sync read means the
    # answer for index sc_i lands next cycle, tested as sc_i_d
    probe_addr = sc_slot * 64 + sc_i
    hv_q = hv[probe_addr]
    probe_valid = hv_q[15]
    probe_head = hv_q[14]
    probe_mlen = hv_q[13..8]
    probe_hash = hv_q[7..0]
    # A message is COMPLETE when all `len` of its flits are behind the
    # tail. A local compound send streams one flit per cycle, and the
    # head entry is stamped FIRST — so a receiver polling its own peek
    # can reach a head whose continuations have not landed. Matching it
    # would hand the deserialiser garbage; the pattern would fail on a
    # message that was fine; the skip would step the cursor past it and
    # the message would never be seen again (`notes/52`). Ring indices
    # are 6 bits, so the subtraction is the mod-64 distance for free.
    sc_rem = sc_tail - sc_i_d

    probe_incomplete =
      band(band(probe_valid, probe_head), probe_mlen > sc_rem)

    # a match is a message, never the inside of one — and never the
    # front of one still arriving
    probe_match =
      band(band(band(probe_valid, probe_head), bnot(probe_incomplete)),
        bor(bnot(sc_filtered), probe_hash == sc_filter))

    probe_word = words[probe_addr]
    hit_word = r_word
    hit_idx = r_idx
    hit_len = r_mlen
    rf_word = words[rf_slot * 64 + rf_idx]

    sc_at_end = sc_i_d == sc_tail
    sc_step_hit = band(sc_live, probe_match)

    # ONE write site for the entry store: enqueue stamps, take clears
    hv_we = bor(is_enq, is_take)
    hv_addr = is_enq * (cmd_slot * 64 + q_tail) + is_take * (cmd_slot * 64 + q_cur)
    hv_data = is_enq * (0x8000 + cmd_head * 0x4000 + cmd_len * 256 + cmd_hash)

    # ONE write site for the cursor: start, skip and take reset it, and
    # the scan parks it wherever it stopped.
    #
    # The ADDRESS is the subtlety. Start/skip/take are commands and act
    # on `cmd_slot`. The scan's park is not a command — it happens
    # whenever the scan FSM finishes, which is cycles after the `peek`
    # that started it and has nothing to do with whatever is on the
    # command port at that instant. Addressing it by `cmd_slot` parks
    # one process's cursor in ANOTHER process's slot.
    #
    # With one process receiving, that never happens. With two — which
    # is to say, with a gen_server and a client, the shape all of OTP is
    # made of — it happens constantly: the client's scan parks its
    # cursor in the server's slot and vice versa. The visible symptom
    # was a `recv_take` that did not remove its message, because the
    # take reclaims at the head only when the CURSOR is at the head, and
    # the cursor was a number some other process wrote.
    sc_stop_inc = band(sc_live, probe_incomplete)
    sc_park = band(scanning, bor(sc_step_hit, bor(sc_at_end, sc_stop_inc)))
    cur_we = bor(is_start, bor(is_skip, bor(is_take, sc_park)))
    cur_addr = sc_park * sc_slot + bnot(sc_park) * cmd_slot

    # A take resets the scan to the front of the mailbox, which is what
    # BEAM does after a successful receive — and the front is the NEW
    # head, past the message just reclaimed. Writing zero was right only
    # while the head was zero.
    cur_data =
      is_start * q_head + is_skip * (q_cur + cmd_len) +
        band(is_take, bnot(bor(is_start, is_skip))) * (q_head + cmd_len) +
        band(scanning, sc_step_hit) * sc_i_d +
        band(scanning, sc_stop_inc) * sc_i_d +
        band(scanning, band(sc_at_end, bnot(bor(sc_step_hit, sc_stop_inc)))) * sc_tail
  end

  on :clk do
    if rst == 1 do
      mswp = mswp + 1
      heads[mswp] = 0
      tails[mswp] = 0
      heads2[mswp] = 0
      tails2[mswp] = 0
      curs[mswp] = 0
      curs2[mswp] = 0
      cnts[mswp] = 0
      cnts2[mswp] = 0
      scanning = 0
      sc_i = 0
      sc_i_d = 0
      sc_live = 0
      r_done = 0
      r_hit = 0
      r_len = 0
      r_word = 0
    else
      mswp = 0
      r_done = 0

      if hv_we == 1 do
        hv[hv_addr] = hv_data
      end

      if is_enq == 1 do
        words[cmd_slot * 64 + q_tail] = cmd_word
        tails[cmd_slot] = q_tail + 1
        tails2[cmd_slot] = q_tail + 1
        cnts[cmd_slot] = q_cnt + 1
        cnts2[cmd_slot] = q_cnt + 1
      end

      # take reclaims a whole MESSAGE: the engine passes its length in
      # cmd_len (latched from the peek that found it), the head entry is
      # tombstoned, and head sweeps the continuations away with it
      if is_take == 1 do
        cnts[cmd_slot] = q_cnt - cmd_len
        cnts2[cmd_slot] = q_cnt - cmd_len

        # reclaim immediately when the taken message WAS at the head
        if q_cur == q_head do
          heads[cmd_slot] = q_head + cmd_len
          heads2[cmd_slot] = q_head + cmd_len
        end
      end

      if cur_we == 1 do
        curs[cur_addr] = cur_data
        curs2[cur_addr] = cur_data
      end

      # ---- the scan FSM
      if is_peek == 1 do
        scanning = 1
        sc_slot = cmd_slot
        sc_filter = cmd_filter
        sc_filtered = cmd_filtered
        sc_tail = q_tail
        sc_start = q_cur
        sc_i = q_cur
        sc_live = 0
        r_hit = 0
        r_len = 0
      else
        if scanning == 1 do
          # one probe retires per cycle, one cycle behind its address
          sc_i_d = sc_i
          sc_live = 1

          if sc_step_hit == 1 do
            scanning = 0
            r_done = 1
            r_hit = 1
            r_word = probe_word
            r_idx = sc_i_d
            r_mlen = probe_mlen
            r_len = sc_i_d - sc_start
            sc_live = 0
          else
          if sc_stop_inc == 1 do
            # a head still streaming in: no candidate THIS pass — the
            # cursor parks on it and the next peek finds it whole
            scanning = 0
            r_done = 1
            r_hit = 0
            r_len = sc_i_d - sc_start
            sc_live = 0
          else
            if band(sc_live, sc_at_end) == 1 do
              scanning = 0
              r_done = 1
              r_hit = 0
              r_len = sc_tail - sc_start
              sc_live = 0
            else
              if sc_i != sc_tail do
                sc_i = sc_i + 1
              end
            end
          end
          end
        end
      end
    end
  end
end
