# 05 — Determinism: what can be claimed

Throughput is a losing argument and the history says so plainly: **2.31×** for
special-purpose Prolog hardware over a general tagged RISC (Berkeley,
PLM-vs-SPUR, 1987), and Azul walking away from custom silicon for software
barriers. So the case has to be made where software genuinely cannot follow — on
**bounds**, which is the same case JOP made for Java and won.

## The claims

All of these are **targets, not results.** Nothing has been synthesised. At
50 MHz, `:balanced` fit (9 engines, T=4).

| Operation | Worst case | Jitter | Why it's bounded | Software BEAM |
|---|---|---|---|---|
| Switch, resident | **0 cy** | 0 | rotation counter, not a switch | µs-scale, scheduler-dependent |
| Switch, swap-in | ~32 cy · 640 ns | ±0 | fixed context size / port width | — |
| Send, immediate | ~13 cy · 260 ns | ≤ 180 ns | ring diameter is the only variable | unbounded — allocation may GC |
| Receive, matching | depth + \|pat\| cy | bounded | fixed scan rate, bounded mailbox | O(n) mailbox scan, the classic trap |
| Allocation | **1 cy** | 0 | bump pointer, port A | may trigger a collection |
| GC mutator stall | **0 cy** | 0 | collector is on port B | per-process pause, size-dependent |
| Exit → supervisor | links × diam. | bounded | link table walk, fixed fan-out rate | scheduler-dependent |

## The composite claim

**A genuine WCET for an Erlang function including its message sends and its
allocation** — which no BEAM has ever been able to state. Hard real-time
control, written in Erlang, with the supervision tree intact.

That is a real place for this to live, and it happens to be exactly the argument
ECOMP's slides were making in 2000 with the words *"low power important in
embedded control"* and *"eliminate cost for real-time operating system."*

## How to measure each one

Determinism claims are worthless unmeasured, and the measurement has to survive
the trap recorded in `06-risks.md` — *the instrument is the device under test.*
So each of these needs a measurement path that does **not** route through the
thing being measured.

| Claim | Measurement |
|---|---|
| Switch cost | Cycle counter in the reference model, cross-checked against a scope trace on a GPIO toggled by the rotation counter. The counter is not the thing being measured. |
| Send latency | Toggle a pin on `SEND` issue and on mailbox-write completion, on *different engines*. Histogram over ≥10⁶ sends. Report the distribution, not the mean. |
| Receive latency | Same, from message enqueue to `RECEIVE_COMMIT`. Sweep mailbox occupancy 0…depth to show the bound is linear and where it saturates. |
| GC stall | Free-running cycle counter per context, incremented only when the context retires an instruction. Run an allocation-heavy loop through many collections; the counter must show 100% retirement. **If it dips, the claim is dead** — do not explain the dip away. |
| Exit propagation | GPIO on `EXIT` issue, GPIO on supervisor's mailbox write. Sweep link count. |
| Jitter ratio | JOP's own metric: longest ÷ shortest execution period over a fixed workload. JOP reported 3 against the JStamp's 5. Publish ours next to theirs. |

## The comparison to make, and the one not to make

**Make:** picoBEAM's jitter ratio against BEAM-on-Linux's, on the same
workload, same source. Scheduler wakeup jitter and GC pause distributions are
the numbers that matter and they are measurable on both sides.

**Do not make:** picoBEAM's throughput against BEAM-on-anything. We will lose by
a large factor, correctly, and saying so first is cheaper than being told.
50 MHz against 3 GHz is 60×, and the barrel gives away another T×. The honest
framing is ECOMP's own hedge — *per clock cycle* — plus the observation that per
clock cycle is what matters for power and for bounds, and nothing else.
