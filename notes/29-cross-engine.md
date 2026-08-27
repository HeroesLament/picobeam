# 29 — Cross-engine: what crosses, and what the ring cannot carry yet

Two engines are up and a message crosses between them. This note
records what that took, and — more usefully — the two things that
stopped the rest, because neither is wiring. Both are decisions.

## What works

`tb_ring2`: engine 0 builds `{7, [8|9], 9}` on its heap and sends it to
a PID on engine 1. Engine 1 reads back 7, 9, 8, 9, arity 3, **and
allocates three cells of its own**.

That last number is the assertion. The engines share no memory, so a
term on engine 1's heap can only have arrived by being rebuilt from
flits. Before `SerUnit` was wired into `send`, what would have crossed
is engine 0's heap ADDRESS — and this two-engine configuration is
precisely what `notes/26` bug 1 was a bug about. It is now the
configuration that proves the fix.

Three things landed to get there.

**`RingLink`** — one hop, a 32-entry FIFO. A packet is a head entry
carrying `kind`, `dest_eng`, the destination PID and a flit count,
followed by its payload. The destination is a PID and not a slot
because the far end has to make the incarnation check itself: an engine
knows nothing about another engine's slots, and a 6-bit slot recycles
fast enough that shipping one alone is the ABA bug `notes/13` designed
the 22-bit serial to prevent.

A full ring applies BACKPRESSURE to the sender — the opposite of the
rule for a full mailbox, which kills the receiver (`notes/12` Q7). The
difference is deliberate: a mailbox is per-process and its fullness is
one process's fault, while the ring is shared and its fullness is
nobody's. Killing someone for congestion would make the victim a
function of unrelated traffic.

**Remote sends always park.** A packet is a header plus its flits, X
cannot stall to push two, and routing every remote message through the
serialiser — an immediate is a one-flit serialisation — gives the ring
one producer instead of two. A LOCAL immediate still retires at X in
one turn, which is why `b3_pingpong` is unchanged.

**PIDs carry the engine id.** `SeatUnit` built them with the engine
field hardcoded to zero, under a comment saying there was one engine so
it folded away. A process on engine 1 minting pids that claim engine 0
sends every reply to the wrong node, where the incarnation check
rejects it — a message lost with no error raised anywhere.

## What stopped, and why it is not wiring

### Cross-engine spawn: the far end has no staged args

`Machine` places every spawn round-robin over `n_engines` and does it
by writing the target engine's table directly. Hardware cannot: engine
0 cannot touch engine 1's proc table, so a remote spawn is a REQUEST
and a REPLY, and the spawner has to park until the child PID comes
back. That much is ordinary.

The problem is the arguments. A local spawn drains them out of the
requesting context's staging registers — `arg` writes them there and
`SeatUnit`'s spawn path reads them from that context. A spawn arriving
over the ring has no requesting context on this engine. Its arguments
are flits, and something has to inject them into a spawn that no local
process originated.

That is a new path through `SeatUnit`, not a new packet kind. The
options are roughly: give the spawn drain a second source that the ring
can drive; or land the args on the heap first and hand the new process
a term. The first is cheaper and the second is closer to what the model
does. It wants deciding before it is built.

A related constraint worth stating now: cross-engine spawn requires
both engines to hold the SAME code image, because the request carries
an entry PC and nothing else. That is the normal case — one program, N
engines — but `tb_ring2` currently boots two *different* images, so the
test that proves spawn will not be that one.

### Cross-engine links: a bitmap cannot hold a remote PID

This is the sharper one.

`Machine` stores `p.links` as a MapSet of full PIDs, which holds a
remote PID as naturally as a local one. `SignalTable` stores links as a
**32-bit bitmap of local slots** — one bit per slot — and there is no
bit pattern in it that means "the process at slot 3 on engine 1".

The bitmap is not an accident. `notes/13` argued that links need no PID
serial where monitors do, and the bitmap is what that argument bought:
a death walks its links one bit per cycle, lowest set bit first, so
propagation is *links* × ring diameter rather than *slots* × diameter.
The machine's whole claim is a stated WCET and that structure is what
pays for it.

So cross-engine links need either a second structure for remote peers —
`ment` is the precedent, since monitor entries already carry a full
target/watcher/ref triple — or an argument for why remote links can be
approximated by something narrower. The monitor path may cross engines
almost for free for exactly this reason, which suggests monitors first
and links second rather than treating the supervision set as one job.

## The state of the board

| | |
|---|---|
| cross-engine messages | **working**, `tb_ring2` |
| PIDs with the real engine id | **done** |
| ring packet kinds | **done** — nine defined, one implemented |
| cross-engine spawn | blocked on the arg-drain decision |
| cross-engine links | blocked on the bitmap |
| cross-engine monitors | probably cheap; `ment` already holds what is needed |
| cross-engine exit / DOWN | follows whichever of the above lands |

Nothing here is discouraging. It is the difference between "the ring
works" and "supervision works across the ring", and finding it now cost
a note rather than a half-built subsystem.
