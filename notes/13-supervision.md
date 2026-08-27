# 13 — Supervision

`03-architecture.md` carries the refinement in one paragraph; this note is
the full design. The one-sentence version: **mechanism in gates, policy in
code, and a WCET for the whole fault-to-restart path** — a claim no OTP
system can state and no prior Erlang machine attempted (every machine in
`02-prior-art.md` stops at spawn-and-send).

## The split

**Mechanism** — everything with a hard bound, in fabric:

- Link and monitor tables per engine (small associative stores; the model
  keeps them as per-process sets).
- Registration itself rides the ring: `link`/`unlink`/`monitor` to a remote
  process are ring transactions, not shared-table writes, so registration
  latency is bounded by the same diameter as send. A registration arriving
  for a dead or never-alive process is answered by the **dead-letter rule**:
  the target engine replies with the exit signal / `DOWN` carrying `noproc`,
  immediately. (M1 models and tests this.)
- Crash detection. In hardware, a fault is an *event*, not an exception
  path: bad tag, fixnum overflow, heap full, stack overflow, mailbox full,
  proc-table full, past-end fetch. Each becomes an exit reason at zero
  marginal cost, delivered through the same signal path as `exit/2`.
- Exit-signal fan-out: on death the engine walks the link set and emits one
  signal per entry onto the ring — a housekeeping FSM's job (Q4b), one hop
  per cycle, so propagation is links × diameter and never contends with
  running code.
- `trap_exit`: a bit in the proc-table entry; a set bit turns an arriving
  exit signal into an ordinary mailbox message `{'EXIT', Pid, Reason}` at
  the mailbox writer, in the delivery path itself.

**Policy** — everything recursive or configurable, as ordinary resident
Erlang code: restart strategies (`one_for_one` and friends), intensity and
period arithmetic, escalation to the parent, child specs, ordering.
Escalation is recursive policy, and recursive policy in gates is scope creep
— the picoJava lesson (`02-prior-art.md`). A supervisor is ~fifty lines of
the v1 subset sitting in `receive`, and because the mechanism below it is
bounded, those fifty lines *inherit* a WCET: fault → exit signal → mailbox →
supervisor's receive → respawn is a sum of bounded terms.

## The incarnation contract (PID serial)

A restart creates a *new* process that answers the old one's role. Software
BEAM distinguishes incarnations by allocating a fresh PID from a large
space; picoBEAM's 6-bit slot index recycles fast, so the PID carries a
**22-bit serial** — an incarnation counter for the slot — and every
delivery-side use of a PID (send, link, monitor, exit2) compares the *full*
PID, serial included, against the slot's current occupant. A stale PID —
the previous incarnation — misses, and the dead-letter rule answers
`noproc`. This is the ABA guard that makes "restart" safe: no message,
link or signal aimed at the dead incarnation can ever land on its
replacement. Serial wraparound at 2^22 incarnations of one slot is accepted
and noted as such (at one crash per millisecond, ~70 minutes of continuous
crashing of a single slot — the restart-intensity policy exists precisely
to halt that long before wraparound).

## The allocation-free fault path

An exit signal that must allocate to describe its reason can deadlock: the
canonical fault *is* `heap_full`. So every hardware-emitted reason is a
**reserved atom index**, fixed at machine definition, needing no atom-table
insertion and no heap cell: `normal`, `killed`, `kill`, `badarith`,
`bad_tag`, `overflow`, `heap_full`, `mailbox_full`, `stack_overflow`,
`system_limit`, `badarg`, `noproc`, plus `EXIT`, `DOWN`, `true`, `false`,
`ok`, `error` for the message shapes. The signal flit set is therefore
composed entirely of immediates — a dying process with a full heap and a
full mailbox can still tell its supervisor why, always. (`term.ex` fixes
the indices; the order of the reserved list is ABI.)

The same reasoning bounds the *shape*: an exit signal is
`{'EXIT', Pid, Reason}` with `Reason` restricted, for hardware-emitted
faults, to an immediate. User `exit/2` with a compound reason is an
ordinary term copy and pays send's price.

## Restart intensity is DoS protection, priced in

A crash-looping child converts supervision bandwidth into ring traffic:
each death is links × diameter flits plus a respawn. The mechanism
rate-limits this by construction — the housekeeping FSM emits one hop per
cycle, and a process crashing at boot cannot crash again until respawned —
but the *sustained* loop is policy's job, exactly as in OTP: intensity K
per period P, then the supervisor itself gives up and escalates. The
hardware contributes the honest version of the number: because
fault-to-restart has a WCET, the maximum crash frequency of a child is
computable, so K/P can be chosen against a known worst case rather than a
guess. Intensity arithmetic needs timestamps; the cycle counter is readable
by policy code (mechanism exports it; exact op TBD at M3 — the model's
`recv_waitt` timeout path already implies per-context timer access).

## Ports are supervised silicon

`10-userland.md` establishes ports-as-processes: a peripheral block owns a
PID, is sent to and received from, and — the payoff here — **is linked and
monitored like anything else**. A port that faults (its EHDL component
raises its fault line) emits an exit signal with a reserved reason;
`monitor(EncoderPid)` has hardware-bounded detection latency. Restarting a
port cannot mean re-elaborating fabric, so restart = **reset pulse + serial
bump**: the supervisor's respawn of a port PID asserts the block's reset
for its declared reset-latency and increments the slot serial, and the
incarnation contract does the rest (in-flight messages to the pre-reset
port dead-letter as `noproc`, exactly like a restarted software process).
The supervision tree is thereby the recovery model for the *entire chip* —
drivers, DSP blocks and processes in one tree, one restart semantics.

## Level 0 — the fabric watchdog

Below the root supervisor sits one non-Erlang guardian: a watchdog FSM that
expects a heartbeat from the root supervisor (a store to a watchdog port at
least every W cycles). Silence means the tree itself is gone — root
crashed without an ancestor, code image corrupt, machine wedged — and the
watchdog's only move is the biggest restart: re-enter the boot path of
`11-boot-and-images.md`, which reloads the image (falling back across A/B
slots on repeated failure). This closes the tree at the top: every level
of the system has a supervisor, and the supervisor of last resort is the
boot ROM. The watchdog is deliberately dumb — a counter and a comparator —
because anything smarter would itself need supervising.

## The tree ships in the image

No hardware table describes the supervision tree. The tree's shape —
children, strategies, intensities — is ordinary code and literal data in
the `.pbi` image (`11-boot-and-images.md`), spawned into existence by the
root supervisor at boot like any OTP release. Changing the tree is a code
deploy, not a bitstream build; the bitstream defines what *can* be
supervised (engines, ports, the watchdog), the image defines what *is*.

## What M1 already demonstrates

The reference model runs the mechanism end-to-end (`machine_test.exs`,
`erl_test.exs`): links with `trap_exit` delivering `{'EXIT', P, badarith}`
from a crashing child; monitor of a dead PID answered `DOWN`/`noproc` over
the ring by the dead-letter rule; hardware-reason deaths for overflow,
mailbox overflow, heap exhaustion, stack overflow, proc-table exhaustion
and past-end fetch — all as reserved atoms, all allocation-free. The
restart-policy layer (a supervisor in the v1 subset) is not yet written;
it needs nothing from the machine that does not already exist, and writing
one is the natural first *program* for M2's hardware to run beyond
`fib`/`nrev`. The M7 demo then stands: `one_for_one`, an LED as witness,
policy in fifty lines, mechanism in gates.
