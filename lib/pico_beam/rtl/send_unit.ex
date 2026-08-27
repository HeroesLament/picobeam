defmodule PicoBEAM.RTL.SendUnit do
  @moduledoc """
  M4 — `send rp, rm`: decode a pid, check the incarnation, enqueue.

  Pure combinational; a send costs the sender ONE turn. Everything
  expensive about message passing at M4 is on the receiving side.

  ## The pid is the route (Bet 2), and the serial is the guard

      pid = tag_pid(5) | engine:4 | slot:6 | serial:22

  A send decodes the word, and three things must hold before a message
  is delivered:

    * the word is actually a pid (`notes/13`: a send to a non-pid is
      `:badarg` on the SENDER — a program error, not a delivery
      failure);
    * the engine field names THIS engine (one engine at M4; the ring
      is M6, and a remote pid dead-letters until it exists);
    * the target slot is occupied AND its serial matches.

  That last test is the incarnation contract in gates. A 6-bit slot
  index recycles fast, so a stale pid — one naming a process that has
  since died and had its slot reused — must NOT land on the new
  occupant. Comparing the full 22-bit serial makes that impossible:
  a stale pid misses, and the answer is the dead-letter rule. At M4
  the message is simply dropped; M6 gives the drop a voice by
  answering `noproc` back over the ring.

  ## Overflow kills the RECEIVER

  A full mailbox raises `overflow`, and the engine dooms the TARGET
  slot with `:mailbox_full` (reserved atom 7) — not the sender. Q7's
  reasoning, from `notes/12`: backpressure on a sender would leak one
  process's slowness into another process's WCET, which is exactly the
  property this machine exists to protect. A process that cannot keep
  up with its mail is the one at fault, and it dies with a reason its
  supervisor can read.

  The doomed target may be resident on another seat, queued, or
  blocked, so the kill cannot be a fault at X — it goes through
  `ProcTable`'s doom vector, and the engine kills whichever seat holds
  the slot.
  """

  use Hw.Component

  # Term tags come from `PicoBEAM.Term`, not from memory. Module
  # attributes are compile-time Elixir and do not survive into a `comb`
  # block, so they reach the datapath as params — which elaboration
  # folds straight back to the literals that used to be written here by
  # hand. `notes/40` is why: the collector spent a milestone comparing
  # against a 7 that had become `:fun` somewhere else.
  param :T_PID, default: PicoBEAM.Term.tag_value(:pid)

  clock :clk, freq: 50.0

  # which engine this is. The PID's engine field is compared against it,
  # and a mismatch is a REMOTE send: the message leaves on the ring
  # instead of going into a local mailbox.
  input :eng_id, 4

  # a send op is retiring at X this cycle
  input :send_en, 1
  input :pid_word, 36
  input :msg_word, 36
  input :msg_hash, 8

  # ProcTable's second read port
  output :pt_slot, 5
  input :pt_serial, 22
  input :pt_state, 2

  # mailbox command (the engine gives this priority over receive-side ops)
  output :mb_cmd, 3
  output :mb_slot, 5
  output :mb_word, 36
  output :mb_hash, 8
  input :mb_full, 1

  # outcomes, all mutually exclusive
  output :remote, 1
  output :remote_slot, 6
  output :delivered, 1
  output :dead_letter, 1
  output :overflow, 1
  output :overflow_slot, 5
  # the pid was not a pid: :badarg on the sender
  output :bad_pid, 1

  wire :tag, 4
  wire :eng, 4
  wire :slot, 6
  wire :serial, 22
  wire :is_pid, 1
  wire :local, 1
  wire :alive, 1
  wire :serial_ok, 1
  wire :routable, 1

  comb do
    tag = pid_word[35..32]
    eng = pid_word[31..28]
    slot = pid_word[27..22]
    serial = pid_word[21..0]

    is_pid = tag == T_PID
    local = eng == eng_id
    pt_slot = slot[4..0]

    # occupied AND the same incarnation — the ABA guard of notes/13
    alive = pt_state != 0
    serial_ok = pt_serial == serial
    routable = band(is_pid, band(local, band(alive, serial_ok)))

    bad_pid = band(send_en, bnot(is_pid))

    # A remote send is not a dead letter and not a delivery: it is a
    # packet handed to the ring. The incarnation check cannot be made
    # here — this engine's ProcTable knows nothing about another
    # engine's slots — so it is made at the far end, on arrival, which
    # is also where the answer would have to be acted on.
    remote = band(send_en, band(is_pid, bnot(local)))
    remote_slot = slot

    dead_letter = band(send_en, band(is_pid, band(local, bnot(routable))))

    delivered = band(send_en, band(routable, bnot(mb_full)))
    overflow = band(send_en, band(routable, mb_full))
    overflow_slot = slot[4..0]

    mb_cmd = delivered * 1
    mb_slot = slot[4..0]
    mb_word = msg_word
    mb_hash = msg_hash
  end
end
