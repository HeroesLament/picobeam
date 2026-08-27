# 53 — The SMP correction

Mac, on being shown that `register/2` refuses a pid the round-robin
placed on engine 1: *"that's a misconception. I had envisioned these
running as a single node... our multi-engine arch needs to be more
like an SMP story than a distribution story."*

This note is the correction and the plan. It rereads `notes/12`'s
central sentence — "an engine is a node, not a scheduler thread" —
and replaces it: **an engine is a scheduler. The machine is the node.
The ring is the node's interconnect, not its distribution channel.**

## 1. Why this is a relabeling, not a rebuild

The reflex reading of "SMP, not distribution" is "shared heap, big
rework". It is not, because of a fact about real BEAM that this
project's architecture accidentally honors: **SMP BEAM with private
process heaps copies every message anyway.** A send between two
processes on one node, on one scheduler, on real BEAM, serialises the
term out of the sender's heap into the receiver's. That is what our
ring does. The copying was never distribution semantics — it was
private-heap semantics, which is BEAM's default and the reason its
GC pauses are per-process. `notes/46` built exactly that collector.

So the inventory of what SMP actually changes is short, and it is all
NAMING and VISIBILITY, not memory:

| | as built (notes/12 doctrine) | SMP truth |
|---|---|---|
| message send, any pid | copies, ring if remote | UNCHANGED — this is BEAM |
| per-process heaps + GC | private, per-engine arenas | UNCHANGED |
| pid carries engine field | "the pid is the route" | fine — an opaque implementation detail, like BEAM's own table indices |
| spawn placement | round-robin (notes/49) | UNCHANGED — this is now just scheduling, which BEAM promises nothing about |
| **registry** | per-engine CAM, node-local | **WRONG — must be node-global** |
| **link/monitor/exit across engines** | ring kinds 3–8 defined, gates DROP them | **WRONG — supervision must not care where a process runs** |
| halt | node-global sideband | already SMP — notes/33 got there first |
| atoms, code | identical image both engines | fine — per-scheduler icache, in effect |

Two rows are wrong. Everything else survives with a better name than
it had.

## 2. The registry: a shared node-level unit

Three designs considered for making `register`/`whereis` node-global:

* **Hashed ownership** — a name's owner engine is a hash of the atom;
  non-local operations cross the ring. Scales to many engines; adds a
  request/reply protocol, latency, and a consistency argument. The
  right shape at N=16. Overkill at N=2.
* **Replicated CAMs with broadcast** — every engine answers whereis
  locally; registration routes through an arbiter engine and
  broadcasts. Fast lookups, but now there is a consistency window and
  an ordering argument leaning on ring FIFO-ness. Machinery bought to
  avoid sharing — which was the distribution reflex again.
* **One shared CAM at the node level** — the registry moves out of
  `BarrelEngine` and up to the top, beside the halt sideband, with
  both engines' ports into it. No protocol, no replicas, no window:
  a registration is globally visible the cycle it lands, which is
  BEAM's own guarantee. Does not scale past a handful of engines —
  and every fabric this design fits is 1, 2 or 4 (`notes/49`).

**Decided: the shared CAM.** The doctrine that forbade shared
structures between engines was the distribution doctrine, and it is
the thing being retired. `notes/33`'s halt sideband is the precedent:
node-global state lives at node level. The registry is node-global
state. (The flattened netlist makes "moving it to the top" almost
free — it is wires either way; what matters is who may drive them.)

Consequences, each small:

* `register/2` drops the `pid_engine == eng_id` check — there is no
  such thing as a remote pid inside one node. Aliveness checks read
  the pid's HOME engine's proc-table mirror, which at node level is
  just another async read port on a LUTRAM that already has four.
* Port contention: two engines can issue registry ops in the same
  cycle. Ops are rare (a registration per process lifetime, a whereis
  per call at worst); a fixed-priority arbiter that makes the losing
  engine's op retry its X slot is enough, and the retry is the same
  replay a `gc_park` already performs.
* Send-to-name resolves against the shared CAM; a hit whose pid lives
  on the other engine is just a remote send, which is the existing
  ring path. `Name ! Msg` to anywhere, for free.
