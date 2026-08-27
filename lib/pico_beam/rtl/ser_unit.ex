defmodule PicoBEAM.RTL.SerUnit do
  @moduledoc """
  M4 — the serialiser: a term on the heap, walked into a flit stream.

  `PicoBEAM.Serial` is the contract and the oracle; this is the same
  walk in gates, and `scripts/tb_ser.v` proves the two agree the way
  `check_shape_hash.exs` proves it for the hash.

  ## Postfix, and what it buys the hardware

  Flits come out in reverse-Polish order — children, then the marker
  that consumes them. The reason is on the OTHER side: a prefix
  reconstructor meets `HDR|3` before it has any of the three elements,
  so it must allocate the tuple and patch it as they arrive, which
  needs a stack of half-built cells and a resume state per cell. In
  postfix every marker arrives with its children already finished on a
  value stack, so rebuilding is one heap op per marker and nothing is
  ever revisited.

  The cost lands here instead, as an explicit traversal stack — but a
  traversal stack is a counter and an index per frame, which is much
  less than a patch list.

  ## Two passes, because a partial message is worse than a slow one

  Pass 0 walks the term and only COUNTS. Pass 1 walks it again and
  emits. That is twice the heap reads, and it is the right trade for
  two reasons:

  * **The length has to be known before the first flit is written.**
    The mailbox stores a message's length in its head entry, which is
    what lets the match unit step over a whole non-matching message.
    A one-pass serialiser would have to write the head first and patch
    its length afterwards.
  * **Atomicity.** With the count in hand, the engine compares it
    against the mailbox's `free` BEFORE anything is written, so a
    message that does not fit is refused whole. A one-pass-and-patch
    serialiser can discover it is out of room with half a message
    already in the receiver's ring — and the receiver would then
    match a head whose continuations never arrived.

  ## The walk

      0 IDLE    -> nothing in flight
      8 / 9     -> one cycle of sync-read latency on heap port B
      1 ROOT    -> classify the root: an immediate emits and finishes;
                   a compound pushes its frame
      2 STEP    -> top frame: another child to visit, or the marker
      3 READ    -> sync-read latency for a child
      4 CHILD   -> the child word is in hand: emit it, or descend
      6 DESC    -> push the descendant's frame
      5 END     -> a pass is finished
      7 HOLD    -> the count is published; wait to be told it fits

  Every heap read costs two states, not one, because `h_addr` is a
  register: the address a state sets is not presented until the next
  cycle and the data is not back until the one after. Reading `h_q0` in
  the same state that set `addr` reads the PREVIOUS address's data —
  which for the root is whatever the last message left behind.

  Frames are `[arity:6][idx:6][kind:1][cell:7]` in an eight-deep
  LUT-RAM. `arity` for a cons is 2 and its "children" are the two
  banks of one cell, which is why heap port B returns both — a list
  walk costs one read per cell rather than two.

  Depth past eight, or a message past 63 flits, is `:system_limit`
  (reserved atom 9) — checked here and in `PicoBEAM.Serial`, so the
  model and the netlist refuse exactly the same programs.
  """

  use Hw.Component

  # Term tags come from `PicoBEAM.Term`, not from memory. Module
  # attributes are compile-time Elixir and do not survive into a `comb`
  # block, so they reach the datapath as params — which elaboration
  # folds straight back to the literals that used to be written here by
  # hand. `notes/40` is why: the collector spent a milestone comparing
  # against a 7 that had become `:fun` somewhere else.
  param :T_CONS, default: PicoBEAM.Term.tag_value(:cons)
  param :T_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)

  clock :clk, freq: 50.0

  input :rst, 1

  # start a serialisation of `term`; `busy` falls and `done` pulses when
  # the flit stream has been emitted (or `fault` when it cannot be)
  input :start, 1
  input :term, 36

  output :busy, 1
  output :done, 1
  output :fault, 1
  output :fault_reason, 8
  # the flit count, valid from the end of pass 0 onward — the engine
  # compares it against the mailbox's free space before pass 1 emits
  output :count, 7
  output :counted, 1

  # gate pass 1: the engine raises this once it has checked `count`
  # against the target's free space
  input :go_emit, 1

  # ...and `abort` is the other answer to that check. A message that
  # does not fit is not emitted at all: the receiver is doomed with
  # `mailbox_full` and this unit is released for the next sender, which
  # it would never be if HOLD could only ever be left by `go_emit`.
  input :abort, 1

  # Backpressure from the mailbox command port. The port has other
  # claimants — an immediate send retiring at X, the exit-signal
  # emitter — and a flit that loses it must be RE-PRESENTED, not
  # dropped. Freezing the whole FSM does that: `emit`/`emit_word` are
  # registered and hold their value, so the next cycle offers the same
  # flit again.
  #
  # The alternative, giving this unit priority, does not work: the
  # loser would then be a send at X, and X cannot stall.
  input :stall, 1

  # heap port B (both banks of one cell)
  output :h_addr, 8
  input :h_q0, 36
  input :h_q1, 36

  # flit stream out — one flit per cycle, straight into the mailbox
  output :emit, 1
  output :emit_word, 36

  # the root term's shape, for the hash the mailbox stamps on the head
  output :root_arity, 8
  output :root_first, 36

  param :MAX_DEPTH, default: 8
  param :MAX_FLITS, default: 63

  memory :stk, width: 20, depth: 8

  wire :st, 4, init: 0
  wire :sp, 4, init: 0
  wire :pass, 1, init: 0
  wire :cnt, 7, init: 0
  wire :cur, 36, init: 0
  wire :addr, 8, init: 0
  wire :r_done, 1, init: 0
  wire :r_fault, 1, init: 0
  wire :r_reason, 8, init: 0
  wire :r_count, 7, init: 0
  wire :r_counted, 1, init: 0
  wire :r_emit, 1, init: 0
  wire :r_word, 36, init: 0
  wire :r_arity, 8, init: 0
  wire :r_first, 36, init: 0
  wire :saved_term, 36, init: 0

  # top-of-stack, decomposed
  wire :top, 20
  wire :t_cell, 7
  wire :t_kind, 1
  wire :t_idx, 6
  wire :t_arity, 6
  wire :t_done, 1

  # classification of a term word
  wire :cur_tag, 4
  wire :cur_imm, 1
  wire :cur_tup, 1
  wire :cur_cons, 1

  # the child selected by the top frame's index
  wire :child_cell, 8
  wire :child_bank, 1
  wire :child_word, 36
  wire :ch_tag, 4
  wire :ch_imm, 1
  wire :ch_tup, 1

  # Stack write funnel — ONE site, decided COMBINATIONALLY.
  #
  # It has to be comb: a read inside an `on` block sees the PRE-edge
  # value, so a `stk_we` set earlier in the same clocked block is
  # invisible to the memory write at the end of it. Deciding in comb and
  # writing once in the on-block is the shape proc_table and the
  # register window already use, and the reason they use it.
  wire :stk_we, 1
  wire :stk_addr, 3
  wire :stk_data, 20
  wire :new_frame, 20
  wire :bump_frame, 20
  wire :par, 20
  wire :par_bump, 20
  wire :root_push, 1
  wire :desc_push, 1
  wire :imm_bump, 1
  wire :pop_bump, 1

  wire :marker, 36
  wire :idx1, 7
  wire :tw, 7
  wire :ti7, 7
  wire :pi7, 7

  comb do
    busy = st != 0
    done = r_done
    fault = r_fault
    fault_reason = r_reason
    count = r_count
    counted = r_counted
    emit = r_emit
    emit_word = r_word
    root_arity = r_arity
    root_first = r_first
    h_addr = addr

    top = stk[sp[2..0] - 1]
    t_cell = top[6..0]
    t_kind = top[7]
    t_idx = top[13..8]
    t_arity = top[19..14]
    t_done = t_idx == t_arity

    cur_tag = cur[35..32]
    cur_tup = cur_tag == T_TUPLE
    cur_cons = cur_tag == T_CONS
    cur_imm = bnot(bor(cur_tup, cur_cons))

    # A tuple's element i is word i+1: cell + (i+1)>>1, bank (i+1)&1.
    # A cons's children ARE the two banks of its own cell, so its
    # "word index" is the child index itself. Widened before the add,
    # per notes/21: `x + 1` takes x's width.
    idx1 = t_idx
    tw = idx1 + 1
    child_cell = t_kind * t_cell + bnot(t_kind) * (t_cell + tw[6..1])
    child_bank = t_kind * t_idx[0] + bnot(t_kind) * tw[0]
    child_word = child_bank * h_q1 + bnot(child_bank) * h_q0

    ch_tag = child_word[35..32]
    ch_tup = ch_tag == T_TUPLE
    ch_imm = bnot(bor(ch_tup, ch_tag == T_CONS))

    # tuple marker is the tuple's own header word; cons has none, so it
    # gets the one wire-only tag in the term space
    marker = t_kind * 0xD00000000 + bnot(t_kind) * (0x900000000 + t_arity)

    # a frame for whatever `cur` points at: a tuple's arity is its
    # header's payload, a cons's is always two
    new_frame =
      cur_tup * (h_q0[5..0] * 16384 + cur[6..0]) +
        bnot(cur_tup) * (2 * 16384 + 128 + cur[6..0])

    # `idx + 1` widened before the add — six bits would wrap a 63-arity
    # tuple's last index back to zero and walk it forever
    ti7 = t_idx
    bump_frame = band(top, 0xFC0FF) + (ti7 + 1) * 256

    par = stk[sp[2..0] - 2]
    pi7 = par[13..8]
    par_bump = band(par, 0xFC0FF) + (pi7 + 1) * 256

    # four writers, one site, mutually exclusive by state
    root_push = band(st == 1, bnot(cur_imm))
    desc_push = st == 6
    imm_bump = band(st == 4, ch_imm)
    pop_bump = band(st == 2, band(t_done, sp != 1))

    stk_we = bor(root_push, bor(desc_push, bor(imm_bump, pop_bump)))

    stk_addr =
      desc_push * sp[2..0] + imm_bump * (sp[2..0] - 1) + pop_bump * (sp[2..0] - 2)

    stk_data =
      bor(root_push, desc_push) * new_frame + imm_bump * bump_frame +
        pop_bump * par_bump
  end

  on :clk do
    r_done = 0
    r_emit = 0

    if stall == 1 do
      # hold everything, including the flit already on the wire
      r_emit = r_emit
      r_word = r_word
    else

    if rst == 1 do
      st = 0
      sp = 0
      cnt = 0
      pass = 0
      r_fault = 0
      r_counted = 0
    else
      hdl_case <<st::4>> do
        # ---- 0: idle
        <<0::4>> ->
          if start == 1 do
            cur = term
            saved_term = term
            pass = 0
            cnt = 0
            sp = 0
            r_fault = 0
            r_counted = 0
            r_arity = 0
            r_first = 0
            addr = term[6..0]
            st = 8
          end

        # ---- 8: the root's cell is addressed; wait for it
        <<8::4>> ->
          st = 1

        # ---- 1: classify the root (its cell has been addressed)
        <<1::4>> ->
          if cur_imm == 1 do
            # an immediate is the whole message
            cnt = cnt + 1

            if pass == 1 do
              r_emit = 1
              r_word = cur
            end

            st = 5
          else
            # h_q0/h_q1 are valid now: a tuple's header is h_q0, its
            # first element h_q1 — which is exactly what the shape hash
            # wants, and it is already in hand
            # the tuple's header and its first element are both in this
            # cell, which is exactly what the shape hash wants — so it
            # costs nothing to publish them here
            if cur_tup == 1 do
              r_arity = h_q0[7..0]
              r_first = h_q1
            else
              r_arity = 0
              r_first = h_q0
            end

            sp = 1
            st = 2
          end

        # ---- 2: address the top frame's next child (or finish it)
        <<2::4>> ->
          if t_done == 1 do
            cnt = cnt + 1

            if pass == 1 do
              r_emit = 1
              r_word = marker
            end

            sp = sp - 1

            # the parent has now finished this child; the bump itself
            # is in comb (pop_bump)
            if sp == 1 do
              st = 5
            else
              st = 2
            end
          else
            addr = child_cell
            st = 3
          end

        # ---- 3: one cycle of sync-read latency
        <<3::4>> ->
          st = 4

        # ---- 4: the child word is in hand
        <<4::4>> ->
          if ch_imm == 1 do
            cnt = cnt + 1

            if pass == 1 do
              r_emit = 1
              r_word = child_word
            end

            st = 2
          else
            if sp == MAX_DEPTH do
              r_fault = 1
              r_reason = 9
              r_done = 1
              st = 0
            else
              # descend: address the child's own cell, and remember
              # whether it is a tuple (whose arity must be read) or a
              # cons (whose arity is two)
              cur = child_word
              addr = child_word[6..0]
              st = 9
            end
          end

        # ---- 9: the descendant's cell is addressed; wait for it
        <<9::4>> ->
          st = 6

        # ---- 6: the cell is in hand; comb pushes its frame this cycle
        # (desc_push), reading the arity out of h_q0
        <<6::4>> ->
          sp = sp + 1
          st = 2

        # ---- 5: a pass is finished
        <<5::4>> ->
          if cnt > MAX_FLITS do
            r_fault = 1
            r_reason = 9
            r_done = 1
            r_counted = 0
            st = 0
          else
            if pass == 0 do
              r_count = cnt
              r_counted = 1
              st = 7
            else
              r_done = 1
              r_counted = 0
              st = 0
            end
          end

        # ---- 7: hold the count until the engine says the message fits
        <<7::4>> ->
          if go_emit == 1 do
            pass = 1
            cnt = 0
            sp = 0
            cur = saved_term
            addr = saved_term[6..0]
            st = 8
          end

          if abort == 1 do
            r_counted = 0
            st = 0
          end

        <<_::4>> ->
          st = 0
      end

      if stk_we == 1 do
        stk[stk_addr] = stk_data
      end
    end
    end
  end
end
