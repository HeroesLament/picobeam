defmodule PicoBEAM.RTL.Heap do
  @moduledoc """
  M2 — the engine heap, CELL-addressed, as `notes/03` designed it.

  "The heap is a uniform two-word cell" is made physical here: two
  36-bit banks (`h0` = even word of every cell, `h1` = odd word), 256
  deep each — two semispaces of 128 cells, the space bit in the depth.
  A cons cell is `{h0: head, h1: tail}` at one address, so:

    * `cons` is ONE cycle: allocate (pointer bump) + write both banks.
      The 1-cycle-allocation claim survives contact with the port.
    * `tset`/`tget` address word `w` as cell `w >> 1`, bank `w & 1` —
      per-bank write enables are the byte-enable trick, no
      read-modify-write.
    * Tuple layout: cell c = `{HDR|arity, elem0}`, cell c+1 =
      `{elem1, elem2}`, ... — element i lives at word i + 1.

  Pointer payloads carry the CELL index within the active semispace
  (v1: 7 bits). `notes/03` specified cells, and for a long time this was
  a live divergence: `Machine` addressed the heap in WORDS, so a
  pointer's payload differed between model and gates and no test could
  report one. The model has moved — `Term.cons/1` and `Term.tuple/1`
  carry the cell index and `alloc` rounds to whole cells — and
  `scripts/mk_ptr.exs` is the testbench that proves the two allocators
  now agree on where every object lands, waste included.

  ## The micro-command interface (one heap op per bundle, rule 2)

  `cmd` is the op byte's low 3 bits VERBATIM — the encoding table put
  the heap group in slot-order so no translation exists:

      0 cons  1 hd  2 tl  3 mktup  4 tset  5 tget  6 tarity

  `pa`/`pb` are the slot's ra/rb port words (cons: head/tail; pointer
  ops: pointer in `pa`, tset's value in `pb`). Reads are sync: the
  result appears on `rd_late` the cycle AFTER `cmd_en` — the
  sequencer's `wb2` state collects it into the destination register.
  For uniformity cons/mktup results also arrive on `rd_late` (their
  pointers are latched), so EVERY heap op is exec + wb2 = 2 sequencer
  cycles at M2. The M3 barrel overlays other contexts on the wb2 slot,
  which is where the extra cycle goes to die.

  Faults (comb, sampled at exec): `bad_tag` (4) for a wrong-tagged
  pointer, `heap_full` (6) when the bump would cross the semispace —
  writes and the bump are suppressed on either.

  Port B is the serialiser's read window (`SerUnit`) and, at M5, the
  collector's. The ehdl one-write-site-per-memory constraint is
  respected by funneling every writer through ONE one-hot write per
  bank.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  input :cmd_en, 1
  input :cmd, 4
  input :pa, 36
  input :pb, 36
  input :i8, 8

  output :rd_late, 36
  output :fault, 1
  output :fault_reason, 8
  output :hp_out, 9
  output :space_out, 1
  output :heap_full, 1

  # -- port B: the serialiser's read window (and the collector's, at M5)
  #
  # BOTH banks come back from one address, because the unit reading
  # through here is walking CELLS: a cons cell is head in h0 and tail in
  # h1 at one address, so returning only h0 would make every list walk
  # cost two reads for no reason. A tuple's header and its first element
  # sit in the same cell too.
  input :b_en, 1
  input :b_addr, 8
  output :b_q0, 36
  output :b_q1, 36

  # Port B WRITES, per bank, at an absolute address. The collector needs
  # them for both halves of a Cheney copy — the object going into
  # to-space, and the forwarding word left behind in from-space — and
  # from-space is not the space the command port is addressing, which is
  # why these carry a whole address rather than a cell in the active
  # semispace.
  #
  # `b_wr` and `b_data` were declared here from the beginning and never
  # implemented; port B was read-only in practice. These replace them.
  input :b_wr0, 1
  input :b_wr1, 1
  input :b_d0, 36
  input :b_d1, 36

  # `flip_en` swaps the semispace. `flip_aptr` is the bump pointer to
  # adopt on the way over: after a collection the live data is ALREADY
  # in the new space, so resetting to zero would hand it out again.
  input :flip_en, 1
  input :flip_aptr, 9
  # `notes/46` split what `flip_en` used to conflate. A collection now
  # moves the allocation base at its START — so the mutator has a fresh
  # semispace to run in while the collection happens — and adopts the
  # collector's bump pointer once per PROCESS after that. The first sets
  # `flip_space`; the rest do not.
  input :flip_space, 1

  # Term tags from `PicoBEAM.Term`, not written here as numbers.
  # `notes/40` found the collector comparing against a 7 that had become
  # `:fun` somewhere else and called sweeping the rest "a separate,
  # mechanical job"; this is that job for the store, and it is the
  # module where a wrong tag would be a wrong POINTER.
  param :T_CONS, default: PicoBEAM.Term.tag_value(:cons)
  param :T_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)
  param :T_HDR, default: PicoBEAM.Term.tag_value(:hdr)
  param :T_FUN, default: PicoBEAM.Term.tag_value(:fun)
  param :T_MAP, default: PicoBEAM.Term.tag_value(:map)
  param :T_BIN, default: PicoBEAM.Term.tag_value(:bin)

  # `badfun` is the reason BEAM gives for calling or unpacking something
  # that is not a fun, and it is an index in the reserved table rather
  # than a number written here (`notes/42`).
  param :A_BADFUN,
    default: Enum.find_index(PicoBEAM.Term.reserved_atoms(), &(&1 == :badfun))

  param :A_BADMAP,
    default: Enum.find_index(PicoBEAM.Term.reserved_atoms(), &(&1 == :badmap))

  memory :h0, width: 36, depth: 256, sync_read: :clk
  memory :h1, width: 36, depth: 256, sync_read: :clk

  # allocation pointer, in cells (0..128)
  # nine bits: an absolute bump pointer has to represent "one past the
  # end", and one past the end of the arena is 256 (`notes/46`).
  wire :aptr, 9, init: 0
  wire :space, 1, init: 0

  # decoded / derived (comb)
  wire :pcell, 8
  wire :i9, 9
  wire :tgw, 9
  wire :tsw, 9
  wire :aptr9, 9
  wire :need9, 9
  wire :lim9, 9
  wire :tscell, 8
  wire :tsbank, 1
  wire :tgcell, 8
  wire :alloc_cells, 8
  wire :is_alloc, 1
  wire :bad_tag, 1
  wire :bad_fun, 1
  wire :bad_map, 1
  wire :bad_bin, 1
  wire :bad_obj, 1
  wire :idx_rd, 1
  wire :is_set, 1
  wire :w0en, 1
  wire :cw0, 1
  wire :cw1, 1
  wire :w0addr, 8
  wire :w0data, 36
  wire :w1en, 1
  wire :w1addr, 8
  wire :w1data, 36
  wire :raddr, 8
  wire :q0, 36
  wire :q1, 36

  # wb2-cycle result state (registered at the cmd edge)
  wire :cmd_d, 4, init: 7
  wire :bank_d, 1, init: 0
  wire :res_ptr_d, 36, init: 0

  comb do
    # `notes/46` — the pointer payload is an ABSOLUTE cell address over
    # the whole 256-cell arena, which is what `Machine` has always meant
    # by it and what a pointer physically is. It used to be seven bits,
    # an index WITHIN the active semispace, with the space bit living in
    # a register beside it — so a pointer could not say which semispace
    # it was in, the model and the gates disagreed about every pointer
    # value in semispace 1, and a concurrent collector (which needs both
    # spaces live at once) could not be built on top of it.
    pcell = pa[7..0]

    # Every index arithmetic below widens its operand BEFORE adding.
    # `x + 1` takes x's own width — Verilog's self-determined rule,
    # which ehdl reproduces — so `i8 + 1` is an eight-bit add and
    # `i8[3..0] + 1` a four-bit one. Written the narrow way, a tset at
    # index 15 wrapped to word 0 and overwrote the tuple HEADER, and a
    # 255-arity mktup computed zero cells and sailed past `heap_full`.
    # Both are the notes/21 lesson, one level down.
    i9 = i8

    # tget: word = i + 1 -> cell/bank
    tgw = i9 + 1
    tgcell = pcell + tgw[7..1]
    # tset takes the FULL eight-bit index. The four-bit ceiling that
    # used to live here is a property of the SLOT ENCODING — `tset`
    # rides the four-field shape and its index is f4 — not of the
    # store, and `encoding.ex` already refuses an index past 15 at
    # assembly time. The deserialiser drives this port directly rather
    # than through an instruction, and a rebuilt tuple can have up to
    # 62 elements, so masking here would have silently folded element
    # 16 onto element 0.
    tsw = i9 + 1
    tscell = pcell + tsw[8..1]
    tsbank = tsw[0]

    # cmd 7 is `mkfun` (`notes/42`): a closure is a tuple-shaped object
    # with an extra word — the header, then `funinfo`, then `nfree`
    # captured variables — so it is 2 + nfree words and the SAME rounding
    # every other object gets. It is an alloc like the other two.
    # cmd 10 is `mkmap` — a flatmap of `i8` pairs. Header, count, then a
    # pair per cell, so it is 2 + 2n words and exactly n + 1 cells: the
    # one object in this machine whose size needs no rounding.
    # cmd 12 is `mkbin` — a binary of `i8` BYTES. v1 stores one byte per
    # word, which is four times the memory a packed layout would use and
    # is deliberate: `binat` and `mset` are BYTE indexed, so the layout is
    # entirely internal and packing four to a word later changes the
    # address arithmetic here and nothing above it — not one compiled
    # program, not one prelude function (`notes/43`).
    is_alloc = bor(cmd == 0, bor(cmd == 3, bor(cmd == 7, bor(cmd == 10, cmd == 12))))

    alloc_cells =
      (cmd == 0) * 1 + (cmd == 3) * ((i9 + 2) >>> 1) +
        bor(cmd == 7, cmd == 12) * ((i9 + 3) >>> 1) +
        (cmd == 10) * (i9 + 1)
    # the bump is compared in nine bits: aptr reaches 128 and a maximal
    # tuple asks for 128 more, and 256 is exactly where an eight-bit
    # sum would wrap back to "plenty of room"
    aptr9 = aptr
    need9 = aptr9 + alloc_cells
    # ...which makes the ceiling absolute too: the end of the semispace
    # the bump pointer is currently in, not a constant 128.
    lim9 = space * 128 + 128
    heap_full = band(band(cmd_en, is_alloc), need9 > lim9)

    # hd/tl want CONS (tag 3); tset/tget/tarity want TUPLE (tag 4)
    bad_tag =
      band(
        cmd_en,
        bor(
          band(bor(cmd == 1, cmd == 2), pa[35..32] != T_CONS),
          # `tset` is the fill-the-fresh-object idiom and a closure is
          # filled with it too, so it takes a tuple OR a fun. `tget` and
          # `tarity` take only a tuple: `element/2` on a fun raises,
          # which is what the separate tag is FOR.
          bor(
            band(cmd == 4,
              band(pa[35..32] != T_TUPLE,
                band(pa[35..32] != T_FUN,
                  band(pa[35..32] != T_MAP, pa[35..32] != T_BIN)))),
            band(bor(cmd == 5, cmd == 6), pa[35..32] != T_TUPLE)
          )
        )
      )

    # cmd 8 is `fget` — a read INSIDE a closure. It rides `tget`'s whole
    # datapath (same offset, same bank select) and differs in exactly one
    # thing: the tag it demands, and therefore the reason it refuses.
    bad_fun = band(cmd_en, band(cmd == 8, pa[35..32] != T_FUN))
    # ...and cmd 9 is `mapat`, the same read again with the same offset
    # and a third tag. Elixir raises `BadMapError` where BEAM raises
    # `{badmap, M}`, and that is not `badarg` either.
    bad_map = band(cmd_en, band(cmd == 9, pa[35..32] != T_MAP))
    # cmd 13 is `binat`, the same read a third time, and `mset` (11) is
    # the write for both — it fills a map or a binary, which are the two
    # objects whose index a program computes.
    bad_bin = band(cmd_en, band(cmd == 13, pa[35..32] != T_BIN))

    bad_obj =
      band(cmd_en, band(cmd == 11, band(pa[35..32] != T_MAP, pa[35..32] != T_BIN)))

    fault = bor(bad_tag, bor(bad_fun, bor(bad_map, bor(bad_bin, bor(bad_obj, heap_full)))))

    fault_reason =
      bad_tag * 4 + bad_fun * A_BADFUN +
        bor(bad_map, bor(bad_bin, bad_obj)) * A_BADMAP + heap_full * 6
    hp_out = aptr
    space_out = space

    # one-hot write funnels — the single write site per bank
    # Port B wins when it writes. It cannot collide with the command
    # port in practice — a collection stops the world, so `cmd_en` is
    # low throughout — but saying which wins is cheaper than trusting
    # that, and keeps the ONE-write-site-per-bank rule visible.
    # cmd 11 is `mset` — `tset`'s write path with a map's tag check and an
    # index that arrived in a register. The offset arithmetic is shared
    # rather than duplicated, which is why `tsw` is computed from `i9`
    # and not from the slot.
    is_set = bor(cmd == 4, cmd == 11)

    cw0 =
      band(band(cmd_en, bnot(fault)),
        bor(is_alloc, band(is_set, tsbank == 0)))

    w0en = bor(b_wr0, cw0)

    w0addr =
      b_wr0 * b_addr +
        band(bnot(b_wr0), 1) *
          (is_alloc * aptr + band(is_set, tsbank == 0) * tscell)

    w0data =
      b_wr0 * b_d0 +
        band(bnot(b_wr0), 1) *
          ((cmd == 0) * pa + (cmd == 3) * (T_HDR * 0x100000000 + i8) +
             (cmd == 7) * (T_HDR * 0x100000000 + 1 + i8) +
             (cmd == 10) * (T_HDR * 0x100000000 + 1 + i8 * 2) +
             (cmd == 12) * (T_HDR * 0x100000000 + 1 + i8) +
             band(is_set, tsbank == 0) * pb)

    cw1 =
      band(band(cmd_en, bnot(fault)),
        bor(cmd == 0,
          bor(cmd == 7, bor(cmd == 10, bor(cmd == 12, band(is_set, tsbank == 1))))))

    w1en = bor(b_wr1, cw1)

    w1addr =
      b_wr1 * b_addr +
        band(bnot(b_wr1), 1) *
          (bor(cmd == 0, bor(cmd == 7, bor(cmd == 10, cmd == 12))) * aptr +
             band(is_set, tsbank == 1) * tscell)

    w1data =
      b_wr1 * b_d1 +
        band(bnot(b_wr1), 1) *
          ((cmd == 0) * pb + (cmd == 7) * pa +
             bor(cmd == 10, cmd == 12) * i8 +
             band(is_set, tsbank == 1) * pb)

    # read address: tget goes through its offset, everything else the cell
    idx_rd = bor(cmd == 5, bor(cmd == 8, bor(cmd == 9, cmd == 13)))

    raddr =
      idx_rd * tgcell + bnot(idx_rd) * pcell
    q0 = h0[raddr]
    q1 = h1[raddr]

    # the wb2-cycle result, selected by the LATCHED command
    rd_late =
      bor(cmd_d == 0, bor(cmd_d == 3, bor(cmd_d == 7, bor(cmd_d == 10, cmd_d == 12)))) *
        res_ptr_d +
        (cmd_d == 1) * q0 + (cmd_d == 2) * q1 +
        bor(cmd_d == 5, bor(cmd_d == 8, bor(cmd_d == 9, cmd_d == 13))) *
          (bank_d * q1 + bnot(bank_d) * q0) +
        (cmd_d == 6) * band(q0, 0xFFFFFFFF)

    b_q0 = h0[b_addr]
    b_q1 = h1[b_addr]
  end

  on :clk do
    if rst == 1 do
      aptr = 0
      space = 0
      # the idle marker. It used to mean "no command has ever run",
      # because 7 was the free code point; 7 is `mkfun` now, so at reset
      # `rd_late` reads `res_ptr_d`, which is zero. Harmless — a wb2 turn
      # only ever follows a real command — and a null pointer is a better
      # thing to read out of a store that has done nothing than whatever
      # `q0` happened to be.
      cmd_d = 7
    else
      if flip_en == 1 do
        if flip_space == 1 do
          space = bnot(space)
        end

        aptr = flip_aptr
      else
        if w0en == 1 do
          h0[w0addr] = w0data
        end

        if w1en == 1 do
          h1[w1addr] = w1data
        end

        if band(band(cmd_en, is_alloc), bnot(heap_full)) == 1 do
          aptr = aptr + alloc_cells
        end

        if cmd_en == 1 do
          cmd_d = cmd
          bank_d = tgw[0]
          res_ptr_d =
            (cmd == 0) * (T_CONS * 0x100000000 + aptr) +
              (cmd == 3) * (T_TUPLE * 0x100000000 + aptr) +
              (cmd == 7) * (T_FUN * 0x100000000 + aptr) +
              (cmd == 10) * (T_MAP * 0x100000000 + aptr) +
              (cmd == 12) * (T_BIN * 0x100000000 + aptr)
        end
      end
    end
  end
end
