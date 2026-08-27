defmodule PicoBEAM.RTL.DeserUnit do
  @moduledoc """
  M4 — the deserialiser: a flit stream in the mailbox, rebuilt on the
  receiver's heap.

  The inverse of `SerUnit`, against the same oracle
  (`PicoBEAM.Serial.rebuild/2`).

  ## Why this side is the simple one

  Postfix is the whole reason. Every marker arrives with its children
  already finished and sitting on a value stack, so the FSM is:

      an immediate  ->  push it
      WCONS         ->  pop tail, pop head, `cons`, push the pointer
      HDR|n         ->  `mktup n`, `tset` n values off the stack, push

  Nothing is ever allocated before it can be filled, nothing is
  patched, and there is no per-cell resume state. Exactly one value is
  left when the last flit is consumed, and that is the message.

  A prefix format would have inverted this: the reconstructor would
  meet `HDR|3` first, have to allocate an empty tuple, and then track
  "I am filling element 1 of the tuple at cell 12, which is itself
  element 0 of the tuple at cell 9" — a stack of half-built cells with
  a write-back position each. The cost of postfix is a traversal stack
  in `SerUnit`; the cost of prefix would have been a patch stack HERE,
  plus the same traversal stack over there anyway.

  ## The value stack is 64 deep, and that is not a new limit

  Depth of NESTING is bounded at 8 by `SerUnit`. The value stack is
  bounded by something else — how many finished siblings can be waiting
  for their marker at once — which for a flat 62-element tuple is 62.
  Since a message is at most 63 flits (`PicoBEAM.Serial`), 64 entries
  can never overflow, so this stack needs no bound check of its own.

  ## Two ports, no contention with one exception

  Flits come through the mailbox's dedicated rebuild port, which is
  separate from its command port, so reading a message never delays
  someone else's enqueue.

  Heap ops are the exception: there is one heap command port and the X
  stage owns it. So this unit RAISES a request and waits for a grant —
  the engine gives priority to the running bundle, and the rebuilding
  context is parked anyway, so a stall costs it nothing that was not
  already spent. Priority, not arbitration: the eighth time.
  """

  use Hw.Component

  # Term tags come from `PicoBEAM.Term`, not from memory. Module
  # attributes are compile-time Elixir and do not survive into a `comb`
  # block, so they reach the datapath as params — which elaboration
  # folds straight back to the literals that used to be written here by
  # hand. `notes/40` is why: the collector spent a milestone comparing
  # against a 7 that had become `:fun` somewhere else.
  param :T_WCONS, default: PicoBEAM.Term.tag_value(:wcons)
  param :T_HDR, default: PicoBEAM.Term.tag_value(:hdr)

  clock :clk, freq: 50.0

  input :rst, 1

  # rebuild the message of `len` flits starting at `idx` in `slot`
  input :start, 1
  input :slot, 5
  input :idx, 6
  input :len, 6

  output :busy, 1
  output :done, 1
  output :result, 36

  # mailbox rebuild port
  output :rf_slot, 5
  output :rf_idx, 6
  input :rf_word, 36

  # heap command port, shared with the X stage by priority
  output :h_req, 1
  output :h_cmd, 3
  output :h_pa, 36
  output :h_pb, 36
  output :h_i8, 8
  input :h_grant, 1
  input :h_rd_late, 36

  memory :vstk, width: 36, depth: 64

  wire :st, 4, init: 0
  wire :i, 7, init: 0
  wire :sp, 7, init: 0
  wire :nn, 7, init: 0
  wire :j, 7, init: 0
  wire :tptr, 36, init: 0
  # `start` is a pulse and everything that came with it is derived from
  # whichever seat the sequencer happened to be serving that cycle. One
  # cycle later `take_seat` has rotated and the inputs describe someone
  # else — so they are LATCHED here rather than read throughout the
  # rebuild. (Read live, `len` became another seat's length and the
  # rebuild finished after one flit, handing back the atom that happened
  # to be first in the message.)
  wire :r_slot, 5, init: 0
  wire :r_idx, 6, init: 0
  wire :r_len, 6, init: 0
  wire :r_done, 1, init: 0
  wire :r_result, 36, init: 0

  wire :flit, 36
  wire :f_tag, 4
  wire :f_wcons, 1
  wire :f_hdr, 1
  wire :f_imm, 1
  wire :f_arity, 7

  wire :v_top, 36
  wire :v_snd, 36
  wire :v_elem, 36

  wire :vs_we, 1
  wire :vs_addr, 6
  wire :vs_data, 36

  comb do
    busy = st != 0
    done = r_done
    result = r_result

    rf_slot = r_slot
    rf_idx = r_idx + i[5..0]

    flit = rf_word
    f_tag = flit[35..32]
    f_wcons = f_tag == T_WCONS
    f_hdr = f_tag == T_HDR
    f_imm = bnot(bor(f_wcons, f_hdr))
    f_arity = flit[6..0]

    v_top = vstk[sp[5..0] - 1]
    v_snd = vstk[sp[5..0] - 2]
    # tset writes element j, which is the j-th value counting up from
    # the base of this tuple's run on the stack
    v_elem = vstk[sp[5..0] - nn[5..0] + j[5..0]]

    # heap request: cons at state 3's entry, mktup at 4's, tset at 5
    h_req = bor(st == 3, bor(st == 4, st == 5))
    h_cmd = (st == 3) * 0 + (st == 4) * 3 + (st == 5) * 4
    h_pa = (st == 3) * v_snd + (st == 5) * tptr
    h_pb = (st == 3) * v_top + (st == 5) * v_elem
    h_i8 = (st == 4) * f_arity[5..0] + (st == 5) * j[5..0]

    # ONE write site for the value stack
    vs_we = bor(band(st == 2, f_imm), bor(st == 6, st == 7))
    vs_addr =
      band(st == 2, f_imm) * sp[5..0] +
        (st == 6) * (sp[5..0] - 2) +
        (st == 7) * (sp[5..0] - nn[5..0])

    # a cons pointer comes straight off rd_late; a TUPLE pointer was
    # latched at mktup and must come from `tptr` — by the time the last
    # `tset` retires, rd_late is that tset's (empty) result, not the
    # pointer. Reading rd_late here would push zero and lose the tuple.
    vs_data =
      band(st == 2, f_imm) * flit + (st == 6) * h_rd_late + (st == 7) * tptr
  end

  on :clk do
    r_done = 0

    if rst == 1 do
      st = 0
      i = 0
      sp = 0
    else
      hdl_case <<st::4>> do
        <<0::4>> ->
          if start == 1 do
            i = 0
            sp = 0
            r_slot = slot
            r_idx = idx
            r_len = len
            st = 1
          end

        # ---- 1: the flit address is presented; the mailbox read is sync
        <<1::4>> ->
          st = 2

        # ---- 2: the flit is in hand
        <<2::4>> ->
          if f_imm == 1 do
            # comb pushed it this cycle
            sp = sp + 1
            i = i + 1

            if i + 1 == r_len do
              st = 8
            else
              st = 1
            end
          else
            if f_wcons == 1 do
              st = 3
            else
              nn = f_arity
              st = 4
            end
          end

        # ---- 3: cons issued; wait for the grant, then for rd_late
        <<3::4>> ->
          if h_grant == 1 do
            st = 6
          end

        # ---- 6: the cons pointer is on rd_late; comb writes it over
        # the head's slot, and the tail's slot goes away with sp
        <<6::4>> ->
          sp = sp - 1
          i = i + 1

          if i + 1 == r_len do
            st = 8
          else
            st = 1
          end

        # ---- 4: mktup issued
        <<4::4>> ->
          if h_grant == 1 do
            st = 9
          end

        # ---- 9: the tuple pointer is on rd_late; keep it and start
        # writing elements
        <<9::4>> ->
          tptr = h_rd_late
          j = 0

          if nn == 0 do
            st = 7
          else
            st = 5
          end

        # ---- 5: one tset per grant
        <<5::4>> ->
          if h_grant == 1 do
            if j + 1 == nn do
              st = 7
            else
              j = j + 1
            end
          end

        # ---- 7: the tuple is built; comb pushes it over the base of
        # its own elements
        <<7::4>> ->
          sp = sp - nn + 1
          i = i + 1

          if i + 1 == r_len do
            st = 8
          else
            st = 1
          end

        # ---- 8: one value left, and it is the message
        <<8::4>> ->
          r_result = vstk[0]
          r_done = 1
          st = 0

        <<_::4>> ->
          st = 0
      end

      if vs_we == 1 do
        vstk[vs_addr] = vs_data
      end
    end
  end
end
