defmodule PicoBEAM.RTL.ProcTable do
  @moduledoc """
  M3 pass 2 — the process table: 32 slots, the engine's roster.

  Per `notes/16` (and `13`'s incarnation contract): a slot holds a
  process's state, saved pc, 22-bit incarnation serial, and fault
  reason. The PID is `{engine:4 | slot:6 | serial:22}` — slot ids here
  are 5 bits (32 slots, v1 scope), zero-extended into the 6-bit PID
  field. Serials survive death and bump on ALLOCATION, so a recycled
  slot's new occupant never answers a stale PID — the ABA guard.
  Serial wraparound at 2^22 is accepted and documented in 13.

  ## The command port (one command per cycle, by contract)

  The table accepts a single micro-command per cycle:

      0 nop
      1 alloc    — pop the free list, bump the slot's serial, write
                   entry pc = cmd_pc, state = queued. Combinational
                   response: alloc_ok (0 = table full → the spawner's
                   :system_limit), alloc_slot, alloc_serial (post-bump,
                   matching the model: root allocates as serial 1).
      2 free     — death: state = free, slot to the free-list tail,
                   fault reason recorded from cmd_pc[7..0]. Serial
                   NEVER clears.
      3 save     — deschedule: saved pc = cmd_pc AND state = queued.
                   The two always happen together (a saved process is
                   by definition on its way to the queue), so folding
                   them into one command keeps the seat unit's use of
                   the single command port down to one cycle. Found by
                   the pass-6 testbench, which caught descheduled procs
                   still reading `resident`.
      4 bind     — seat-in: state = resident.
      5 requeue  — deschedule bookkeeping: state = queued (the engine
                   pushes the slot to the RunQueue itself).
      7 park     — an evicted BLOCKED process: save pc, state = blocked.
                   Distinct from `save` because a blocked process must
                   NOT enter the run queue — only a message may put it
                   back. This is the difference between "descheduled
                   because its budget ran out" and "descheduled because
                   it is waiting for mail".
      8 wake     — a message arrived for a blocked process: state =
                   queued. The engine pushes the slot to the RunQueue.

      9 settrap  — `process_flag(trap_exit, Bool)`: cmd_pc[0] is the
                   flag. A bit rather than a state, because it is
                   orthogonal to every state a process can be in — a
                   trapping process can be resident, queued or blocked
                   and the arriving signal has to be converted either
                   way. `notes/13` puts the conversion "at the mailbox
                   writer, in the delivery path itself", which is why
                   the bit is read through its own port here rather
                   than by whoever is running.

      6 doom     — mark a slot for death with a reason it has not run
                   yet to receive. `send` uses it when a target's
                   mailbox overflows: Q7 says the RECEIVER dies, and the
                   receiver may be queued, blocked, or resident on
                   another seat at that moment, so the kill cannot be a
                   simple fault at X. The doomed slot is published in
                   `doom_vec`; the engine kills the seat holding it (if
                   any) and the seat unit refuses to seat it.

  The ENGINE guarantees at-most-one command per cycle: spawn/death
  issue from the X stage (one context occupies X per cycle, one system
  op per bundle), and the seat unit's bind/save/requeue defer to X by
  fixed priority — a priority, not an arbiter, and the deferral is
  1 cycle, bounded. This component just trusts the contract; the
  integration pass asserts it.

  ## Read port

  `rd_slot` → `rd_pc`/`rd_serial`/`rd_state` combinationally: the seat
  unit reads the incoming process's pc and serial at seat-in (the seat
  file caches the pid so `self` never touches this table).

  Storage: one LUT-RAM per column (async read), each with exactly one
  write site — the ehdl discipline. The free list is its own 32 × 5
  ring FIFO initialized 0..31.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # FOUR bits. It was three, and `settrap` is command 9, which
  # truncated to 1 — `alloc`. So every `process_flag(trap_exit, true)`
  # silently consumed a process slot and set no flag, and the symptom
  # was a supervisor dying with its child for no visible reason.
  #
  # Third time: M3's `cstate` was three bits with a state 9
  # (`spawn_park`) that became 1 (`run`), and M2's `pidx` collapsed the
  # same way. A command or state space that grows past its declared
  # width does not error — it aliases onto a neighbour that is usually
  # a legal, plausible, wrong thing to do.
  input :cmd, 4
  input :cmd_slot, 5
  input :cmd_pc, 12

  output :alloc_ok, 1
  output :alloc_slot, 5
  output :alloc_serial, 22

  input :rd_slot, 5
  output :rd_pc, 12
  output :rd_serial, 22
  output :rd_state, 2

  # a SECOND read port: `send` must check a target's incarnation serial
  # in the same cycle the seat unit is reading something else. Replicated
  # columns, mirror-written — the register window's trick at 1/100th the
  # width.
  input :rd2_slot, 5
  output :rd2_serial, 22
  output :rd2_state, 2

  # a THIRD read port, for the exit-signal path: when a link fan-out
  # asks "does this peer trap?", `send` may be using rd2 and the seat
  # unit rd1 in the same cycle. One more replicated column is cheaper
  # than a stall on the one path whose latency is a published number.
  input :rd3_slot, 5
  output :rd3_trap, 1
  output :rd3_state, 2

  # a FIFTH read port: the ring's arrival check. A packet landing from
  # another engine has to have its PID verified against this table —
  # the far end could not do it, because it does not know our slots —
  # and it arrives whenever it arrives, which may be the same cycle a
  # send is using rd2 and a signal is using rd3.
  input :rd5_slot, 5
  output :rd5_serial, 22
  output :rd5_state, 2

  # a SIXTH read port (`notes/50`): the serialiser's completion wake.
  # A compound local send finishes cycles after the send's X, when no
  # other port is guaranteed free — the exit emitter got rd3 for the
  # same reason. Another async read of the mirror pair; synthesis
  # replicates the LUTRAM.
  input :rd6_slot, 5
  output :rd6_state, 2

  # a SEVENTH (`notes/53`): the node registry's aliveness probe for a
  # pid registered from the PEER engine. Never contended — an engine
  # checks its own pids through rd2, so only foreign probes land here,
  # and two engines probing each other read two different tables.
  input :rd7_slot, 5
  output :rd7_state, 2
  output :rd7_serial, 22

  # a FOURTH read port, on the reason column. A process killed by a
  # signal has to pass that reason ON to its own links — Erlang
  # propagates transitively — and the X-stage fault reason is silent
  # about it, because such a process never faulted at X. The reason it
  # actually died of is the one `doom` wrote here.
  input :rd4_slot, 5
  output :rd4_reason, 8

  # one bit per slot, set by `doom`, cleared on alloc and free
  output :doom_vec, 32

  # `notes/40` — which slots hold a process, as a vector. The collector's
  # root walker has to enumerate live processes, and asking slot by slot
  # through `rd_slot` would cost 32 round trips before the first root.
  # It is maintained beside `doomv` from exactly the same two events.
  output :live_vec, 32

  # occupancy witness (the thousand-spawns demo counts on this)
  output :occ, 6

  # columns
  memory :pcs, width: 12, depth: 32
  memory :serials, width: 22, depth: 32
  memory :states, width: 2, depth: 32
  memory :reasons, width: 8, depth: 32
  memory :serials2, width: 22, depth: 32
  memory :states2, width: 2, depth: 32
  memory :traps, width: 1, depth: 32
  memory :states3, width: 2, depth: 32

  # free list: ring FIFO preloaded with every slot id
  memory :flist, width: 5, depth: 32, init: Enum.to_list(0..31)

  # entry 36's sweeper cursor: `eng_rst` holds for the entire image
  # load (thousands of cycles), so a 32-cycle walk during reset is free
  wire :swp, 5, init: 0

  wire :fhead, 5, init: 0
  wire :ftail, 5, init: 0
  wire :fcnt, 6, init: 32

  # command decode
  wire :is_alloc, 1
  wire :is_free, 1
  wire :is_save, 1
  wire :is_bind, 1
  wire :is_requeue, 1
  wire :is_doom, 1
  wire :is_park, 1
  wire :is_wake, 1
  wire :is_settrap, 1
  wire :doomv, 32, init: 0
  wire :livev, 32, init: 0

  # write funnels (one write site per column)
  wire :new_serial, 22
  wire :st_we, 1
  wire :st_addr, 5
  wire :st_data, 2
  wire :pc_we, 1
  wire :pc_addr, 5

  comb do
    is_alloc = cmd == 1
    is_free = cmd == 2
    is_save = cmd == 3
    is_bind = cmd == 4
    is_requeue = cmd == 5
    is_doom = cmd == 6
    is_park = cmd == 7
    is_wake = cmd == 8
    is_settrap = cmd == 9

    alloc_ok = band(is_alloc, fcnt != 0)
    alloc_slot = flist[fhead]
    # serial bumps at allocation: first life of a slot is serial 1,
    # matching the model's root pid {:pid, 0, 0, 1}
    new_serial = serials[alloc_slot] + 1
    alloc_serial = new_serial

    rd_pc = pcs[rd_slot]
    rd_serial = serials[rd_slot]
    rd_state = states[rd_slot]
    rd2_serial = serials2[rd2_slot]
    rd2_state = states2[rd2_slot]
    rd3_trap = traps[rd3_slot]
    rd3_state = states3[rd3_slot]
    rd4_reason = reasons[rd4_slot]
    rd5_serial = serials2[rd5_slot]
    rd5_state = states2[rd5_slot]
    rd6_state = states2[rd6_slot]
    rd7_state = states2[rd7_slot]
    rd7_serial = serials2[rd7_slot]
    doom_vec = doomv
    live_vec = livev

    occ = 32 - fcnt

    # state column: alloc → queued(1), free → free(0), bind →
    # resident(2), requeue → queued(1). One-hot by cmd decode.
    st_we =
      bor(alloc_ok,
        bor(is_free, bor(is_bind, bor(is_requeue, bor(is_save, bor(is_park, is_wake))))))

    st_addr = alloc_ok * alloc_slot + bnot(alloc_ok) * cmd_slot
    # 0 free · 1 queued · 2 resident · 3 blocked
    st_data =
      alloc_ok * 1 + is_bind * 2 + is_requeue * 1 + is_save * 1 + is_park * 3 +
        is_wake * 1

    # pc column: alloc writes the entry pc, save writes the resume pc
    pc_we = bor(alloc_ok, bor(is_save, is_park))
    pc_addr = alloc_ok * alloc_slot + band(bor(is_save, is_park), bnot(alloc_ok)) * cmd_slot
  end

  on :clk do
    if rst == 1 do
      fhead = 0
      ftail = 0
      fcnt = 32
      # entry 36: these are SEMANTIC and were init-only — a doom vector
      # surviving an image push would doom the next program's processes
      # the moment they recycled the slots
      doomv = 0
      livev = 0
      # ...and the per-slot COLUMNS are memories, which no reset flag
      # reaches: a serial surviving a push gives the next program's
      # processes different pids run to run — nondeterminism the model
      # cannot follow, caught by tb_spawn2's RERUN pass. The free list's
      # RAM is also restored to identity, because deaths permute it.
      swp = swp + 1
      serials[swp] = 0
      serials2[swp] = 0
      states[swp] = 0
      states2[swp] = 0
      states3[swp] = 0
      traps[swp] = 0
      flist[swp] = swp
    else
      swp = 0
      if alloc_ok == 1 do
        fhead = fhead + 1
        serials[alloc_slot] = new_serial
        serials2[alloc_slot] = new_serial
      end

      # a slot's doom bit is set by `doom` and cleared when the slot
      # changes hands, so a recycled slot never inherits a death
      if is_doom == 1 do
        doomv = bor(doomv, 1 <<< cmd_slot)
      end

      if alloc_ok == 1 do
        doomv = band(doomv, bnot(1 <<< alloc_slot))
        livev = bor(livev, 1 <<< alloc_slot)
      end

      if is_free == 1 do
        doomv = band(doomv, bnot(1 <<< cmd_slot))
        livev = band(livev, bnot(1 <<< cmd_slot))
      end

      if is_free == 1 do
        flist[ftail] = cmd_slot
        ftail = ftail + 1
      end

      # A DOOMED process already has its reason recorded — it was
      # written when the signal named it, which is the only moment
      # anyone knew what it was. The free that follows carries the X
      # stage's fault reason, and for a process killed by a signal
      # there is no X-stage fault, so that reason is zero: `normal`.
      # Letting the free write unconditionally erased the reason at
      # exactly the moment the process died of it, and the corpse then
      # claimed to have exited normally.
      if band(is_free, bnot(band(doomv >>> cmd_slot, 1))) == 1 do
        reasons[cmd_slot] = cmd_pc[7..0]
      end

      if is_doom == 1 do
        reasons[cmd_slot] = cmd_pc[7..0]
      end

      # net free-list count: alloc takes, free returns
      if band(alloc_ok, bnot(is_free)) == 1 do
        fcnt = fcnt - 1
      end

      if band(is_free, bnot(alloc_ok)) == 1 do
        fcnt = fcnt + 1
      end

      if st_we == 1 do
        states[st_addr] = st_data
        states2[st_addr] = st_data
        states3[st_addr] = st_data
      end

      # trap_exit is per-INCARNATION, so allocation clears it: a
      # recycled slot must not inherit the previous occupant's flag,
      # which is the same reasoning the doom bit already gets
      if alloc_ok == 1 do
        traps[alloc_slot] = 0
      end

      if is_settrap == 1 do
        traps[cmd_slot] = cmd_pc[0]
      end

      if pc_we == 1 do
        pcs[pc_addr] = cmd_pc
      end
    end
  end
end
