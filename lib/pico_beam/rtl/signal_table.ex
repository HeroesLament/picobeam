defmodule PicoBEAM.RTL.SignalTable do
  @moduledoc """
  M5 — links, monitors, and the exit-signal fan-out. `notes/13`'s
  mechanism half, in one unit because it is one walk.

  (Was `LinkTable` until monitors arrived. A component that holds both
  and drives every signal the machine emits should not be named after
  half of what it does.)

  ## Three relations, three bitmaps, one walk

      links[p]   the slots p is linked to        -> exit signals
      mwatch[p]  the monitor ENTRIES watching p  -> DOWN messages
      mown[p]    the monitor entries p created   -> cleanup

  A death walks all three in turn, one bit per cycle, lowest set bit
  first. `notes/13` promises propagation is "links × ring diameter";
  scanning 32 slots regardless would make it *slots* × diameter, a
  different and worse number that also happens to be bounded. The
  machine's whole claim is a stated WCET, so it pays for the constant
  it states: `m & -m` to isolate, five reduction-ORs to index.

  `mown` exists for the case that is easy to forget. When a WATCHER
  dies, its monitor entries have to go — otherwise the entry leaks, and
  worse, it fires later at a slot that has since been recycled and
  drops a `DOWN` into a stranger's mailbox. Without a reverse index
  that cleanup is a 32-entry scan at every death; with one it is
  monitors-long like everything else.

  ## Why links need no PID serial and monitors do

  `links` is a bitmap of SLOTS, which carries no incarnation — and that
  is sound only because a link cannot outlive either end: death clears
  both sides, and registration checks the serial (the engine refuses a
  `link` to a stale pid and answers `noproc`).

  A monitor is different: it hands the watcher a **ref**, and the
  `DOWN` that eventually arrives must carry that same ref back so the
  watcher can tell which of its monitors fired. So monitors are
  entries, not bits — 32 of them, each holding `{ref, watcher, target}`
  — and the bitmaps index entries rather than slots.

  ## What leaves here

  `sig_en` with `sig_kind` (0 = exit signal, 1 = DOWN), `sig_slot`,
  `sig_from`, `sig_reason` and `sig_ref`. The engine decides what each
  means, because the answer depends on state it owns:

      kind 0, target does not trap  ->  the target dies, same reason
      kind 0, target traps          ->  {'EXIT', From, Reason}
      kind 1 (always)               ->  {'DOWN', Ref, From, Reason}

  A `DOWN` never kills. That is the whole difference between watching
  something and being tied to it, and it is why `monitor` is what
  `gen_server:call` uses and `link` is what a supervisor uses.

  Both messages are flits of immediates in `PicoBEAM.Serial`'s postfix
  wire format, so `notes/13`'s allocation-free rule holds: a process
  dying with a full heap can still tell its supervisor why.

  `normal` (reserved atom 0) is the one reason that kills nobody — but
  it still travels: a TRAPPING link partner receives {'EXIT', From,
  normal} (the model always delivered it; the source-side filter that
  used to live here was hiding those), and a monitor always raises its
  `DOWN`, because it reports the fact of death rather than judging it.
  The drop-for-non-trappers decision belongs to the delivery end.

  ## The remote store (notes/53 Phase 4)

  The bitmaps above index LOCAL slots; a relation whose other end
  lives on another engine is 16 entries of {peer pid, kind, owner,
  ref}. The death walk gains a fourth phase over them: kind 0 emits an
  exit signal to `sig_peer`, kind 1 a DOWN — same handshake, with
  `sig_remote` telling the engine to put it on the ring rather than
  deliver it here. Cross-engine monitors are held at the TARGET (the
  model's `watchers` list); the watcher side stores nothing and a DOWN
  aimed at a watcher that died first dead-letters on arrival, exactly
  as the model's serial check does.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # 0 nop · 1 link · 2 unlink · 3 monitor
  # 4 rlink_add · 5 rlink_del · 6 rwatch_add  (notes/53 Phase 4: the
  # REMOTE half of each relation — the other end lives on another
  # engine, so it is a full pid, not a slot bit)
  input :cmd, 3
  input :cmd_a, 5
  input :cmd_b, 5
  input :cmd_ref, 22
  input :cmd_pid, 36

  # monitor could not be recorded: the entry table is full
  output :mon_full, 1
  # ...and the remote-relation store's version of the same
  output :rem_full, 1

  input :die_en, 1
  input :die_slot, 5
  input :die_reason, 8
  input :die_pid, 36

  input :sig_ready, 1
  # readiness for the REMOTE phase (state 5): the engine's ring-egress
  # latch is free. Separate from `sig_ready` because the two phases
  # drain into different places.
  input :rsig_ready, 1

  output :busy, 1
  output :sig_en, 1
  output :sig_kind, 1
  output :sig_slot, 5
  output :sig_from, 36
  output :sig_reason, 8
  output :sig_ref, 22
  # the signal's target is on another engine: `sig_slot` is
  # meaningless and `sig_peer` carries the destination pid — the
  # engine routes these to the ring instead of local delivery
  output :sig_remote, 1
  output :sig_peer, 36
  output :done, 1

  output :next_slot, 5
  output :next_valid, 1

  input :rd_slot, 5
  output :rd_mask, 32

  memory :links, width: 32, depth: 32
  memory :mwatch, width: 32, depth: 32
  memory :mown, width: 32, depth: 32
  # {target:5, watcher:5, ref:22}
  memory :ment, width: 32, depth: 32

  # ---- the remote-relation store: 16 entries of {peer pid} + {kind,
  # owner, ref}. An entry means "when OWNER (a local slot) dies, tell
  # PEER (a pid on another engine)": kind 0 emits an exit signal (the
  # remote half of a link), kind 1 a DOWN carrying ref (the remote
  # half of a monitor, held at the TARGET like the model's `watchers`).
  # No dedup: linking the same pair twice stores two entries — the
  # model's MapSet is idempotent, so a program that double-links can
  # see a doubled {'EXIT',..}; none of ours do, and 16 comparators
  # per add is the price of fixing it.
  memory :rpid, width: 36, depth: 16
  # {kind:1, owner:5, ref:22}
  memory :rmeta, width: 28, depth: 16

  wire :st, 3, init: 0
  wire :d_slot, 5, init: 0
  wire :d_reason, 8, init: 0
  wire :d_pid, 36, init: 0
  wire :rest, 32, init: 0
  wire :mfree, 32, init: 0xFFFFFFFF
  wire :r_sig, 1, init: 0
  wire :r_kind, 1, init: 0
  wire :r_sig_slot, 5, init: 0
  wire :r_ref, 22, init: 0
  wire :r_done, 1, init: 0

  wire :m_row, 5, init: 0
  wire :m_bit, 5, init: 0
  wire :m_set, 1, init: 0

  wire :neg, 32
  wire :oh, 32
  wire :idx, 5
  wire :i0, 1
  wire :i1, 1
  wire :i2, 1
  wire :i3, 1
  wire :i4, 1
  wire :more, 1

  # the monitor entry the walk is looking at, and the free-entry pick
  wire :ent, 32
  wire :ent_target, 5
  wire :ent_watcher, 5
  wire :ent_ref, 22
  wire :fneg, 32
  wire :foh, 32
  wire :fidx, 5
  wire :f0, 1
  wire :f1, 1
  wire :f2, 1
  wire :f3, 1
  wire :f4, 1

  wire :ma, 32
  wire :is_link, 1
  wire :is_unlink, 1
  wire :is_mon, 1
  wire :is_radd, 1
  wire :is_rdel, 1
  wire :is_rwatch, 1
  wire :step, 1

  # ---- remote-store state: the valid vector (flops — the walks and
  # the free pick need it whole), the remote walk mask, the latched
  # delete key, and the remote emission registers
  wire :rvalid, 16, init: 0
  wire :rrest, 16, init: 0
  wire :del_pid, 36, init: 0
  wire :r_rem, 1, init: 0
  wire :r_peer, 36, init: 0

  # lowest set bit of rrest, and the free-entry pick over ~rvalid
  wire :rneg, 16
  wire :roh, 16
  wire :ridx, 4
  wire :rj0, 1
  wire :rj1, 1
  wire :rj2, 1
  wire :rj3, 1
  wire :rmore, 1
  wire :rfneg, 16
  wire :rfoh, 16
  wire :rfidx, 4
  wire :rf0, 1
  wire :rf1, 1
  wire :rf2, 1
  wire :rf3, 1

  wire :rent_pid, 36
  wire :rent_meta, 28
  wire :rent_kind, 1
  wire :rent_owner, 5
  wire :rent_ref, 22
  wire :rmine, 1
  wire :del_own, 5, init: 0

  wire :lk_we, 1
  wire :lk_addr, 5
  wire :lk_data, 32
  wire :mw_we, 1
  wire :mw_addr, 5
  wire :mw_data, 32
  wire :mo_we, 1
  wire :mo_addr, 5
  wire :mo_data, 32

  comb do
    busy = st != 0
    sig_en = r_sig
    sig_kind = r_kind
    sig_slot = r_sig_slot
    sig_from = d_pid
    sig_reason = d_reason
    sig_ref = r_ref
    sig_remote = r_rem
    sig_peer = r_peer
    done = r_done
    rd_mask = links[rd_slot]
    next_slot = idx
    next_valid = band(bor(st == 1, bor(st == 2, st == 3)), more)

    is_link = cmd == 1
    is_unlink = cmd == 2
    is_mon = cmd == 3
    is_radd = cmd == 4
    is_rdel = cmd == 5
    is_rwatch = cmd == 6
    mon_full = band(is_mon, mfree == 0)
    rem_full = rvalid == 0xFFFF

    # `normal` used to be filtered HERE (`propagates`), which meant a
    # trapping local link never saw {'EXIT', _, normal} — the model
    # delivers it. The filter moved to the DELIVERY end (the engine
    # drops normal for a non-trapper, dooms otherwise), which is where
    # the model keeps it and the only place that knows about traps.

    # lowest set bit of the current walk mask, and its index
    neg = 0 - rest
    oh = band(rest, neg)
    more = rest != 0
    i0 = reduce_or(band(oh, 0xAAAAAAAA))
    i1 = reduce_or(band(oh, 0xCCCCCCCC))
    i2 = reduce_or(band(oh, 0xF0F0F0F0))
    i3 = reduce_or(band(oh, 0xFF00FF00))
    i4 = reduce_or(band(oh, 0xFFFF0000))
    idx = i4 * 16 + i3 * 8 + i2 * 4 + i1 * 2 + i0

    # ...and the same trick over the free-entry mask, for allocation
    fneg = 0 - mfree
    foh = band(mfree, fneg)
    f0 = reduce_or(band(foh, 0xAAAAAAAA))
    f1 = reduce_or(band(foh, 0xCCCCCCCC))
    f2 = reduce_or(band(foh, 0xF0F0F0F0))
    f3 = reduce_or(band(foh, 0xFF00FF00))
    f4 = reduce_or(band(foh, 0xFFFF0000))
    fidx = f4 * 16 + f3 * 8 + f2 * 4 + f1 * 2 + f0

    ent = ment[idx]
    ent_ref = ent[21..0]
    ent_watcher = ent[26..22]
    ent_target = ent[31..27]

    # ---- the remote walk's lowest set bit, its free pick, and the
    # entry under the cursor — the 16-bit copies of the tricks above
    rneg = 0 - rrest
    roh = band(rrest, rneg)
    rmore = rrest != 0
    rj0 = reduce_or(band(roh, 0xAAAA))
    rj1 = reduce_or(band(roh, 0xCCCC))
    rj2 = reduce_or(band(roh, 0xF0F0))
    rj3 = reduce_or(band(roh, 0xFF00))
    ridx = rj3 * 8 + rj2 * 4 + rj1 * 2 + rj0

    rfneg = 0 - bnot(rvalid)
    rfoh = band(bnot(rvalid), rfneg)
    rf0 = reduce_or(band(rfoh, 0xAAAA))
    rf1 = reduce_or(band(rfoh, 0xCCCC))
    rf2 = reduce_or(band(rfoh, 0xF0F0))
    rf3 = reduce_or(band(rfoh, 0xFF00))
    rfidx = rf3 * 8 + rf2 * 4 + rf1 * 2 + rf0

    rent_pid = rpid[ridx]
    rent_meta = rmeta[ridx]
    rent_ref = rent_meta[21..0]
    rent_owner = rent_meta[26..22]
    rent_kind = rent_meta[27]
    rmine = rent_owner == d_slot

    ma = links[cmd_a]

    # one advance of whichever walk is running
    step = band(bor(st == 1, bor(st == 2, st == 3)), band(more, sig_ready))

    # ---- links: registration near side, its mirror, the walk's clears
    lk_we =
      bor(band(bor(is_link, is_unlink), st == 0),
        bor(st == 4, band(st == 1, bor(step, bnot(more)))))

    lk_addr =
      band(bor(is_link, is_unlink), st == 0) * cmd_a +
        (st == 4) * m_row +
        band(st == 1, step) * idx +
        band(st == 1, bnot(more)) * d_slot

    lk_data =
      band(is_link, st == 0) * bor(ma, 1 <<< cmd_b) +
        band(is_unlink, st == 0) * band(ma, bnot(1 <<< cmd_b)) +
        band(st == 4, m_set) * bor(links[m_row], 1 <<< m_bit) +
        band(st == 4, bnot(m_set)) * band(links[m_row], bnot(1 <<< m_bit)) +
        band(st == 1, step) * band(links[idx], bnot(1 <<< d_slot))

    # ---- mwatch: a new monitor's target row, and the corpse's own
    mw_we =
      bor(band(is_mon, band(st == 0, mfree != 0)),
        bor(band(st == 2, bnot(more)), band(st == 3, step)))

    mw_addr =
      band(is_mon, st == 0) * cmd_b +
        band(st == 2, bnot(more)) * d_slot +
        band(st == 3, step) * ent_target

    mw_data =
      band(is_mon, st == 0) * bor(mwatch[cmd_b], 1 <<< fidx) +
        band(st == 3, step) * band(mwatch[ent_target], bnot(1 <<< idx))
    # st 2 with nothing left writes zero: the corpse's watcher row

    # ---- mown: the watcher's own row, and its clearing
    mo_we =
      bor(band(is_mon, band(st == 0, mfree != 0)),
        bor(band(st == 3, bnot(more)), band(st == 2, step)))

    mo_addr =
      band(is_mon, st == 0) * cmd_a +
        band(st == 3, bnot(more)) * d_slot +
        band(st == 2, step) * ent_watcher

    mo_data =
      band(is_mon, st == 0) * bor(mown[cmd_a], 1 <<< fidx) +
        band(st == 2, step) * band(mown[ent_watcher], bnot(1 <<< idx))

  end

  on :clk do
    r_sig = 0
    r_rem = 0
    r_done = 0

    if rst == 1 do
      st = 0
      rest = 0
      mfree = 0xFFFFFFFF
      # the remote store is CROSS-PROGRAM semantic state (entry 36's
      # class): a relation surviving an image push would signal into
      # the next program's processes
      rvalid = 0
      rrest = 0
    else
      hdl_case <<st::3>> do
        <<0::3>> ->
          if bor(is_link, is_unlink) == 1 do
            m_row = cmd_b
            m_bit = cmd_a
            m_set = is_link
            st = 4
          else
            if band(is_mon, mfree != 0) == 1 do
              ment[fidx] = cmd_b * 134_217_728 + cmd_a * 4_194_304 + cmd_ref
              mfree = band(mfree, bnot(1 <<< fidx))
            else
              if band(bor(is_radd, is_rwatch), rvalid != 0xFFFF) == 1 do
                rpid[rfidx] = cmd_pid
                rmeta[rfidx] = is_rwatch * 134_217_728 + cmd_a * 4_194_304 + cmd_ref
                rvalid = bor(rvalid, 1 <<< rfidx)
              else
                if is_rdel == 1 do
                  del_own = cmd_a
                  del_pid = cmd_pid
                  rrest = rvalid
                  st = 6
                else
                  if die_en == 1 do
                    d_slot = die_slot
                    d_reason = die_reason
                    d_pid = die_pid
                    rest = links[die_slot]
                    st = 1
                  end
                end
              end
            end
          end

        # ---- 1: links, then hand over to the monitors OF this process
        <<1::3>> ->
          if step == 1 do
            r_sig = 1
            r_kind = 0
            r_sig_slot = idx
            rest = band(rest, bnot(oh))
          end

          if more == 0 do
            rest = mwatch[d_slot]
            st = 2
          end

        # ---- 2: DOWN to everyone watching, and clear their mown rows
        <<2::3>> ->
          if step == 1 do
            r_sig = 1
            r_kind = 1
            r_sig_slot = ent_watcher
            r_ref = ent_ref
            rest = band(rest, bnot(oh))
            mfree = bor(mfree, oh)
          end

          if more == 0 do
            rest = mown[d_slot]
            st = 3
          end

        # ---- 3: the monitors this process CREATED, silently removed
        <<3::3>> ->
          if step == 1 do
            rest = band(rest, bnot(oh))
            mfree = bor(mfree, oh)
          end

          if more == 0 do
            rrest = rvalid
            st = 5
          end

        # ---- 5: the REMOTE relations this process owned — exit
        # signals and DOWNs whose peer lives on another engine. Skips
        # advance every cycle; emissions pace on `sig_ready` like the
        # local phases, which for a remote signal means "the engine's
        # ring-egress latch is free".
        <<5::3>> ->
          if rmore == 1 do
            if rmine == 1 do
              if rsig_ready == 1 do
                r_sig = 1
                r_kind = rent_kind
                r_ref = rent_ref
                r_rem = 1
                r_peer = rent_pid
                rrest = band(rrest, bnot(roh))
                rvalid = band(rvalid, bnot(roh))
              end
            else
              rrest = band(rrest, bnot(roh))
            end
          else
            r_done = 1
            st = 0
          end

        # ---- 6: rlink_del — one entry per cycle, matching on
        # {owner, peer, kind 0}. Every match clears (a double-link
        # leaves duplicates; the delete should not leave one behind).
        <<6::3>> ->
          if rmore == 1 do
            if band(band(rent_owner == del_own, rent_pid == del_pid),
                 bnot(rent_kind)) == 1 do
              rvalid = band(rvalid, bnot(roh))
            end

            rrest = band(rrest, bnot(roh))
          else
            st = 0
          end

        # ---- 4: the mirror half of a link/unlink
        <<4::3>> ->
          st = 0

        <<_::3>> ->
          st = 0
      end

      if lk_we == 1 do
        links[lk_addr] = lk_data
      end

      if mw_we == 1 do
        mwatch[mw_addr] = mw_data
      end

      if mo_we == 1 do
        mown[mo_addr] = mo_data
      end
    end
  end
end
