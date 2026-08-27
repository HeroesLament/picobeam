# 54. Supervision crosses the ring

*The Phase-4 campaign of `notes/53`: link, monitor, exit/2, and both
noproc replies, across engines — plus the two old bugs the first
cross-engine link test flushed out of the LOCAL machine.*

## What the wire now carries

The ring's kind field finally earns its four bits. Kinds 0–2 are the
message and spawn transport (`notes/29`, `notes/49`); the sup
transport adds five more, every payload word an immediate so the
allocation-free death rule (`notes/13`) holds across engines too:

    kind 3  link_req      [from]                 head = target pid
    kind 4  unlink_req    [from]
    kind 5  monitor_req   [from, ref]
    kind 6  exit_signal   [from, reason]
    kind 7  down_signal   [ref, from, reason]

There is no kind 8. The model never had a separate noproc packet
either: a link_req that dead-letters answers with kind 6 carrying
`noproc`, a monitor_req with kind 7 — the reply IS the signal.

## Refs need no engine field

`notes/53` worried the 0x600000000 ref layout would need engine bits
"or DOWN matching breaks". It doesn't, for a reason worth recording:
a ref is minted by `monitor`, which runs on the WATCHER's engine, and
a process never migrates — so every ref one process will ever compare
came from its own engine's counter, and collisions between engines'
counters are invisible to any single process. The monitor_req carries
the ref word out; the target's death walk echoes it back verbatim.
(What the mon2 expect file DID catch: the reset audit had set
`next_ref = 0` where the model starts at 1 — a uniformly shifted
counter self-agrees, so only a raw-word compare against the model
could see it.)

## Where the state lives

`SignalTable` grows a remote-relation store: 16 entries of {peer pid,
kind, owner slot, ref}. The local bitmaps cannot hold a foreign end —
they index slots, and a slot number is only meaningful at home. An
entry means "when OWNER dies, tell PEER": the death walk gains a
fourth phase over them, emitting `sig_remote`/`sig_peer` through the
same `sig_ready` handshake, which for a remote signal means "the
engine's egress latch is free".

A cross-engine link stores an entry at BOTH ends (each side's death
must notify the other); a cross-engine monitor stores only at the
TARGET, exactly like the model's `watchers` list — the watcher-side
cleanup that `mown` does locally is replaced by the dead-letter check
on arrival, which is what the model does too.

## How a request leaves an engine

A sup op whose pid is foreign parks its context — BarrelSeq state 18,
the same discipline a remote send rides — with the packet latched
per-seat at X. At the seat's own F slot it claims the ONE outbound
signal latch (`sx_*`), which also serves the death walk's remote legs
and the ingress noproc replies, in that priority order. The latch
drains through the existing `rt_*` egress FSM, which was built
multi-kind on purpose. Backpressure is parking, not queues: no FIFO
to size, no packet to lose.

The local halves still happen at X: a remote link records its near
side (cmd 4), a remote monitor mints its ref and writes rd. The far
half lands via ingress: kind 3/5 into the far remote store, dead
targets answering noproc; kind 6 into the existing trap-vs-doom
delivery with the model's rules verbatim (kill is untrappable and
lands as `killed`; normal kills nobody; a trapping target gets
{'EXIT', From, Reason}); kind 7 always a message. Final flits pop
only when their action has its resources — the stall-not-drop rule
`rg_take` set the precedent for.

## The two local bugs the gate work flushed out

**`normal` was filtered at the SOURCE.** The SignalTable refused to
walk a normal death's links, so a trapping local partner never saw
{'EXIT', _, normal} — the model always delivered it. The filter moved
to the delivery end, the only place that knows about traps: doom only
when the reason is non-normal, deliver to trappers regardless. Same
fix in `exit/2`'s else-branch, where exit(Pid, normal) at a
non-trapping target used to DOOM it (exit(self(), normal) still
dies, as it must).

**Entry 38.** A peek that hit a SHORT message never wrote rd — every
bare-immediate selective receive (`receive go`) skipped its own
message and blocked forever, on every engine count, since forever.
See `notes/26`. Fixed with the entry-34 deferred-writeback shape,
now its third use.

## Gates

`tb_slink2`: a trapping parent on engine 0 sees a cross-engine
badarith, a cross-engine NORMAL exit, and a noproc reply, in program
order, model-compared. `tb_mon2`: ref out equals ref back, kill
crosses and lands as killed, monitoring a corpse answers noproc.
Both green against `Machine engines: 2`; the model halves are
permanent tests in `test/sup_smp_test.exs`. The full single-engine
regression set stayed green — the normal-propagation change is
invisible to every existing program, because none of them trapped a
normal death.

Untested on gates, named so the gap is a decision: kind 4 (remote
unlink) is implemented and model-covered but no testbench exercises
it yet, and the remote store's 16 entries fault nothing when full —
an ingress add that finds no room answers noproc (fails loudly to
the requester), a local one is silently dropped. Both are recorded
here rather than discovered later.

---

## Postscript: the board's verdict

One batched bitstream — 52,327 LUT4 (62% of the 85F), 14,005 FF,
Fmax 12.15 MHz, PASS at 12.00; Phases 3 and 4 together cost about
2k LUT4 and 340 kHz of margin. Three pushes, three verdicts:

    counter, push 1:  p026 0 d 00 001 002 0 5 2a 80 01 01
    counter, push 2:  p0da 0 d 00 001 002 0 5 2a 80 01 01
    super2:           p0f8 0 d 20 003 002 0 5 05 80 01 01

The first two lines differ only in the free-running frame counter —
an image push is a true soft reboot now, which is entry 36 closed on
silicon. The third is the V1 demo: `OO=05` is the restarted server's
fresh answer, `XX=01` is `killed` crossing the ring through the link,
and `CC=20` is the geography — engine 1 buried its server, engine 0
holds the supervisor's survivors. Exactly the line predicted before
the push, from a model run of the same program.
