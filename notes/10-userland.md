# 10 — Userland: how code that isn't ours runs on silicon that is

Decisions from the boundary/packaging design discussion (2026-08-22). This
note covers the hardware/software boundary (SIFs, hardware ports, the `api`
block), the artifact and repository topology, and what each decision forces.
The driving example throughout is an OcuSync-class OFDM video waveform on
AD936x 2×2 MIMO — a large fabric PHY whose MAC layer runs as Erlang processes
on picoBEAM. Boot and image format are in `11-boot-and-images.md`.

## The rule that shapes everything: samples never become terms

A video-rate MIMO stream can never traverse a 36-bit-flit mailbox, and Bet 1
means there is no shared memory to map. So the PHY — correlators, OFDM
demod, FEC, framing — is a pure-fabric pipeline from the transceiver pins to
wherever bytes go, and what crosses into the Erlang world is **control,
events, and descriptors**: "frame 214 landed in buffer 6, CRC good," never
the frame. The Erlang-visible API of a waveform is therefore a MAC-layer API
— channel hopping, rate adaptation, ARQ, pairing, link stats — which is
soft-decision logic on millisecond timescales, i.e. exactly the shape Erlang
exists for. This is also v1-compatible by construction: no binaries needed,
because payload bytes never enter the term world.

Descriptor lifetime is the one problem this creates early: frame buffers
live outside the term heap, so v1 uses fixed rings where hardware recycles
slots and a descriptor is just an index. A real `BIN`-tag story is v2.

## The boundary has exactly three tiers

| Tier | Name | Shape | Carries |
|---|---|---|---|
| 0 | **stream plane** | fabric-to-fabric wiring (`interface`/`connect`) | samples, symbols, bytes — never terms |
| 1 | **hardware port** | a process: PID, mailbox endpoint on the ring | config, events, stats, descriptors |
| 2 | **SIF** — Silicon-Implemented Function | an instruction: `SIF idx, args → result` | single bounded-latency reads/writes |

Naming follows NIF: a SIF is a Silicon-Implemented Function. A hardware
port makes the BEAM pun physical — an Erlang port that is a port.

**The discipline that keeps the tiers honest:** every SIF declares a
worst-case latency at elaboration and the linter enforces it; anything
unbounded must be a port message. SIF = synchronous and bounded, port =
asynchronous and unbounded, nothing in between. A SIF's declared latency
folds directly into its caller's WCET, so the determinism story composes
across the boundary.

**The barrel dissolves the dirty-NIF problem.** A context waiting on a SIF
simply does not fetch on its rotation turns; the other T−1 contexts lose
nothing. BEAM needed dirty schedulers and a decade of folklore because a
long NIF blocks a whole scheduler — here that failure mode is
unrepresentable, the same structural trick as the GC claim. Cost: a
scoreboard bit per context in the pipeline. That is an M2/M3 datapath input,
not a bolt-on.

**Q8 is now resolved more precisely than its recorded leaning.** Not
"ports-as-processes with `PORT_READ` as escape hatch" — ports for the
asynchronous world, declared-latency SIFs for the synchronous one, and the
escape hatch *deleted*: an undeclared poke into fabric is exactly the ABI
drift this whole scheme exists to prevent. (Appended to Q8 in
`08-open-questions.md`.)

## Ports are supervisable, and that is the point

Everything from the supervision design carries over to silicon: `link` and
`monitor` against a port PID are ordinary table entries; a peripheral fault
is an exit signal carrying a **reserved reason atom** (hardware-emitted
reasons get fixed atom-table indices so the fault path is allocation-free);
a supervisor's restart of a port is a **reset pulse into the block plus a
PID-serial bump**. The 22-bit PID serial is the incarnation counter —
delivery hardware compares slot *and* serial, so stale PIDs to dead
incarnations dead-letter instead of aliasing. The supervision tree is the
recovery model for the entire chip, one mechanism from a crashed process
down to a wedged modem. (Full supervision note still to be written;
the mechanism/policy split is: links, monitors, signal propagation and
crash detection in gates — restart *policy* as an ordinary resident
process.)

## The `api` block: declare the boundary once, generate both sides

FFIs rot because the boundary is specified twice. Here the RTL, the ISA,
the compiler and the application language share one compile, so the API is
declared once, on the component, and everything else is emitted:

```elixir
defmodule OcuSync.Modem do
  use Hw.Component
  use PicoBEAM.Port, name: :ocusync    # claims a port PID at elaboration

  # ... RTL: correlators, demod, FEC, AD936x interface ...

  api do
    call  :set_channel, [:u8], :ok
    call  :stats, [], {:rssi, :evm, :mcs}
    event :link_state, one_of: [:up, :down, :syncing]
    event :frame, {:buf_idx, :len, :crc_ok}
    sif   :rssi_now, [], :u16, cycles: 2
  end
end
```