* Death clears arrive from both engines' `died` strobes; two clears
  in one cycle target different entries by construction (two deaths,
  two pids, two entries).
* The model merges `e.names` into one `m.names` map and deletes the
  node-local refusal. Its tests get SIMPLER.

## 3. Supervision must cross engines

The gates today pop and drop ring kinds 3–8. In a node, that means
`spawn_link` to a child the round-robin placed away silently loses
the link — a supervisor that cannot see its child die is not a
supervisor. The model already carries exit/DOWN signals across
(`wire/4` does not care where the target lives); the gates must grow:

* **kind 6, `exit_signal`** — the link fan-out's remote leg. The
  emitter already walks the link table and emits 4-flit signals
  locally; a remote peer becomes a ring packet carrying {from, reason},
  delivered into the far engine's existing signal-delivery path.
* **kind 7, `down_signal`** — same shape, monitors, 5 flits with ref.
* **kinds 3/4/5, link/unlink/monitor_req** — registration of the
  relationship itself when the two ends live apart; each is a small
  request that lands in the far link table, plus `noproc` (kind 8)
  coming back when the target is already dead.

This is the largest block of work in the plan, and it is the one that
makes "OTP on picoBEAM" true rather than true-on-one-engine. The
incarnation checks the ring already performs on arrival are exactly
the dead-letter semantics these signals need.

## 4. What "distribution" now means

The word is not deleted — it is promoted. Distribution is
MULTI-BOARD: a second ULX3S on a real wire, a node id above the
engine id, and the serialised-term format the ring already speaks
becoming a wire format between machines. The pieces built under the
old doctrine — copied terms, incarnation checks, packets that carry
their destination — are precisely what a two-board picoBEAM needs.
Nothing from notes/29/47/49 is wasted; it was distribution
infrastructure built one level too early, now waiting at the level
it belongs.

## 5. The plan, in order

Cheapest and most-unblocking first, per `notes/51`; RTL batched into
one bitstream at the end.

1. **Reset audit (entry 36)** — `sp_rr`, the CAM valid bits,
   `next_ref`, doom state onto the image-push reset path. Small RTL;
   rides the batch. The counter-pushed-twice test is its gate.
2. **Model: the SMP registry** — one `m.names`, drop node-local
   refusal, aliveness via `fetch_remote` (any engine). Rewrite the
   node-local two-engine test to assert the OPPOSITE: engine 1's
   whereis FINDS engine 0's name, and register(remote_child) works.
   The counter demo with `engines: 2` becomes a permanent test — the
   program that found the misconception guards the correction.
3. **Gates: the shared CAM** — NameTable instance moves to node
   level (M5Core), arbiter for the two engines' ops, cross-engine
   aliveness read, send-to-name → remote-send handoff. tb_spawn2-
   style two-engine testbench: register on 0, whereis and send by
   name from 1.
4. **Gates: ring kinds 6/7 (exit, DOWN)** — supervision's remote
   legs, model-compared. Then 3/4/5/8 (remote link/monitor setup).
   Two testbenches: cross-engine spawn_link where the child dies, and
   a cross-engine monitor seeing DOWN.
5. **One bitstream.** Counter pushed twice in a row; a cross-engine
   supervised demo; the board's status line as the verdict.
6. **notes/12 postscript** pointing here, so the next reader meets
   the doctrine and its correction in the same sitting.

Not in this plan, named so their absence is a decision: work
stealing/migration (spawn-time placement only — BEAM promises
nothing), shared binary heap for large messages (real SMP BEAM
refc-shares big binaries; ours copy — a performance note, not a
semantics bug), ETS (its natural home is now obvious: a shared
node-level unit, like the registry).

---

## 6. Touch points — the file-by-file inventory

Surveyed against the tree as it stands (post-`notes/52`), not from
memory. Ordered by phase; each phase ends at a test that gates it.

### Phase 1 — the reset audit (entry 36, sharpened)

The push DOES reset: `eng_rst = bor(rst, bst == 0)` holds the engines
in reset while an image loads, and the CAM's valids already sit in its
own rst block. The leak is precisely the registers relying on `init:`
alone — bitstream-time initialization, which survives everything short
of reconfiguration. The audit found **174** such registers in
`BarrelEngine`; most are data latches rewritten before read, and the
semantic subset must join the rst block:

