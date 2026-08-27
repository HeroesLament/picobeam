defmodule PicoBEAM.RTL.Collector do
  @moduledoc """
  M5 — the per-engine collector: Cheney copying between two semispaces.

  `notes/03` designed the heap as two semispaces with a space bit in the
  depth, and `heap.ex` has carried `flip_en` and an unused port B since
  M2 waiting for this. `Machine` has modelled the algorithm since M1
  (`collect/2`, `cheney_scan/3`), so this unit has an oracle rather than
  an argument to check itself against.

  ## Why it stopped being optional

  Until `notes/22`'s postscript, `send` shipped a POINTER: a compound
  message cost the receiver nothing, because there was nothing to
  allocate. Now every received compound message is a fresh copy on the
  receiver's heap. Measured on the model, a loop that sends a 3-tuple to
  itself collects **once every ~1,140 cycles** on a 128-cell semispace.
  Without a collector the same loop dies of `heap_full` after about
  thirty iterations.

  That measurement also says what to optimise. **Live data at each
  collection is 8 words.** The copy is nothing; the cost is entirely in
  walking the ROOTS, which is a fixed price whatever survives.

  ## The roots are the engine's problem, deliberately

  This unit does not know where roots live — they are spread over the
  register windows, the frame RAM, the mailboxes and a dozen per-seat
  latches — and it should not. The engine streams them in one at a time
  and gets each one back rewritten:

      root_en / root_word   ->   root_ack / root_new

  and raises `roots_done` when it has presented the last one. That keeps
  root enumeration where the knowledge is, and keeps this module a pure
  statement of Cheney's algorithm, testable on a synthetic root list.

  ## The algorithm, in three phases

      1 EVACUATE ROOTS   each root in turn; a pointer's object is copied
                         to to-space and a FORWARDING word is left in
                         its old cell, so the second reference to the
                         same object finds the copy instead of making
                         another
      2 CHENEY SCAN      walk to-space from the bottom; every pointer
                         found inside a copied object is itself
                         evacuated, which appends to the very region
                         being walked. The scan finishes when it catches
                         up with the bump pointer — that IS the
                         termination proof, and it is why Cheney needs
                         no mark stack
      3 FLIP             the heap adopts the new space AND the new bump
                         pointer (`flip_aptr`): the live data is already
                         over there, so resetting to zero would hand it
                         out twice

  ## The forwarding tag

  `Term`'s `:fwd`, which is **0xA**, and it comes from `Term` rather than
  being written here as a number.

  It was 7 when this module was written, and 7 is now `:fun`. Nothing had
  broken, because no program could make a fun — but the first closure on
  a heap would have looked to this unit like a forwarding pointer, and it
  would have followed it into whatever the payload happened to address.
  A silent wrong answer, waiting for a feature two milestones away.

  So the tags are `param`s with their defaults read out of `Term`
  (`notes/40`). Elaboration folds them to the same literals the hand
  written ones were; what changes is that there is one place where a tag
  number is decided, and the RTL is downstream of it.

  It is written into bank 0 of the evacuated cell, which is safe because
  that cell is dead the moment its contents have been copied — a cons's
  head or a tuple's header, neither of which anyone will read again.

  ## What this unit does NOT do

  It does not decide when to run, it does not stop the world, and it
  does not enumerate roots. Those are the engine's, and they are what
  turns a correct algorithm into a correct collector.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # a collection is beginning; `from_space` is the side being evacuated
  input :start, 1
  input :from_space, 1

  # ...and where to-space's bump pointer is RIGHT NOW. `notes/46` — a
  # collection is a sequence of per-process collections sharing one
  # to-space, and the mutator allocates into the same space between
  # them. So the cursor cannot restart at the bottom each time: it
  # starts where the heap's allocation pointer has got to, and the heap
  # adopts it back when this process is done.
  input :start_hp, 9

  output :busy, 1
  output :done, 1

  # to-space bump pointer, in cells — what `flip_aptr` must adopt
  # nine bits, not eight. A bump pointer has to be able to hold ONE PAST
  # the end of the space it is in — that is what "full" looks like — and
  # one past the end of an absolute 256-cell arena is 256 (`notes/46`).
  # At eight bits it wrapped to zero and the allocator handed out cell 0
  # of the semispace it had just left.
  output :to_hp, 9

  # live-exceeds-semispace: nothing was reclaimed and the engine must
  # fault the allocating process with `heap_full`
  output :overflow, 1

  # ---- the root stream
  # `root_en` presents one word; `root_ack` pulses with `root_new` valid
  input :root_en, 1
  input :root_word, 36
  output :root_ack, 1
  output :root_new, 36
  # every root has been presented; run the scan
  input :roots_done, 1

  # ---- heap port B
  output :h_addr, 8
  output :h_wr0, 1
  output :h_wr1, 1
  output :h_d0, 36
  output :h_d1, 36
  input :h_q0, 36
  input :h_q1, 36

  param :CELLS, default: 128

  # Term tags, from `PicoBEAM.Term` and not from memory. Module
  # attributes are compile-time Elixir and do not survive into a `comb`
  # block, so they reach the datapath as params — which elaboration
  # folds back to literals, so this costs nothing but correctness.
  param :T_CONS, default: PicoBEAM.Term.tag_value(:cons)
  param :T_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)
  param :T_FUN, default: PicoBEAM.Term.tag_value(:fun)
  param :T_MAP, default: PicoBEAM.Term.tag_value(:map)
  param :T_BIN, default: PicoBEAM.Term.tag_value(:bin)
  param :T_FWD, default: PicoBEAM.Term.tag_value(:fwd)

  wire :st, 4, init: 0
  # to-space bump pointer and the scan cursor, both cell indices
  wire :thp, 9, init: 0
  wire :scan, 9, init: 0
  # the word being evacuated, and where its answer goes
  wire :ev_word, 36, init: 0
  wire :ev_ret, 2, init: 0
  wire :ev_cells, 8, init: 0
  wire :ev_i, 8, init: 0
  wire :ev_src, 8, init: 0
  wire :ev_dst, 8, init: 0
  wire :r_ack, 1, init: 0
  wire :r_new, 36, init: 0
  wire :r_done, 1, init: 0
  wire :r_ovf, 1, init: 0
  wire :addr, 8, init: 0
  wire :wr0, 1, init: 0
  wire :wr1, 1, init: 0
  wire :d0, 36, init: 0
  wire :d1, 36, init: 0
  # the scan's held cell contents while its two banks are processed
  wire :sc_q0, 36, init: 0
  wire :sc_q1, 36, init: 0

  wire :to_base, 8
  wire :need_c, 9
  wire :lim_c, 9
  wire :to_base9, 9
  wire :ev_tag, 4
  wire :ev_ptr, 1
  wire :q0_tag, 4
  wire :fwd_hit, 1
  # "is this word a pointer?", asked of the three places that ask it.
  # It used to be asked FOUR times and answered two different ways:
  # state 1 spelled out the five tags, states 7, 8 and 12 tested `== 3`
  # and `== 4`. `notes/46` has what that cost.
  wire :rw_ptr, 1
  wire :q0_ptr, 1
  wire :sq1_ptr, 1
  wire :obj_cells, 8
  wire :arity8, 8

  comb do
    busy = st != 0
    done = r_done
    to_hp = thp
    overflow = r_ovf
    root_ack = r_ack
    root_new = r_new
    h_addr = addr
    h_wr0 = wr0
    h_wr1 = wr1
    h_d0 = d0
    h_d1 = d1

    # `notes/46` — pointers are absolute cell addresses now, so a
    # from-space address needs no base added to it: the pointer IS the
    # address. `to_base` survives because the to-space CURSOR still has
    # to start somewhere, and where it starts is the whole point.
    to_base = bnot(from_space) * CELLS
    # Widen BEFORE adding. `heap.ex`'s moduledoc has this lesson in it
    # already — EHDL reproduces Verilog's self-determined width rule, so
    # `to_base + CELLS` is an EIGHT-bit add and 128 + 128 is zero. An
    # overflow limit of zero means every collection overflows on its
    # first object, which is a collector that reclaims nothing and an
    # engine that collects forever.
    to_base9 = to_base
    need_c = thp + obj_cells
    lim_c = to_base9 + CELLS

    ev_tag = ev_word[35..32]
    # `notes/42` — a fun is a boxed object laid out exactly like a tuple,
    # so it is a pointer here and it is sized here by the same formula.
    # This module has already been the place where a tag drifted once
    # (`notes/40`); the fix then was params, and the point of params is
    # that adding a third pointer tag is one line in one place.
    # Kept, unused, as the shape the three tests below share.
    ev_ptr =
      bor(ev_tag == T_CONS,
        bor(ev_tag == T_TUPLE,
          bor(ev_tag == T_FUN, bor(ev_tag == T_MAP, ev_tag == T_BIN))))

    q0_tag = h_q0[35..32]
    fwd_hit = q0_tag == T_FWD

    # The same question `ev_ptr` asks, asked of the root being offered,
    # of the cell the scan is holding, and of that cell's odd bank. One
    # expression per SIGNAL because EHDL has no functions in a `comb`
    # block — but one LIST of tags, which is the part that drifted.
    # ...and a pointer is only ours to move if it is in FROM-space.
    # A pointer already in to-space is either a copy this collection
    # made or an object allocated since it began; following it would
    # copy live to-space data as if it were garbage and leave a
    # forwarding word in the middle of it.
    #
    # Under a stop-the-world collection every LIVE pointer is in
    # from-space, so this filter only ever rejects rubbish — a stale pad
    # word inside an even-arity tuple, which `RTL.Heap` does not write
    # and the model does. It became load-bearing the moment pointers
    # went absolute (`notes/46`): under the old relative scheme a stale
    # pad was ALWAYS read as a from-space address and could only waste a
    # copy, and it can now name a live to-space cell.
    #
    # It is also the primitive the concurrent collector is built on.
    rw_ptr =
      band(root_word[7] == from_space,
        bor(root_word[35..32] == T_CONS,
          bor(root_word[35..32] == T_TUPLE,
            bor(root_word[35..32] == T_FUN,
              bor(root_word[35..32] == T_MAP, root_word[35..32] == T_BIN)))))

    q0_ptr =
      band(h_q0[7] == from_space,
        bor(q0_tag == T_CONS,
          bor(q0_tag == T_TUPLE,
            bor(q0_tag == T_FUN, bor(q0_tag == T_MAP, q0_tag == T_BIN)))))

    sq1_ptr =
      band(sc_q1[7] == from_space,
        bor(sc_q1[35..32] == T_CONS,
          bor(sc_q1[35..32] == T_TUPLE,
            bor(sc_q1[35..32] == T_FUN,
              bor(sc_q1[35..32] == T_MAP, sc_q1[35..32] == T_BIN)))))

    # a cons is one cell; a tuple of arity n is 1 + n words, which is
    # (n + 2) >> 1 cells — the same rounding `Term.cell_round/1` does on
    # the model side, and the reason both run out of heap together
    arity8 = h_q0[7..0]
    obj_cells =
      (ev_tag == T_CONS) * 1 +
        bor(ev_tag == T_TUPLE,
          bor(ev_tag == T_FUN, bor(ev_tag == T_MAP, ev_tag == T_BIN))) *
          ((arity8 + 2) >>> 1)
  end

  on :clk do
    r_ack = 0
    r_done = 0
    wr0 = 0
    wr1 = 0

    if rst == 1 do
      st = 0
      thp = 0
      scan = 0
      r_ovf = 0
    else
      hdl_case <<st::4>> do
        # ---- 0: idle
        <<0::4>> ->
          if start == 1 do
            thp = start_hp
            scan = start_hp
            r_ovf = 0
            st = 1
          end

        # ---- 1: waiting for a root, or for the engine to say there are
        # no more. An immediate answers in this state and never leaves it.
        <<1::4>> ->
          if root_en == 1 do
            ev_word = root_word
            ev_ret = 0

            if rw_ptr == 1 do
              addr = root_word[7..0]
              st = 2
            else
              r_ack = 1
              r_new = root_word
            end
          else
            if roots_done == 1 do
              st = 6
            end
          end

        # ---- 2: the address is presented; the data lands next cycle
        <<2::4>> ->
          st = 3

        # ---- 3: forwarded already, or a fresh copy
        <<3::4>> ->
          if fwd_hit == 1 do
            # someone else already moved it; take their answer
            r_new = ev_tag * 0x100000000 + h_q0[7..0]
            r_ack = band(ev_ret == 0, 1)
            st = 12 * (ev_ret != 0) + 1 * (ev_ret == 0)
          else
            ev_cells = obj_cells
            ev_i = 0
            ev_src = ev_word[7..0]
            ev_dst = thp

            if need_c > lim_c do
              # live data does not fit: nothing can be reclaimed
              r_ovf = 1
              r_done = 1
              st = 0
            else
              thp = thp + obj_cells
              st = 4
            end
          end

        # ---- 4: present the source cell of the copy.
        #
        # `addr` is a REGISTER, so the address a state sets is not on the
        # memory until the next cycle and the data is not back until the
        # one after — every heap read costs two states here for the same
        # reason `SerUnit`'s moduledoc says it costs two there. Sampling
        # in state 5 without state 11 read the PREVIOUS address's data,
        # which for the first cell of an object is the right answer by
        # accident (state 1 had already addressed it for the tag check)
        # and for every cell after it is not.
        <<4::4>> ->
          addr = ev_src + ev_i
          st = 11

        # ---- 11: the address is on the memory; the data lands next
        <<11::4>> ->
          st = 5

        # ---- 5: the cell is in hand; write it to to-space. On the FIRST
        # cell, the forwarding word replaces the source's bank 0 — after
        # it has been read, which is why this is not a race.
        <<5::4>> ->
          addr = ev_dst + ev_i
          wr0 = 1
          wr1 = 1
          d0 = h_q0
          d1 = h_q1
          ev_i = ev_i + 1

          if ev_i + 1 == ev_cells do
            st = 9
          else
            st = 4
          end

        # ---- 9: leave the forwarding word behind
        <<9::4>> ->
          addr = ev_src
          wr0 = 1
          # the forwarding word: `Term`'s `:fwd` tag over the new cell
          d0 = T_FWD * 0x100000000 + ev_dst
          r_new = ev_tag * 0x100000000 + ev_dst
          r_ack = band(ev_ret == 0, 1)
          st = 12 * (ev_ret != 0) + 1 * (ev_ret == 0)

        # ---- 6: the scan. Present the cell under the cursor.
        <<6::4>> ->
          if scan == thp do
            r_done = 1
            st = 0
          else
            addr = scan
            st = 13
          end

        # ---- 13: same two-state read, for the scan's cell
        <<13::4>> ->
          st = 7

        # ---- 7: hold the cell, then evacuate bank 0 if it is a pointer
        <<7::4>> ->
          sc_q0 = h_q0
          sc_q1 = h_q1

          if q0_ptr == 1 do
            ev_word = h_q0
            ev_ret = 1
            addr = h_q0[7..0]
            st = 2
          else
            st = 8
          end

        # ---- 12: an evacuation launched by the scan has answered
        <<12::4>> ->
          if ev_ret == 1 do
            sc_q0 = r_new
            ev_ret = 0

            if sq1_ptr == 1 do
              ev_word = sc_q1
              ev_ret = 2
              addr = sc_q1[7..0]
              st = 2
            else
              st = 10
            end
          else
            sc_q1 = r_new
            ev_ret = 0
            st = 10
          end

        # ---- 8: bank 0 was not a pointer; try bank 1
        <<8::4>> ->
          if sq1_ptr == 1 do
            ev_word = sc_q1
            ev_ret = 2
            addr = sc_q1[7..0]
            st = 2
          else
            st = 10
          end

        # ---- 10: write the (possibly rewritten) cell back and advance
        <<10::4>> ->
          addr = scan
          wr0 = 1
          wr1 = 1
          d0 = sc_q0
          d1 = sc_q1
          scan = scan + 1
          st = 6

        <<_::4>> ->
          st = 0
      end
    end
  end
end