Elaboration emits, from that single block: the CSR/handshake RTL; the
ring-endpoint glue that makes the block answer to its PID; its reserved
reason atoms; and a generated Core Erlang client module (`ocusync:...`)
where `rssi_now/0` compiles literally to the SIF instruction. The ABI
cannot drift because there is no second artifact to drift.

For IP that is not EHDL-native (wrapped Verilog, vendor blackboxes), the
same declaration attaches via a standalone **`defport`** form — an `api`
block bound to a blackbox instance plus a register map. This is Rustler's
"thin crate wrapping an existing C library" pattern.

## Repository and artifact topology: three tiers

User code does not live in the ehdl repo, and application code does not
live in the bitstream repo. The models are Rustler (macro ergonomics) and
Nerves (build/packaging shape):

1. **Libraries** — `ehdl` (HDL, simulator, linter, emitter) and `pico_beam`
   (engine/fabric IP, fit solver, boundary macros, Core-Erlang→ISA
   compiler). Hex packages, nothing app-specific.
2. **The bitstream project** — a board/product repo: fabric top, the IP,
   the boundary declarations. Its build emits **two artifacts**: the
   bitstream, and a **generated SDK package** — the client modules from the
   `api` blocks, the frozen SIF-index/port-PID map, the reserved-atom map,
   fit facts, and behavioural stubs of every port for host-side testing.
   (Precedent: LiteX emitting `csr.svd` for firmware to build against —
   except our "header file" is working Erlang modules.)
3. **Application projects** — plural. Depend on `pico_beam` (compiler) plus
   the generated SDK; build a **code image** (see `11-boot-and-images.md`).
   Several apps can target one bitstream; one app can target several
   bitstreams. The application team never sees Verilog or nextpnr.

Third-party IP ships as a hex package containing all three faces —
EHDL components, boundary declaration, target-side client library —
versioned together: **a package manager for supervised peripherals**.

## Four named sub-problems, each with a trap

- **Discovery.** SIF indices and port PIDs are global resources, but
  declarations live in arbitrary apps. Collection is explicit, not scanned:
  the fabric top names its boundaries (`boundaries: [...]` or
  `boundary_apps: [...]`), each `api` block exports `__pico_boundary__/0`,
  and `Fabric.build/1` gathers. Silent inclusion of a dep's port is a
  surprise a determinism-first project must not tolerate.
- **Deterministic assignment.** Indices are a pure function of the
  declaration set — sorted by `{app, module, name}` — never of discovery
  order, and the assignment is emitted as a build artifact (a
  `boundary.lock`-shaped map) so a human and a logic analyzer can both
  answer "what is SIF 9". This is the Gensym lesson (ehdl's
  nondeterministic net names silently invalidated every seed sweep) applied
  before the mistake instead of after.
- **Two clocks of code.** A user project contains Elixir that runs at
  elaboration time (component bodies, fit, `api` blocks) and Erlang/Elixir
  that runs on the machine. Same language, different worlds — split by
  directory/compiler convention (Nerves-style: `hw/` into the design,
  `rom/` through the ISA compiler), never per-function annotation. A module
  is one or the other; the `api` block is the only straddler, and it
  straddles by *generating* into the ROM side, not executing there.
  Decide at M1 — it constrains the compiler's entry points.
- **The ABI seam.** Bitstream and image can now version-skew. The bitstream
  hashes its boundary map into a CSR; the image records the SDK hash it
  compiled against; the loader compares and refuses a mismatch, loudly.
  Mechanics in `11-boot-and-images.md`.

## The testability ladder

Three rungs, one source: `mix test` in the app repo runs supervisors and
MAC logic against the SDK's behavioural port stubs on the plain BEAM (no
ehdl installed); `mix pico.sim` runs the same image against the M1
reference interpreter; the board runs it against gates. Only the bottom
rung needs a synthesis tool. This makes the "instrument is the device under
test" discipline something downstream users inherit rather than a house
rule.

## Debt this creates upstream, on the ledger now

- **ehdl:** `Hw.Sim.Schedule`'s `@instance_prefixes` table is hardcoded to
  HelloBoard's instance names — entity partitioning does not work for a
  design it hasn't heard of. Fine for a single-repo research tool, fatal
  for ehdl-as-dependency. Deriving it from `__hw_instances__` is contained
  but touches the M0 machinery; schedule it deliberately.
- **pico_beam / M1:** the `sif` form needs an opcode and the scoreboard
  bit; the port protocol needs its flit format frozen with the ISA; the
  reserved-atom region belongs to `pico_beam`'s version, not the board.
- **Constraint noted:** interface rate on the Zynq/AD936x target is capped
  (~16 MHz lanes) by the openXC7 ILOGIC/ISERDES gap recorded in ehdl's
  notes — a full-rate OcuSync-class demo is gated on that fuzzer work, not
  on anything in this note.