* `lib/pico_beam/rtl/barrel_engine.ex` — add to `if rst == 1`:
  `sp_rr` (the counter that bit), `next_ref`, and every FSM/valid:
  `rg_st rg_ok rg_head rg_left`, `rt_st rt_i rt_kind`, `ro_busy
  ro_have ro_pdone`, `rx_pend rx_rep`, `sr_rem sr_head sr_hdr`,
  `sd_st`, `dzw_pend`, `dz_take`, `sg_rem0..3` (a stale remote flag
  replays a ring send), `spr0..3`, `bx0..3`. Data latches (cd/hl/rv/
  tx/rx-payload...) may stay init-only — write down WHY per group.
* `lib/pico_beam/rtl/name_table.ex`, `proc_table`, `mailbox`,
  `run_queue`, `signal_table`, `reg_window_ctx`, `heap` — same sweep,
  same rule: FSMs, valids, counters, occupancy into rst; pure data
  exempt. (ProcTable/RunQueue likely already correct — they had M3
  reset bugs fixed once; verify, don't assume.)
* **Gate:** the counter image pushed twice in a row on one bitstream,
  both runs clean — plus a `tb_fixed` variant that pulses `rst`
  mid-run and reboots into a second image.

### Phase 2 — the model goes SMP (an evening, all subtractions)

* `lib/pico_beam/machine.ex`
  - `names` moves off the engine struct onto the machine: one
    `m.names`, `%{atom_payload => pid}`. Sites: struct init,
    `{:reg_name,..}` / `{:whereis,..}` / `{:unreg,..}` exec clauses,
    the `{:send,..}` atom-resolution branch, `reap/5`'s
    auto-unregister sweep.
  - `{:reg_name,..}` DROPS `Term.pid_engine(pid) == eid`; aliveness
    stays `fetch_remote/2`, which already works cross-engine.
  - The 8-entry `:system_limit` stays (the shared CAM is still 8).
* `test/names_test.exs` — the node-local test INVERTS: engine 1's
  probe now must FIND `:root` and a send through it must land.
  Add: register a child the round-robin placed remote (the counter's
  exact failure, asserted green).
* `test/` new: `counter_smp_test.exs` — `priv/demo/counter.ex` with
  `engines: 2`, the guard-dog test.
* `scripts/mk_names.exs` stays; expectations regenerate themselves.

### Phase 3 — the shared CAM in gates

* `lib/pico_beam/rtl/name_table.ex`
  - Entry grows an ENGINE field: `{name:16, eng:4, slot:5, serial:22}`
    (s-regs 27→31 bits); `q_eng` joins the lookup outputs; the death
    port keys on `{eng, slot, serial}`.
  - Second command interface OR external arbiter — recommended:
    keep the unit single-ported, arbitrate outside.
* `lib/pico_beam/rtl/barrel_engine.ex`
  - The `instance :names` LEAVES the engine. In its place, ports:
    `nm_req/nm_kind(reg|whereis|unreg|resolve)/nm_name/nm_pid` out,
    `nm_gnt/nm_hit/nm_pid_in/nm_bad_in` back. On `bnot(nm_gnt)` the
    op REPLAYS its X slot — the `gc_park` replay, reused.
  - `regn_ok` drops `nm_pid_w[31..28] == eng_id`. Aliveness for a
    non-local pid cannot read the local `pt_rd2` — it moves to node
    level (below). Engine keeps the tag/undefined checks only.
  - `snd_atom` resolution: `nt_q_*` wires become the node port; a
    resolved pid with a foreign engine field falls into `snd_remote`
    — the existing ring send, untouched. `whereis`'s result word
    assembles from the CAM's stored eng, not `eng_id`.
  - `died` export: already a port (`died`, `su_died_pid`) — reused
    as the node CAM's clear feed.
* `lib/pico_beam/rtl/proc_table.ex` — one more mirror read port
  (`rd7_slot → rd7_state/serial`) per engine, wired UP to the node
  so registration can check aliveness on the pid's home engine.
* `lib/pico_beam/rtl/m5_core.ex` and `duo.ex` — instantiate the CAM
  once; a fixed-priority two-way arbiter (engine 0 wins ties, loser
  replays); both engines' died feeds (two deaths in one cycle clear
  two different entries by construction); both `rd7` probes muxed by
  the pid-under-check's engine bit.
