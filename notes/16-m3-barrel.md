# 16 — M3: the barrel

The plan, written before the RTL, the way 15 was written after it.
M3 per `07-roadmap.md`: **T contexts, reduction counter, run queue,
process table, `spawn` and `yield`, one engine — concurrency exists
but nothing leaves the island.** Exit demo: a thousand spawns, and a
trace proving exact 1/T interleaving.

The reference model already IS the M3 spec — the "M3 on-ramp"
increment in `machine.ex` (seats, lazy fill, `swap_cost`, the
budget-with-waiters rule, blocked-resident eviction, spawn-queues-
past-N×T, `:system_limit` at 64 slots). The RTL's job is to earn
those semantics in gates; where hardware wants a different shape,
the model moves at co-sim time, as with heap cell addressing.

## The pipeline transform

M2's sequencer is TEMPORAL: one context, states in sequence
(fetch → exec → wb2/call_wait/ret_fill...), 2 cycles per bundle,
~36 ns of logic in the exec state. The barrel makes it SPATIAL:

    cycle:   t      t+1    t+2    t+3    t+4
    F stage: ctx0   ctx1   ctx2   ctx3   ctx0
    D stage:  —     ctx0   ctx1   ctx2   ctx3
    X stage:  —      —     ctx0   ctx1   ctx2

Three stages, T = 4 seats, seat = cycle mod T (Q9: fixed rotation,
always). A context issues one bundle per turn = every 4 cycles.

* **F** — the context's pc on CodeMem's sync read (the read IS the
  stage register).
* **D** — decode + classify + window address muxes + the async
  LUT-RAM window READ; operands register into X. Splitting the read
  out of the exec cycle is where M2's 36 ns goes to die.
* **X** — tag-checked ALU, write-back, control resolution (branch,
  call, ret, spawn, yield, halt, fault), reduction decrement.

**No bypass, no interlock, by construction:** a context's next
bundle enters F two cycles after its last left X, and other
contexts' addresses live in other slot regions of the window RAMs.
The M2 exec path had window-write → same-cycle read one-hot fun;
in the barrel a same-context RAW is 4 cycles apart. This is the
architecture's whole point (`03`, dividend 1) and it is also the
fmax fix promised in 15's calibration entry.

Write/read port discipline carries over unchanged: the window keeps
3 banks × replicas + LVT; port 0 keeps its phase-disjoint one-hot
sum (ALU wb / fill / dest / heap-late / pool-late) because the
phases now belong to DIFFERENT SEATS and remain disjoint per cycle
by rotation arithmetic — the wb2 cycle that cost M2 a stall is
simply another context's X slot now, exactly as promised.

## Per-context state (the pointer file widens)

