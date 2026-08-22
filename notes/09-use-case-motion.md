# 09 — Driving use case: fieldbus motion interpolator

**This is the application picoBEAM should be designed against.** It was arrived
at by contrast: FOC current control (the first case tried) is picoBEAM doing
arithmetic in a tight sequential loop, which is its weakness. A motion
interpolator driving an EtherCAT or CANopen head-end is picoBEAM doing
message-routed concurrency under a hard cycle deadline, which is precisely what
it is.

## The shape

```
  softbrain (host BEAM / Nerves)          picoBEAM (FPGA)              fieldbus
  ------------------------------          ---------------              --------
  kinematics, path planning,   setpoint   N axis processes,   frames   drives
  blending, task logic         tuples     one per axis,       at exact
  SOFT timing              ──USB/Eth──▶   interpolating     ──cycle──▶ CiA 402 /
                                          + a supervisor       tick     EtherCAT
                                          + a head-end port             slaves
```

**The interpolator is the boundary between soft timing and hard timing.** That
is what an interpolator has always been for, and it is why this maps well:
setpoints may arrive whenever, as long as they arrive *ahead* of the window they
apply to. Only the egress — cycle tick → frame on wire — needs a bound. Ingress
jitter is absorbed by the setpoint buffer, the same trick as the SDRAM
hibernation tier in `03-architecture.md`: work with no observable deadline is
allowed to be slow.

## Why it fits where FOC did not

| | FOC current loop | Motion interpolator |
|---|---|---|
| Cycle rate | 20–100 kHz | 1–4 kHz (EtherCAT), 100–1000 Hz (CAN) |
| Parallelism | one sequential loop per motor | **N independent axes** |
| Dominant cost | arithmetic | message routing + timing |
| Barrel divisor T | hurts (it is the loop) | irrelevant (axes run concurrently) |
| What determinism buys | torque ripple | **inter-axis sync + a safety number** |

The barrel's weakness is single-process latency. Here every axis is its own
process on its own context, so eight axes interpolate *concurrently* and the
wall-clock is one axis's time, not eight.

## The budget

Cubic Hermite interpolation per axis per tick, with state update: ~30
instructions inlined, ~80 naive (tuple churn, see the FOC analysis). At
80 ns/instruction (T = 4, 50 MHz):

| | per axis per tick |
|---|---|
| inlined | 2.4 µs |
| naive v1 compiler | 6.4 µs |

Tick-to-wire chain, bounded end to end:

```
cycle tick delivered (ring)              ~13 cy    260 ns
all N axis processes get a slot          ≤ T cy    ~80 ns .. 1 µs
interpolate (concurrent across axes)               2.4–6.4 µs
gather N results into the frame builder            2–3 µs
head-end hands bytes to the MAC                    fabric
                                                   ----------
                                          total    ~10 µs, jitter ~0
```

**~1% of a 1 ms EtherCAT cycle, ~4% of a 250 µs cycle.** The compute is not the
constraint and will not become one.

## The bus is the bottleneck, not picoBEAM

This reframes the whole exercise.

**Classical CAN @ 1 Mbit:** a standard-ID 8-byte data frame is ~130 µs with
stuffing. N axes × one RPDO per cycle at 60% bus load gives roughly **4–5 axes
at a 1 ms cycle, 9 axes at 2 ms.** EHDL's existing CAN stack appears to be
classical CAN only — `lib/hw/std/can/crc15.ex` is the CAN 2.0 CRC; CAN FD needs
CRC17/CRC21. *(Inferred from the file name — verify before planning around it.)*

**EtherCAT @ 100 Mbit:** one frame carries all axes. 80 axes × 8 bytes of PDO is
640 bytes ≈ 55 µs on the wire — 22% of a 250 µs cycle. EtherCAT is where the
context count actually gets spent.

So picoBEAM has enormous headroom relative to either bus, which means **the
interesting engineering is timing and supervision, not throughput.** Say that
out loud rather than benchmarking interpolation math nobody is waiting on.

## Where the argument actually wins: jitter

An EtherCAT master's frame emission timing sets the Distributed Clocks SYNC0
alignment. Software masters on Linux + PREEMPT_RT typically report cycle jitter
in the ±5–20 µs range under load, worse without RT — which is why dedicated
hardware masters exist. CANopen has the same problem in a different dress: SYNC
object jitter becomes inter-axis position error directly.

picoBEAM's cycle timer is a hardware counter and the frame assembly runs on a
guaranteed 1/T share. **Cycle-to-cycle jitter is not small, it is zero**, because
no scheduler makes a decision anywhere in the path. That is the thing a software
master cannot buy at any price.

## And the part that is genuinely novel

An axis process that faults — following error, encoder loss, drive NMT state
change, overtravel — raises a hardware-detectable event, which becomes an exit
signal, which reaches the supervisor in **links × ring diameter**. A bounded,
statable number from fault to safe-stop, rather than a distribution.

That is a functional-safety argument (IEC 61508 / ISO 13849 both want exactly
this number), and *"your motion interpolator is a supervised gen_server with a
10 µs bounded execution time and a nanosecond-bounded fault path"* is a product
position nobody currently occupies.

## Consequences for the rest of the design

1. **Board: CAN first on ULX3S, EtherCAT later elsewhere.** The ULX3S has no
   Ethernet, which blocks an EtherCAT head-end outright; CAN needs only a
   transceiver on GPIO, and EHDL already has `Hw.CAN.Controller`, `BitTiming`,
   `CRC15` and a `canopen_sync_bringup` design. EtherCAT argues for either an
   RMII PMOD or the Zynq-7020 target (which has GbE). **This is the strongest
   argument yet for keeping the fabric portable across targets.**

2. **Q2 is application-dependent, and this case inverts the FOC answer.** FOC
   argued for T = 4 because T divides single-process speed. Here per-axis
   latency is irrelevant against a 1 ms cycle, so **`:wide` (T = 8, 10 engines,
   80 contexts) is correct** — 80 supervised axes on one ECP5-85F, at
   12.8 µs/axis, still 1.3% of the cycle. T should therefore be a solver input
   driven by a declared latency budget, not a constant.

3. **Q8 gets a concrete requirement.** The head-end must be a port that accepts
   *terms* and does the byte packing in fabric, because v1 has no binaries and
   frame construction in Erlang is therefore impossible. This is the right
   design anyway, and it makes ports-as-processes look better still: a fieldbus
   head-end that owns a PID, that you `link` to, and that messages you when the
   cycle completes.

4. **New: fixnum overflow must trap, not wrap.** Position accumulators in
   encoder counts will approach 2^31 on a multi-turn axis with a high-resolution
   encoder. Erlang programmers expect integers to grow without bound; picoBEAM's
   32-bit fixnums will not. **Silent wraparound in a motion controller is a
   safety hazard.** Overflow must raise — it is already a hardware-detectable
   event per `03-architecture.md`, so make it an exit reason and let supervision
   handle it. Add to the ISA at M1.