* `scripts/tb_fixed.v` — the single-engine harness must now
  instantiate `name_table` + the trivial arbiter beside the engine,
  or `tb_fixed:names` stops building. Same for `scripts/run_tbs.sh`
  link lines (`$ENG` list gains name_table.v).
* **Gate:** `tb_names2` — register on engine 0, whereis + send-by-
  name from engine 1, child registered cross-engine; and
  `tb_fixed:names` still green single-engine.
* **Risk:** the resolve path is now a cross-engine combinational arc
  (engine → node CAM → engine) on a design closing at 12.48/12.00.
  If timing breaks, the fallback is designed up front: name-sends and
  registry ops take a one-cycle registered handshake (they already
  know how to park), costing latency, not correctness.

### Phase 4 — supervision crosses the ring

The model is the reference: it already wires `link_req`,
`exit_signal`, `down_signal` and the `noproc` replies with flit
counts assigned. The gates must stop being silently wrong first:
today a sup op NEVER examines `sup_pid[31..28]`, so `link` to a
remote pid indexes the LOCAL table with the remote slot bits — a
serial-mismatch dead-letter usually, a false match possibly.

* `lib/pico_beam/rtl/barrel_engine.ex`
  - X-stage sup ops grow `sup_remote = sup_pid[31..28] != eng_id`:
    remote `link`/`unlink`/`monitor`/`exit2` become ring TX requests
    (kinds 3/4/5 + exit2 riding 6), reusing the `rt_*` egress FSM —
    it was built multi-kind on purpose (`notes/49`). `monitor`'s ref
    is minted locally (the ref counter is per-engine; refs need an
    engine field folded in — check `ref_word`'s 0x600000000 layout
    for four spare bits — or DOWN matching breaks).
  - The link-table fanout's remote leg: `lt_sig` targets whose pid is
    foreign emit kind 6/7 packets instead of local `sd_st` delivery.
    The emitter's existing 4/5-flit bursts define the payload.
  - Ingress `rg_kind` dispatch grows cases 3–8, landing in the
    existing machinery: kind 3 → `lk_pend` path, kind 6/7 → the
    `sd_st` delivery FSM (which already handles trap-vs-doom and the
    `:kill` rules), kind 8 → DOWN-with-noproc.
* `lib/pico_beam/rtl/signal_table.ex` — likely untouched (it stores
  relationships; the pid word it stores already carries the engine
  field). Verify `next_slot` prefetch doesn't assume local pids.
* Ring arbitration: the `rt_*` FSM is now shared by spawn transport,
  sup requests, and remote signals — one queue discipline note in
  the code; the `rg_ready` arbiter already serializes producers.
* Model: no changes — which is the point. Every new testbench
  compares against a model run that already worked.
* **Gates (tests):** `tb_slink2` — cross-engine `spawn_link`, child
  dies, parent's trap sees `{'EXIT', pid, reason}`; `tb_mon2` —
  cross-engine monitor, DOWN with the right ref; a `noproc` case for
  each.
* **This phase is the campaign** — sized like `notes/49` was (the
  ring transport plus both ends), not like a fix.

### Phase 5 — one bitstream, and the words

* `bash scripts/build_m5.sh` once, everything batched.
* Board gates: counter pushed twice; a two-engine supervised demo
  (registered server on one engine, supervisor on the other, kill →
  restart → answer) — which is also the V1 demo for showing someone.
* `notes/12` postscript pointing here; `README.md` architecture
  paragraph reworded (node/scheduler/interconnect); `AGENTS.md`
  doctrine line updated; `notes/48`'s absence list amended.

### Explicitly deferred, so the absences are decisions

Work stealing (spawn-time placement only), refc-shared binaries
(copying big binaries is a perf note, not a semantics bug), ETS (now
obviously another shared node unit), multi-board distribution (the
promoted meaning of the word — the ring format is ready for it).