Duplicated ×T, indexed by seat: pc, mini-FSM state (run / call_wait /
ret_wait / ret_fill / parked — the M2 state encoding survives as a
PER-CONTEXT status, not the engine's), pend_call/ret/halt, reduction
budget, and the window pointer trio (cur/stg/spl) — RegWindowRam's
moduledoc wrote this contract at M2: storage layout, addressing and
port discipline unchanged, `ctx` input goes live, pointer file
becomes a ×T array. The proc-table slot bound to each seat joins
this file.

A context whose mini-FSM is not `run` simply BUBBLES its F slot —
the rotation never skips a seat, it just issues nothing for it
(1/T is a promise about slots, not about progress).

## Multi-cycle machinery: shared units, no arbiter

FrameRam has one port pair, so the drain unit and the fill unit stay
SINGLE, shared by all seats, serialized by a busy flag each:

* call: seat's cur drains in background (16 cy). A second seat
  reaching call while the drain unit is busy parks (bubbles) —
  same window_ready contract as M2, now per-seat.
* ret: pop-then-fill (18 cy) holds the fill unit; other seats keep
  executing through it. Contention degrades throughput, never
  correctness, and the WCET terms stay sums of bounded terms.

## FrameRam grows a slot dimension

M2: 32 frames, one process, `fp` counts frames. M3: frames are
per-PROCESS stack regions — `addr = {slot, depth, idx}`. Proposal:
**32 proc slots × 8 frames deep** = 4096 words = 8 DP16KD (85F has
208; the full 64 × 8 doubles that and can wait for the fit model).
Call depth past 8 is `:stack_overflow` — a reserved-atom fault, per
13. The `rets` link store grows the same slot dimension
(and goes distributed-RAM, the 15-noted one-liner). The M2
`spill_slot` register generalizes to {slot, depth} captured at
push — and the width bugs that class of arithmetic just taught us
about are already fixed at the emitter.

## Seat swap (the model's swap_cost, made of gates)

Unseating saves 16 registers + pc + pointers; seating restores them.
A **swap unit** (one more shared FSM on the frame RAM's port budget —
or a dedicated 32×16-word save RAM, 2 DP16KD, decided at
implementation by port pressure) drains the seat's cur slot to the
proc's save area and fills from the incoming proc's. ~16 out +
16 in ≈ the model's swap_cost 32. The seat bubbles during; seat_ready
is a per-seat cycle stamp, exactly the model's.

Deschedule policy in gates = the model's rule verbatim: budget
exhausted AND run queue non-empty → unseat to queue tail; queue
empty → budget reloads, seat kept. `yield` forces the budget to 1.
Blocked-at-rotation with waiters → evict (matters from M4's receive;
at M3 only halt/fault vacate otherwise).

## Process table, run queue, spawn, self

**ProcTable** — 32 entries (v1 scope; PID slot field stays 6 bits):
state (free/queued/resident/dead), saved pc, serial (22-bit
incarnation counter, per 13's ABA contract), fault reason. Free
slots in a FIFO free list; allocation = pop + serial bump.
Links/monitors/trap_exit columns are M4+/M6 tenants of the same RAM.

**RunQueue** — 32-deep FIFO of slot ids, LUT-RAM ring buffer,
head/tail counters. The only policy in the machine.

**`spawn rd, f, arity`** — args stage via `arg` exactly like call
(the stg slot is the newborn's first frame); at X: allocate slot
(full → `:system_limit` fault on the SPAWNER), write entry
{pc = f, serial+1}, drain stg to the newborn's save area, enqueue,
write `pid = {engine:4|slot:6|serial:22}` (32 bits, fits the 36-bit
payload) to rd. The drain makes spawn multi-cycle; the spawner's
seat bubbles behind the shared drain unit, bounded as ever.

**`self rd`** — reads the seat's bound slot + serial. This is the
M2-deferred op; it costs a pointer-file read.

**Death** — halt or fault at M3 = the process dies: entry → dead
(serial retained), seat vacated, next queue entry seats in. Fault
reasons keep landing in the table for 13's exit-signal fan-out to
pick up at M6. Engine-level halt = proc table empty AND queue empty
(the thousand-spawns demo ends this way).

## ISA/encoding deltas

`spawn` (rd, f-target, arity — call-shaped), `yield`, `self` (rd)
join the system group; `machine.ex` executes them already. The
opcode-table discipline holds: no translation at decode. `Encoding`
+ `Asm` grow the three shapes; the v1 `Erl` front end already emits
spawn/yield/self forms in the model — co-sim gets a real workload.

## Order of work (the pass rhythm that worked for M2)

1. **This note**, then encoding/asm for spawn/yield/self.
2. **ProcTable + RunQueue RTL** — standalone, iverilog-first (the
   emitted-netlist TB loop from the silicon session is now the
   default verification path — sim BEFORE silicon this time).
3. **Barrel sequencer** — rotation counter, per-context pc/state
   file, F/D/X pipeline registers, bubble logic; M2's FSM semantics
   redistributed per-seat. The single hairiest pass.
4. **Window ctx goes live** — pointer file ×T (the RegWindowRam
   contract), D-stage read timing.
5. **FrameRam slot dimension** + drain/fill/swap units + per-seat
   window_ready.
6. **Reduction counter + deschedule/yield path.**
7. **Spawn datapath + self.**
8. **Demo**: `DemoSpawn` — root spawns 1000 workers (spawn counter
   as the out witness), per-seat activity on 4 LEDs, UART oracle
   gains seat-occupancy fields; scope trace of the LED pins shows
   the 1/T comb. Then the silicon loop: build → flash → capture.

Deliberately NOT in M3: mailbox/send/receive (M4), collector (M5),
the ring (M6), placement (one engine — spawn's engine field is
constant), timer wheel (recv_waitt is M4), the Q5 method cache
(flat 9-bit pc still fits every image we can load).

## Risks named up front

* The D-stage window read wants the LVT indexed by a REGISTERED
  address — check the LVT read path doesn't reintroduce the 36 ns.
* Shared drain/fill/swap units on one FrameRam port pair: worst-case
  park chains need a bound argument in the note that closes M3.
* fmax claim: the barrel should clear 24 MHz with slack (measure,
  don't assume — 15's numbers are the baseline); 48 MHz (CLKOP) is
  the stretch target the PLL already emits.
* The emitter width-rule class of bug: every new `slot * K + idx`
  address computation gets an iverilog test before silicon. We know
  the species now.

---

## Build log — passes 2–5 (2026-08-23)

iverilog-first held: every part met a self-checking testbench on the
emitted netlist before any engine integration, and nothing needed
silicon to find. Running cost ledger (yosys, `synth_ecp5`, standalone —
sums are pessimistic, shared logic prunes at integration):

| part | LUT4 | FF | DPR16X4 | DP16KD |
|---|---|---|---|---|
| ProcTable (32 slots) | 108 | 16 | 36 | — |
| RunQueue (32 deep) | 22 | 16 | 4 | — |
| BarrelSeq (T=4) | 620 | 116 | — | — |
| RegWindowCtx | 5,212 | 824 | — | 21 |
| FrameRamProc | 1,189 | 224 | 64 | 8 |

### Pass 4's fork, decided by measurement

The window was built FIRST as the note specified — LUT-RAM, depth ×4
for the context dimension — and the ledger refused it: **26,807 LUT4 +
3,024 DPR16X4**, five times the entire M2 engine. A 256-deep DPR16X4
cascade rebuilds exactly the mux forests the M2 RAM rebuild existed to
kill; depth is only free in distributed RAM up to the primitive's own
16 words.

So all 21 bank replicas became sync-read EBRs, and **the barrel is what
makes that free**: addresses present in D, the DP16KD's output register
IS the D→X operand register the pipeline already needed, and the LVT
bank selects ride beside it as seven 2-bit registers (`lsr*`). Result
5,212 LUT + 21 of 208 EBRs, and D-stage timing improves rather than
degrades. The LVT itself split into four per-context 128-bit registers
(local `{slot, reg}` indices — M2's shift widths verbatim) instead of
one 512-bit file with 9-bit shifts.

Recorded as a general lesson: at M2 the register file wanted LUT-RAM
because 64 words × async reads beat flops; at M3 the same structure
wants EBR because 256 words × pipelined reads beat LUT-RAM. The
storage primitive is a function of depth AND of what the pipeline can
absorb — re-measure it at every T.

### Pass 5: seats address the window, SLOTS address the frames

`FrameRamProc` is `{slot:5, depth:3, idx:4}` → 4096 × 36 (8 EBRs) with
the link store `{slot:5, depth:3}` → 256 × 13 in distributed RAM (the
`rets`-in-an-EBR waste `notes/15` flagged, fixed as promised). 32 slots
× 8 frames; depth 8 is `:stack_overflow`, surfaced combinationally for
the fault chain, with `underflow` as its mirror.

The two indexings are deliberate and now explicit: a window is a barrel
POSITION, a frame stack is a process IDENTITY, and the seat→slot
binding (pass 6's seat file) is the only thing that maps between them —
which is precisely why a process can be swapped out and back without
its stack moving.

One structural economy fell out: `push_en` and `pop_en` are mutually
exclusive BY CONSTRUCTION (both are `BarrelSeq` F-slot claims; one F
owner per cycle; a context parked for call is not parked for ret), so
the 32 depth counters live in ONE shift-indexed 128-bit register with a
single read port and a single write site. Third place the barrel's
one-owner-per-cycle rule has deleted an arbiter.

### The integration harness

`scripts/tb_m3_pass5_int.v` wires BarrelSeq + RegWindowCtx +
FrameRamProc with the TB playing the engine datapath, and runs a real
call/ret: stage an arg, call (pointer rename + link push + background
drain into the claimed frame), the callee reads the staged arg, returns
a value, the caller's 16 registers stream back one word per owner turn,
and the return value lands in the caller's dest register — all verified
by value, while a SECOND context loops concurrently and its registers
stay intact. That last check is the port-0 proof: the fill write only
ever lands on the filling context's own X slot, where no bundle exists,
so the shared port needs priority, not arbitration.

Engine glue proven by the harness and owed to the integration pass: the
one-cycle `fillw_en`/`fillw_idx`/`fillw_seat` delay pair (M2's, reused
verbatim) and the port-0 phase mux.

### Reordering

The swap unit moves from pass 5 to pass 6: it saves and restores a
seat's registers keyed by proc slot, and that mapping is the seat
file's state. Pass 5 therefore ends at "frames are per-process and the
three parts compose"; pass 6 is the seat file + swap unit + reduction
counter + deschedule.

---

## Pass 6 (2026-08-23) — the machine makes its first decision

`SeatUnit`: the seat file, the reduction counters, the deschedule
rule, and the swap unit. 383 LUT + 266 FF + 1 EBR. Updated ledger
total for the barrel's scheduling half: ProcTable + RunQueue +
BarrelSeq + SeatUnit ≈ 1,133 LUT — the concurrency machinery costs
about a fifth of one register window.

### The rule, and where it is evaluated

    exhausted AND waiters  → unseat to the queue tail, seat the head
    exhausted AND no queue → reload the budget, keep the seat
    seat empty AND waiters → seat the head (lazy fill at rotation)
    yield                  → force the budget to 0 at X; same path

Every test happens at the OWNING SEAT'S OWN F SLOT, so the barrel's
one-owner-per-cycle property makes the whole scheduler arbiter-free —
the fourth time that rule has deleted arbitration (after the drain
claim, the fill claim, and FrameRam's depth-counter write port).

### The swap needs no new window port

Save reuses the window's DRAIN replica with its read pointer muxed
from `spl` to `cur` (`op_swap`, no rename): 16 words out through the
same `spill_*` stream a call uses, into a 512 × 36 save RAM (one EBR,
`{slot:5, reg:4}`). Restore streams back one word per owner turn
through port 0, paced exactly like the ret fill and muxed with it by
phase. ≈ 16 + 17 owner turns — the model's `swap_cost` of 32, in
gates, for one extra EBR and two muxes.

The save RAM zeroes at reset, so a never-swapped process restores a
clean window — which is exactly the hook pass 7 needs: staging a
newborn's args means writing them into its save area and letting the
ordinary seat-in path bring it to life. One mechanism, two callers.

### The one-turn pipeline drain (the M2 link-capture lesson, again)

A seat cleared at its F slot still has bundles in D and X that will
retire and move its pc. So the FSM clears the seat, waits for that
seat's NEXT F slot (4 cycles — the pipeline is empty by then), and
only then trusts `f_pc` as the resume address. Save the pc a turn
early and you save the wrong one: the same species as the M2 link
capture, caught here by construction rather than by silicon.

### What the testbench proved

`scripts/tb_m3_pass6.v` wires FIVE components — BarrelSeq + SeatUnit +
ProcTable + RunQueue + RegWindowCtx — and runs six processes on four
seats with BUDGET = 8. Each process writes its own slot id into r1 on
entry and re-checks it every loop iteration, so a swap that restores
the wrong window, or loses one, fails by value on the very next turn
that process runs.

    swaps=67  invariant checks=2221  turns=[741 747 753 758 735 712]

Six processes, four seats, spread inside 6% — round-robin fairness
falling out of a counter and a FIFO, with 2,221 verified window
restorations and no cross-contamination.

### The bug the testbench caught

`save` wrote the resume pc but left the proc's state reading
`resident`, so descheduled processes lied about their residency. Fixed
at the source: ProcTable's `save` now sets `state = queued` in the
same command, which is also one fewer cycle on the single command
port. Nothing consumed the state column yet, so this was a latent bug
being paid forward to M4 — exactly what a state-invariant assertion in
a testbench is for, and worth keeping the habit.

---

## Pass 7 (2026-08-23) — spawn and self

Processes now create processes. `spawn` is call-shaped end to end and
costs the spawner ONE visible turn, with everything else in the
background:

    X:        is_spawn → park (state 9), latch the entry pc in the
              context's existing call-target register
    F slot:   spawn_ready (a free slot + an idle drain + an idle seat
              unit) → commit: allocate, push the newborn on the run
              queue, claim the window drain against the spawner's
              STAGING slot, pc + 1, run again
    +2 cyc:   the pid goes back to the spawner's rd through port 0
    +16 cyc:  the staged args finish draining into the newborn's SAVE
              area — after which the ORDINARY seat-in path wakes it

That last line is the pass-6 prediction paid off exactly: because the
save RAM zero-inits and seat-in always restores from it, "hand a
newborn its arguments" and "restore a swapped-out process" are the same
mechanism with a different source slot. Spawn added no restore path,
no second save area, and no new window port — just a third source
(`stg`) on the drain replica that already had two.

`self` costs nothing: the seat file already holds `{slot, serial}` per
seat, so `self_pid` is a combinational output of the seat unit, and the
unit owns the PID layout (`tag_pid<<32 | engine<<28 | slot<<22 |
serial`) so nothing else needs to know it. Verified against
`PicoBEAM.Term.make(:pid, …)` bit for bit.

A full proc table answers `spawn_full` instead of `spawn_ready`, and
BarrelSeq turns that into a fault on the SPAWNER — `:system_limit`,
per `notes/13`, resolved at an F slot through a one-cycle death pulse
since the fault does not arise at X.

### What the testbench proved

`scripts/tb_m3_pass7.v`: a root spawns eight children, each with a
distinct staged argument, then halts; every child checks the argument
it woke up with and its own identity.

    spawned=8 args_ok=8 pids_ok=8 deaths=9 occ=0 swaps=9

The closing invariant is the one worth naming: **the pid `spawn` handed
the parent is bit-for-bit the pid the child later reports for `self`,
and the argument the parent staged is the argument the child wakes up
with** — parent-side promise and child-side reality, checked against
each other across an allocation, a drain, a queue, a seat-in and a
restore. `occ` returning to 0 says every slot was freed.

### Two bugs, both worth keeping in the log

**The state field outgrew itself.** `cstate` was three bits; spawn_park
arrived as state 9 and truncated to 1 — *run*. The context re-fetched
its spawn bundle forever, silently runnable. Exactly the species of the
M2 `pidx` collapse and the emitter width bugs in `notes/15`: a new
encoding value outgrew its field. The field is four bits now, and the
moduledoc says why. Check the width whenever a state is added.

**The pid came back too late.** The first implementation wrote rd after
the staging drain, so the spawner resumed and read a stale rd — and,
worse, staged the NEXT spawn's argument before the previous pid had
been accounted for, skewing arguments by one. But ProcTable answers
alloc combinationally, so the pid is known AT commit: it now goes back
at the spawner's very next X slot, two cycles after commit and four
before the spawner's next bundle can read rd. Spawn keeps its one-turn
cost and the drain stays in the background.

### Ledger

| part | LUT4 | FF | DPR16X4 | DP16KD |
|---|---|---|---|---|
| ProcTable | 108 | 16 | 36 | — |
| RunQueue | 22 | 16 | 4 | — |
| BarrelSeq (T=4, +spawn) | 1,157 | 123 | — | — |
| SeatUnit (+spawn, +self) | 458 | 300 | — | 1 |
| RegWindowCtx | 5,212 | 824 | — | 21 |
| FrameRamProc | 1,189 | 224 | 64 | 8 |

Remaining for M3: engine integration (the datapath the pass-5 and
pass-7 harnesses have been standing in for — classification, ALU,
heap, the port-0 phase mux, `self`'s write-back) and then `DemoSpawn`
on silicon with the scope trace.

---

## Pass 8 (2026-08-23) — the engine, integrated

`BarrelEngine` replaces every stand-in the earlier harnesses used:
real `Decode`, real `Classify`, real `Alu`, a real assembled image
through the loader side-door, a real proc table and run queue. Two
programs run on it, both assembled by the toolchain that has been
eating its own output since M1:

    DemoSpawn   root spawns 8 workers, each handed a distinct argument
                → values=[8 7 6 5 4 3 2 1], deaths=9, occ=0, no faults

    fib         root spawns TWO fib processes, arguments 10 and 7
                → results=[13 55], deaths=3, occ=0, no faults

The second is the one to frame: **two independent recursions, each
eleven frames deep, running concurrently through one pipeline** — the
M2 milestone (fib(10) = 55) now arriving as a process among processes
rather than as the only thing the machine can do.

### Two decoders on purpose

A bundle is decoded at D to form the window's read addresses and again
at X to drive the ALU, the write ports and control. Carrying ~150 bits
of decoded fields across D→X would cost more flops than re-decoding
costs LUTs — `Decode` is pure bit-slicing and `Classify` is a handful
of byte compares — so the 72-bit bundle is the pipeline register and
the decode is duplicated deliberately.

### Port 0, seven sources, still no arbiter

    ret-fill · swap-in fill · spawn's pid · ret dest · ALU result ·
    arg staging · self

The first four belong to PARKED contexts, whose X slots carry no
bundle; the last three belong to the running context's own X slot. One
context owns any X cycle, so the mux is a priority chain, not an
arbiter — the fifth structure the barrel's one-owner-per-cycle rule has
made free.

### Per-seat latches the barrel needs and M2 did not

M2 decoded and committed a call in the same neighbourhood of cycles, so
the dest register and return value rode combinational wires. Here a
call or spawn commits at a LATER F slot — with other contexts in
between — so the engine keeps per-seat latches for call dest, spawn rd
and the ret value, written at X and read at the owning seat's commit.

### Three findings

**Deschedule could abandon a fill.** `SeatUnit` swapped any valid seat
whose budget was exhausted, including one mid ret-fill — which would
strand the shared fill unit forever. It now requires `f_run`
(BarrelSeq's `f_en`): only a RUNNING context may be descheduled. Caught
while wiring, before it could ever be observed.

**Frame depth 8 was too shallow for the first real program.** `fib(10)`
recurses eleven frames deep and faulted where M2's flat 32-frame store
had not. The bound moved to 15 (8 EBRs → 16) and, exactly as pass 5
claimed, nothing structural changed — addressing and the counter file
kept their shape. A reminder that per-process bounds need sizing
against real recursion, not against a round number.

**A test program that forgot to stage its argument** produced fib = 0
and briefly looked like the M2 silicon bug returning. It was the
program: `call` takes its arguments from the staging slot, and the
wrapper never wrote one. Worth logging because the failure signature of
"argument never staged" and "value lost in the ret chain" is identical
from the outside — check the program before the machine.

### Cost

| | LUT4 | FF | DPR16X4 | DP16KD |
|---|---|---|---|---|
| **BarrelEngine (T=4, whole)** | **10,292** | **1,861** | **166** | **40** |
| M2 Engine (T=1) for comparison | 5,269 | ~1,000 | 378 | 7 |

Four contexts, a process table, a run queue, a scheduler, a swap unit
and spawn for 1.95× the single-context M2 engine — and 40 of the 85F's
208 EBRs. The DPR16X4 count FELL by more than half: the register
window's move to block RAM more than paid for the seat and frame
machinery added on top of it.

Remaining for M3: the board top (`DemoSpawn` on the ULX3S with per-seat
LEDs and the UART oracle carrying seat occupancy), then silicon and the
scope trace of the 1/T comb.

---

## Pass 9 (2026-08-23) — M3 on silicon

`Ulx3sM3Top`: PLL (25 → 12 MHz exact, M2's numbers unchanged), the demo
image in a 64-bundle ROM, `BarrelEngine`, the LED instrument, and the
debug UART re-aimed at the barrel. No microSD — M2 proved that path,
and a ROM keeps build → flash → observe to one `fujprog`. `SdBoot`
drops back in unchanged when an image outgrows the ROM; the side-door
contract is identical.

| | |
|---|---|
| Whole board top | 8,143 LUT4 · 1,922 FF · 166 DPR16X4 · 41 DP16KD · PLL |
| Timing | **27.2–30.2 MHz ≥ 12 MHz — PASS** |
| Bitstream | 536,002 B |

**The barrel got FASTER than the machine it replaced.** M2's
single-context engine closed at 23.3 MHz; four contexts, a scheduler, a
process table and a swap unit close at 27.2 — because splitting fetch,
decode and execute across F/D/X did exactly what `notes/15` predicted it
would when it recorded 36 ns of logic in one M2 exec cycle. More
machine, shorter critical path.

### The demo, and why the workers do not die

Six workers that announce themselves and then spin forever: four seats
stay permanently occupied and two processes stay permanently queued, so
the rotation runs under sustained load and the scheduler swaps
continuously. A demo whose processes exit would show the comb for a
few microseconds and then an idle machine — this one shows it until
power is removed.

### On the board

    p00d 1 3 00 006 002 1 1 01 11
     │   │ │  │   │   │  │ │  │  └ seat 3 state
     │   │ │  │   │   │  │ │  └─── deaths (the root, once)
     │   │ │  │   │   │  │ └────── last out byte (worker 1)
     │   │ │  │   │   │  └──────── seat 2 state
     │   │ │  │   │   └─────────── seat 1 state
     │   │ │  │   └─────────────── run-queue depth = 2
     │   │ │  └─────────────────── proc-table occupancy = 6
     │   │ └────────────────────── no fault
     │   └──────────────────────── flags {idle,fault,x_en,out_seen}
     └──────────────────────────── pc, cycling the worker spin loop

Held steady across captures seconds apart: **six live processes, two
waiting, one death (the root), no faults**. The pc wanders 00b/00c/00d
because whichever worker is in X at the sampling instant is somewhere
in its three-bundle loop, and the seat states flicker between run and
idle as the swap unit rotates the two queued processes through the four
seats.

### The instrument

`led[3:0]` are the raw per-seat retire strobes — seat k's pin is high
exactly on the cycles seat k retires a bundle. At 12 MHz with T = 4
that is a 3 MHz square wave per seat, 90° apart: the 1/T comb, on a
scope, as the M3 exit demo's evidence. The whole-top simulation
measured the shares first:

    seat_strobes = [37879 37713 37790 37835]      spread 0.4%

Four processes, one pipeline, equal shares to within four parts in a
thousand — and no scheduler policy anywhere in the machine, only a
2-bit counter.

To the naked eye the four pins are simply four equal dim glows, which
is the same claim without instruments. `led[7:4]` show the spawn count
(6); FIRE2 swaps in the last worker result; FIRE1 re-boots.

### M3 exit criteria

`07-roadmap.md` asked for "T contexts, reduction counter, run queue,
process table, SPAWN and YIELD within one engine. Demo: a thousand
spawns, and a scope trace showing exact 1/T interleaving." The
mechanism is all present and on silicon; the spawn count in this demo
is six rather than a thousand because a 32-slot proc table with
non-exiting workers is the honest limit — a thousand-spawn variant
needs exiting workers and is a program change, not a machine change.

---

## Pass 10 (2026-08-23) — a thousand spawns, on silicon

`07-roadmap.md`'s M3 demo, met literally. One line off the board:

    p000 0 9 00 3e8 3e9 0 0 55 66
              │  │   │        │
              │  │   │        └─ out = 0x55, the completion marker
              │  │   └────────── deaths = 0x3e9 = 1001
              │  └────────────── spawns = 0x3e8 = 1000
              └───────────────── occupancy = 0

**A thousand processes created and reaped, the proc table drained to
zero, the root's marker emitted, machine idle.** No leaked slot, no
`:system_limit`, no fault.

Getting there needed one thing the machine deliberately does not
provide: **backpressure is the program's job.** A 32-slot table plus a
~17-turn seat-in makes reaping slower than spawning, so an unthrottled
root fills the table and takes `:system_limit` on itself — correct
behaviour, and exactly the shape `notes/13` argues for restart
intensity. The demo's root therefore counts a short delay loop between
spawns. Mechanism in gates, policy in code, one more time.

### Two demos, one bitstream

They prove different things and cannot be the same program:

* **A — a thousand spawns** (default). Runs at LOW process count: a
  root plus whichever worker is being reaped. The rotation phase-locks
  onto two seats and the other two idle. That is the barrel's honest
  behaviour when there is not enough work to fill it — a lone process
  gets 1/T, which `03-architecture.md` named as the trade going in.
* **B — the 1/T comb** (hold FIRE2 through reset). Six workers that
  never exit keep four seats saturated and two processes permanently
  queued, so the rotation runs under load and the seat strobes are a
  clean four-phase comb. Whole-top simulation:

      seat_strobes = [37879 37713 37790 37835]      spread 0.4%

The LED semantic follows the LATCHED demo choice rather than the live
button, because FIRE2 is held through demo B to select it and must not
also mean "change the view" — a small thing that cost one debug cycle
and is worth stating.

### Board

| | |
|---|---|
| Whole top, both demos | 8,159 LUT4 · 41 DP16KD · PLL |
| Timing | 25.7–30.7 MHz ≥ 12 MHz — PASS |
| Bitstream | 535,110 B |

The debug UART's two 3-digit fields were widened from 9-bit pc taps to
full 12-bit counters so a four-digit spawn count could be displayed —
`AAA` and `LLL` racing each other to 3e8/3e9 is the demo, readable at
115200 baud.

**M3 is complete.** T contexts, reduction counter, run queue, process
table, spawn, yield, self — in fabric, on a board, with a thousand
spawns and a scope-visible comb as the evidence. M4 is the mailbox.
