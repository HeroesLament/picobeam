# 51 — The price of a change

Written while waiting fifty minutes for a bitstream, at Mac's request,
after Mac watched `yosys-abc` chew and said the thing out loud: *"this
is why we do need to get better at simming stuff modularly... I didn't
realize getting changes onto the FPGA would be so painful."*

This note is the economics of changing picoBEAM: what each kind of
change costs, why it costs that, which of those costs are self-
inflicted, and what to do about each. It exists because `notes/50`'s
features hit the board green on their FIRST bitstream, and that was
not luck — it was a cost ladder used properly, mostly by accident.
This note is the accident written down so it can be a policy.

---

## 1. Two kinds of change, three orders of magnitude apart

The single most important fact about iterating on this machine:

**A program change costs seconds.** The bitstream is the MACHINE; the
image is the PROGRAM. `mix run scripts/mk_names.exs` rebuilds the
image in about four seconds, `fujprog -a` pushes it down the debug
cable in 325 milliseconds, and the board is running the new program
before the editor window loses focus. `notes/37` and `notes/38` built
exactly this and it is the best tooling decision in the project.

**An RTL change costs the better part of an hour.** Any edit under
`lib/pico_beam/rtl/` means yosys → nextpnr → ecppack → flash:

| stage | measured (M5, two engines) | of which |
|---|---|---|
| EHDL emit | ~1 min | |
| yosys | ~18 min CPU | **70% is abc9** (43 CPU-min today) |
| nextpnr place | ~15–20 min | simulated annealing |
| nextpnr route | ~10 min | |
| ecppack + fujprog | seconds | |

So the discipline that matters most costs nothing to adopt: **know
which kind of change you are making.** A day spent on programs is a
day of second-long iterations. RTL changes want to be BATCHED, verified
cheaply, and paid for once — `notes/50` shipped a compiler overhaul,
three new opcodes, a new hardware unit, a sixth ProcTable port and two
`exit2` fixes on a single bitstream, and that is the shape to aim for.

## 2. The cost ladder, as actually used

Every bug found at level N costs roughly ten to a hundred times more
at level N+1. The `notes/50` work, by where its bugs actually died:

| level | cost per run | found there |
|---|---|---|
| `mix test` (model, 85 tests) | ~1 s | all five register-recycling bugs |
| single-module tb (`tb_gc`, `tb_ser`...) | seconds | — (nothing new this round) |
| minimal engine vector (`nmini`, 30 bundles) | ~90 s | the CAM's immediate-vs-compound split |
| `tb_fixed` (full image, one engine) | 1–3 min | the lost wakeup; both `exit2` bugs |
| board build | ~50 min | nothing — it was green first push |

Three RTL bugs died at the ninety-second-to-three-minute level. Each
one found by a board round trip instead would have been an hour; the
whole set, an afternoon. That is the argument for simulation, and it
is an argument the BOARD makes.

The inverse discipline also held, and matters as much: nothing that
the model could catch was hunted in a testbench, and nothing a
testbench could catch was hunted on the board. The expensive levels
are for what only they can see — integration races at the tb level;
timing, congestion and physical truth on silicon. A simulation run
that a cheaper level could have replaced is pure waste, and an hour of
blind full-engine simulation is how this session's earlier mistake
looked from the outside.

**The corollary about vector SIZE:** the minimal `nmini` vector — one
engine, thirty bundles, one behavior per output — found the CAM bug in
ninety seconds. The same bug inside the full `names` demo took ten
minutes a run to even reach, because the flattened two-engine `duo`
netlist takes iverilog minutes just to LOAD. When a tb-level bug
appears, the first move is to SHRINK the program that shows it, not to
re-run the big one with more prints.

## 3. Both pains are one pain: EHDL flattens

Why is abc9 seventy percent of synthesis? Why does iverilog take
minutes to load `duo.v`? Same answer. EHDL emits ONE module: every
instance is inlined into its parent with a prefix, and the two-engine
top is ~431,000 lines of Verilog with no hierarchy left in it.

* **abc9** maps the whole design as a single ~90,000-node logic
  network. Its algorithms are superlinear; module boundaries would let
  it map `collector` once, `name_table` once, each in milliseconds to
  seconds, instead of one giant graph in 43 CPU-minutes.
* **iverilog** parses and elaborates those 431k lines from scratch for
  every single invocation — before the first simulated cycle.
* **nextpnr** is least affected (placement is global anyway), but the
  netlist it ingests is bigger than it needs to be.

The fix is **hierarchical emission in EHDL** — emit each component as
its own module and instantiate it, flattening only where a `param`
actually specializes an instance. That is an EHDL change, not a
picoBEAM change, and it is the single highest-leverage build-speed
item on any list this project could write. It also fixes a
CORRECTNESS wart for free: the port-name/net-name silent merge that
`scripts/check_drivers.py` exists to catch (`notes/41`) is a flattening
artifact, and modules with real ports make it impossible.

## 4. The menu, cheapest first

Ordered by cost-to-adopt, with what each buys:

1. **Batch RTL changes** (free, policy only). Verify at the cheap
   levels, build once per batch. This is how `notes/50` shipped.
2. **A single-engine iteration target** (an afternoon). `build_m5.sh`
   builds two engines because the SHIPPING config is two engines; an
   `build_m5solo.sh` with one engine and no ring would roughly halve
   both synthesis and place-and-route for the majority of RTL work
   that is engine-internal. The two-engine build remains the gate for
   anything touching the ring, spawn transport, or the halt sideband.
3. **`-noabc9` for iteration builds** (one flag). The older abc flow
   maps faster and loses a little Fmax. Fine for "does it work on
   silicon"; not fine for the shipping bitstream — the margin is
   13.52 MHz against a 12.00 MHz clock and that headroom is not for
   spending on impatience.
4. **Verilator for the big testbenches** (a weekend). iverilog
   interprets; Verilator compiles to C++ and runs designs this size
   fifty to a hundred times faster, at the price of a compile step and
   a testbench port (it wants synthesizable tb constructs). Worth it
   the day tb_fixed's minutes become the inner loop; not before.
5. **Hierarchical emission in EHDL** (real work, biggest payoff).
   Fixes synthesis time, simulation load time, and the flattening
   footgun in one move. When it lands, items 3 and 4 matter less.

What is deliberately NOT on the menu: incremental synthesis (yosys has
no real story for it — hierarchy IS the incremental story), and a
faster laptop (the suspend-stretched wall clock made today feel worse
than it is: on desk power this is a ~35-minute build, not 95).

## 5. The rule to keep

One sentence per level:

* The **model** is where semantics get right — if `mix test` can see
  it, nothing else is allowed to be the discovery mechanism.
* A **testbench** is where cycles and races get right, on the
  SMALLEST vector that shows the behavior.
* The **board** is where reality gets right — timing, congestion, the
  card, the cable — and it should be BORING by the time it runs,
  because everything else was caught below.

`notes/48` said the gate is the release. This note's version: the
board is the verdict, the gate is the argument, the model is the
draft — and the price of confusing the levels is measured in hours.
