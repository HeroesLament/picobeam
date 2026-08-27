# 20 — The Metronome as a picoBEAM program

What actually ships on the SD card if the E-Motion metronome runs on
picoBEAM instead of being hand-designed as RTL. Written as code first and
conclusions second, because the code turned out to be a better argument
than the argument was.

Every module below is in (or one named op away from) the **v1 subset** that
`lib/pico_beam/erl.ex` accepts. Elixir rather than Erlang throughout —
the front end eats Core Erlang, which Elixir emits too, as long as you
stay off maps, binaries, structs, protocols, closures, comprehensions and
`try`. What's on the card is one pre-linked `.pbi` (`notes/11`); the
supervision tree is not a hardware table, it is this code plus the header's
initial tree spec.

Target: the exmo MVP arm. **Six axes, three CAN buses, two drives per bus,
CiA 402 interpolated-position mode (7), 250 Hz SYNC.**

---

## The tree

```
                        stage-0 loader  (notes/11)
                                │  seeds from the .pbi header
                                ▼
                        metronome_root                    trap_exit
                        one_for_all, 3 in 10s
                                │
        ┌───────────────┬───────┴────────┬────────────────┐
        │               │                │                │
      guard           feed            bus_0            axis_sup
   cross-bus       host link        bus_1            one_for_one
   fault domain    occupancy        bus_2            10 in 1s
   + STO kick      underflow        (one per         │
        │          seq gaps          CAN bus)        │
        │               │                │      ┌────┴────┬────┬────┬────┬────┐
        │               │                │     ax0  ax1  ax2  ax3  ax4  ax5
        │               │                │      └──┬──┘   └──┬─┘   └──┬─┘
        │               │                │         │         │        │
        ▼               ▼                ▼      ──────────────────────────
   port :sto       port :feed       port :bus0..2   (each axis is bound to
   (STO line)      (USB or          (bit timing,     exactly one bus process:
                    AXI-DMA)         CRC15, SYNC,    axis = {bus, node_id})
                                     RPDO/TPDO,
                                     guard band)
```

Ports are the fabric blocks from `notes/10` — they own PIDs, they are sent
to and received from, they are `link`ed and `monitor`ed like anything else,
and a restart of one is a reset pulse plus a serial bump. Everything with a
deadline shorter than a bundle (~330 ns) lives inside them. Everything
between a bundle and a USB round trip is the Elixir below.

**13 processes.** Ten of them spend their lives blocked in `receive` and
therefore hold no seat. On a tick, six axes plus three buses wake — nine
runnable on T=4 seats, so two swap rounds. See "The fit" at the end.

---

## `Metronome.Axis` — the hot loop

One axis, one process, one job: turn a queue of segments into exactly one
setpoint per SYNC tick, and die loudly the moment it can't.

```elixir
defmodule Metronome.Axis do
  @moduledoc """
  State lives in the loop arguments. No process dictionary, no ETS, no
  map — 16 registers per function window is the budget and this fits it
  with three to spare.

  Fixed point: position and velocity are raw CiA 402 units (int32 counts,
  int32 counts/s), which is also exactly what a picoBEAM fixnum is — the
  term payload and the wire field are the same 32 bits, so nothing is
  ever scaled on the way out. The spline parameter `u` is Q12 (0..4096).
  """

  # ------------------------------------------------------------------
  # start / hold
  # ------------------------------------------------------------------

  def start(bus, node, home) do
    spawn(Metronome.Axis, :hold, [bus, node, home, 0])
  end

  # No trajectory yet. Keep emitting the standstill setpoint anyway:
  # silence on an ip-mode axis is a following error, not a pause.
  # `starved` counts consecutive dry ticks — saturating in spirit, and
  # the reason the axis eventually kills itself rather than drifting.
  def hold(bus, node, pos, starved) do
    receive do
      {:seg, p1, v1, n, du} ->
        run(bus, node, pos, 0, p1, v1, 0, du, n, [])

      {:tick, _seq} ->
        bus ! {:sp, node, pos, 0}
        if starved > 12 do
          # 12 ticks at 250 Hz = 48 ms, just inside the published 50 ms
          # hold. Past here the host is not late, it is gone.
          exit(self(), :starved)
        else
          hold(bus, node, pos, starved + 1)
        end

      {:stop, why} ->
        exit(self(), why)
    end
  end

  # ------------------------------------------------------------------
  # run: p0/v0 -> p1/v1, currently at spline parameter u, stepping du
  # per tick, n ticks total, q queued behind.
  # ------------------------------------------------------------------

  def run(bus, node, p0, v0, p1, v1, u, du, n, q) do
    receive do
      # A new segment from the feed. Never interrupts the one in flight —
      # it goes on the tail. This is the look-ahead ring, and it is a
      # cons list because that is what v1 has.
      {:seg, np, nv, nn, ndu} ->
        run(bus, node, p0, v0, p1, v1, u, du, n, push(q, {np, nv, nn, ndu}))

      {:tick, _seq} ->
        p = hermite(p0, v0, p1, v1, u)
        v = v0 + mulsr(v1 - v0, u, 12)
        bus ! {:sp, node, p, v}
        step(bus, node, p0, v0, p1, v1, u + du, du, n - 1, q)

      {:stop, why} ->
        exit(self(), why)
    end
  end

  # end of segment: take the next one, or fall back to hold
  defp step(bus, node, p0, v0, p1, v1, u, du, n, q) do
    if n > 0 do
      run(bus, node, p0, v0, p1, v1, u, du, n, q)
    else
      if q == [] do
        # We landed exactly on p1 and there is nothing behind it. This is
        # the underflow that `Segment.seq` exists to make visible.
        hold(bus, node, p1, 1)
      else
        {np, nv, nn, ndu} = hd(q)
        # C1 continuity for free: this segment's end is the next one's
        # start, so the spline is continuous in position and velocity
        # without the host sending either twice.
        run(bus, node, p1, v1, np, nv, 0, ndu, nn, tl(q))
      end
    end
  end

  # ------------------------------------------------------------------
  # cubic Hermite, delta form
  #
  #   p(u) = p0 + dp*(3u^2 - 2u^3) + m0*(u - 2u^2 + u^3)
  #             + m1*(u^3 - u^2)
  #
  # Delta form because absolute encoder counts near 2^31 times a Q12
  # basis function overflows a 32-bit fixnum instantly (notes/09, item 4).
  # dp is one segment's worth of travel — at 250 Hz and 1 m/s on a
  # 10 000 count/mm axis that is ~40 000 counts, so every product below
  # stays inside 2^30 with room.
  #
  # `mulsr(a, b, k)` is multiply-then-arithmetic-shift-right-by-k, ONE
  # op — see "The bill" below. The 64-bit intermediate never becomes a
  # term, so it cannot raise a spurious `overflow`; the final shifted
  # result can, and should.
  # ------------------------------------------------------------------

  defp hermite(p0, v0, p1, v1, u) do
    u2 = mulsr(u, u, 12)
    u3 = mulsr(u2, u, 12)
    hp = u2 + u2 + u2 - u3 - u3          # 3u^2 - 2u^3
    h0 = u - u2 - u2 + u3                # u - 2u^2 + u^3
    h1 = u3 - u2                         # u^3 - u^2
    p0 + mulsr(p1 - p0, hp, 12) + mulsr(v0, h0, 12) + mulsr(v1, h1, 12)
  end

  # v1 has no `++`. Fine: nine elements deep, hand-rolled, and the
  # look-ahead ring is bounded by the feed rather than by this.
  defp push([], x), do: [x]
  defp push([h | t], x), do: [h | push(t, x)]
end
```

Cost, hand-counted against the naive one-op-per-bundle codegen: **~28
bundles per axis per tick.** `notes/09` budgeted 30 inlined and 80 naive;
the delta form beats its own naive estimate because the fused shift keeps
the fixed point out of the term world.

---

## `Metronome.Bus` — the cyclic engine for one CAN bus

Owns a port, owns the guard band, owns two axes. This is where the
metronome's *"any bus losing its cyclic stream quick-stops every bus, in
one cycle, without asking the host"* actually lives.

```elixir
defmodule Metronome.Bus do
  def start(port, guard, node_a, node_b) do
    spawn(Metronome.Bus, :init, [port, guard, node_a, node_b])
  end

  def init(port, guard, node_a, node_b) do
    # subscribe to the port's tick event; the port is fabric and its
    # SYNC transmitter is a counter, so this tick has zero jitter by
    # construction and there is no "SYNC jitter budget" to write down.
    port ! {:subscribe, self()}
    ax_a = Metronome.Axis.start(self(), node_a, 0)
    ax_b = Metronome.Axis.start(self(), node_b, 0)
    link(ax_a)
    link(ax_b)
    cyclic(port, guard, ax_a, ax_b, 0, 0, 0)
  end

  # seq        — SYNC sequence number, from the port
  # got        — how many axis setpoints arrived for THIS tick (0..2)
  # late       — consecutive ticks where `got` was short at guard time
  def cyclic(port, guard, a, b, seq, got, late) do
    receive do
      {:tick, s} ->
        # fan out. Two sends, ~50 cycles; the tick is 48 000 cycles at
        # 12 MHz, so this is 0.1% of the period.
        a ! {:tick, s}
        b ! {:tick, s}
        cyclic(port, guard, a, b, s, 0, late)

      # An axis has produced its number. Hand it straight to the port,
      # which packs RPDO1 = controlword|pos|seq and RPDO2 = vel and
      # holds them until the guard band opens. Term -> bytes happens in
      # fabric, per notes/10 Q8: v1 has no binaries, so frame
      # construction in Erlang is not merely slow, it is impossible.
      {:sp, node, pos, vel} ->
        port ! {:rpdo, node, pos, vel, seq}
        cyclic(port, guard, a, b, seq, got + 1, late)

      # The port raises this at `next_sync - longest_acyclic - margin`.
      # 255 us at 500 kbit/s. Everything queued goes on the wire now;
      # anything not queued is missing for this cycle.
      {:guard, _s} ->
        if got == 2 do
          port ! {:flush, seq}
          cyclic(port, guard, a, b, seq, got, 0)
        else
          # One tick short is a hiccup. Two in a row is a stream that
          # has stopped, and the arm should not find that out slowly.
          if late >= 1 do
            guard ! {:bus_silent, self(), seq}
            exit(self(), :cyclic_underrun)
          else
            port ! {:hold, seq}
            cyclic(port, guard, a, b, seq, got, late + 1)
          end
        end

      # TPDO in: position/statusword back from a drive. Upstream is
      # reporting, not feedback (METRONOME.md), so it goes to the feed
      # and nothing here waits on it.
      {:tpdo, node, pos, status} ->
        guard ! {:fb, node, pos, status}
        cyclic(port, guard, a, b, seq, got, late)

      # The acyclic tunnel: SDO/LSS from the host, forwarded verbatim.
      # It cannot delay the cyclic stream because the PORT schedules it
      # into the gap after the guard band, in RTL, not here.
      {:sdo, req} ->
        port ! {:sdo, req}
        cyclic(port, guard, a, b, seq, got, late)
    end
  end
end
```

---

## `Metronome.Feed` — the host link

The half of METRONOME.md that is currently 428 lines of USB descriptor
readback. Here it is as a process.

```elixir
defmodule Metronome.Feed do
  @moduledoc """
  "The metronome holds 50 ms. The host must never be more than 25 ms from
  refilling it. Beyond that is a fault, not a glitch." — this module is
  that sentence.

  Occupancy and underflow are published state, not debug prints: they go
  out on every upstream report.
  """

  def start(port, axes) do
    spawn(Metronome.Feed, :init, [port, axes])
  end

  def init(port, axes) do
    port ! {:subscribe, self()}
    loop(port, axes, 0, 0, 0)
  end

  # want — the seq we expect next; occ — segments handed downstream and
  # not yet consumed; under — saturating underflow count.
  def loop(port, axes, want, occ, under) do
    receive do
      # One waypoint, six axes, from the host. 48 bytes of payload plus
      # header — one USB packet, which is the whole architecture in one
      # sentence: the host fills a pipe, it does not close a loop.
      {:window, seq, n, du, s0, s1, s2, s3, s4, s5} ->
        if seq == want do
          fan(axes, n, du, s0, s1, s2, s3, s4, s5)
          port ! {:ack, seq, occ + 1, under}
          loop(port, axes, seq + 1, occ + 1, under)
        else
          # A gap is visible AS A GAP rather than as a jump in position.
          # We do not paper over it and we do not accept the window: the
          # host must resend from `want`.
          port ! {:gap, want, seq, occ, under}
          loop(port, axes, want, occ, under + 1)
        end

      # An axis consumed a segment; occupancy drops. This is how the
      # published number stays true rather than estimated.
      {:consumed, _node} ->
        loop(port, axes, want, occ - 1, under)

      {:fb, node, pos, status} ->
        port ! {:report, node, pos, status, occ, under}
        loop(port, axes, want, occ, under)

      # No window inside a whole 25 ms half-depth. The host is late.
      # Note the receive timeout is a positive integer — v1 forbids
      # `after 0`, which is exactly right here anyway.
      after 25 ->
        port ! {:starving, want, occ, under}
        loop(port, axes, want, occ, under + 1)
    end
  end

  # `spawn` needs a literal function name and a syntactic arg list, so
  # nothing in v1 is generic over a list of children — see "The bill".
  # Fanning out to a fixed six is not a hardship; it is the same shape
  # the child specs take.
  defp fan(axes, n, du, s0, s1, s2, s3, s4, s5) do
    a0 = element(1, axes); a1 = element(2, axes); a2 = element(3, axes)
    a3 = element(4, axes); a4 = element(5, axes); a5 = element(6, axes)
    a0 ! seg(s0, n, du); a1 ! seg(s1, n, du); a2 ! seg(s2, n, du)
    a3 ! seg(s3, n, du); a4 ! seg(s4, n, du); a5 ! seg(s5, n, du)
    true
  end

  defp seg(s, n, du), do: {:seg, element(1, s), element(2, s), n, du}
end
```

`du` — the Q12 step per tick — is computed **by the host** and shipped in
the window. picoBEAM never divides, because v1 has no `div` and because
"the host is filling a pipe" means the host may as well fill it with
something already chewed.

---

## `Metronome.Guard` — the cross-bus fault domain

*"The fault domain is the arm, not the bus."* Fifty lines, per `notes/13`'s
mechanism/policy split — the detection is in gates, this is only the
policy.

```elixir
defmodule Metronome.Guard do
  def start(sto, b0, b1, b2) do
    spawn(Metronome.Guard, :init, [sto, b0, b1, b2])
  end

  def init(sto, b0, b1, b2) do
    process_flag(:trap_exit, true)
    link(b0); link(b1); link(b2)
    sto ! {:subscribe, self()}
    watch(sto, b0, b1, b2)
  end

  def watch(sto, b0, b1, b2) do
    receive do
      # Any bus losing its stream stops every bus, in one cycle, without
      # asking the host. Three sends and an STO kick; the sends are
      # bounded, so "time from detection to quick-stop" is a NUMBER —
      # which is the whole IEC 61508 argument in notes/09.
      {:bus_silent, who, seq} ->
        quickstop(sto, b0, b1, b2, :cyclic_underrun, who, seq)

      # A hardware-emitted death: overflow on a position accumulator, a
      # port raising its fault line, mailbox_full. All reserved atoms,
      # all allocation-free (notes/13), so this path works even when the
      # heap does not.
      {:EXIT, who, why} ->
        quickstop(sto, b0, b1, b2, why, who, 0)

      {:fb, _node, _pos, _status} ->
        watch(sto, b0, b1, b2)
    end
  end

  defp quickstop(sto, b0, b1, b2, why, who, seq) do
    sto ! {:drop, why}            # safety is a wire, not a message
    b0 ! {:stop, why}
    b1 ! {:stop, why}
    b2 ! {:stop, why}
    exit(self(), why)             # escalate: root decides what happens next
  end
end
```

Note what `sto ! {:drop, why}` is doing. The STO *line* is a wire — the
port drops it in fabric the cycle the message lands. This message is not
the safety function; it is the request. METRONOME.md's *"safety is a wire,
not a message"* survives intact, and the Erlang is only deciding *when*.

---

## `Metronome.Root` — the supervisor

```elixir
defmodule Metronome.Root do
  def start(p_bus0, p_bus1, p_bus2, p_feed, p_sto) do
    spawn(Metronome.Root, :init, [p_bus0, p_bus1, p_bus2, p_feed, p_sto])
  end

  def init(pb0, pb1, pb2, pfeed, psto) do
    process_flag(:trap_exit, true)
    boot(pb0, pb1, pb2, pfeed, psto, 0)
  end

  def boot(pb0, pb1, pb2, pfeed, psto, restarts) do
    b0 = Metronome.Bus.start(pb0, self(), 1, 2)
    b1 = Metronome.Bus.start(pb1, self(), 3, 4)
    b2 = Metronome.Bus.start(pb2, self(), 5, 6)
    g  = Metronome.Guard.start(psto, b0, b1, b2)
    f  = Metronome.Feed.start(pfeed, axes_of(b0, b1, b2))
    link(b0); link(b1); link(b2); link(g); link(f)
    sup(pb0, pb1, pb2, pfeed, psto, restarts)
  end

  # one_for_all: an arm whose bus process died has lost its trajectory
  # continuity anyway, so restarting one child in isolation would leave
  # five axes mid-spline and one at home. Restart the lot, from standstill.
  def sup(pb0, pb1, pb2, pfeed, psto, restarts) do
    receive do
      {:EXIT, _who, :normal} ->
        sup(pb0, pb1, pb2, pfeed, psto, restarts)

      {:EXIT, _who, why} ->
        if restarts >= 3 do
          # Give up. The level-0 fabric watchdog is the supervisor of
          # last resort and it will reload the image (notes/13).
          exit(self(), why)
        else
          boot(pb0, pb1, pb2, pfeed, psto, restarts + 1)
        end
    end
  end
end
```

**This supervisor is not generic and cannot be.** `spawn` compiles to an
opcode carrying a literal code address, so a child spec cannot be data that
names a function. What OTP does with `{M, F, A}` in a list, v1 does with a
literal call per child. It is fifty lines instead of fifty lines, and the
restart *policy* — intensity, period, strategy, escalation — is still
ordinary code, which was the point of `notes/13`'s split. What is lost is
`Supervisor` as a library; what is kept is supervision.

---

## What this program bills the machine

Writing it produced a sharper list than arguing about it did. In order of
how much they block:

**1. ~~`mul` returns zero.~~ DONE** — see `notes/21`. Asking the ALU
directly turned one bug into three: arithmetic ran through the tag,
comparisons were unsigned, and overflow wrapped silently. 12 MULT18X18D,
fmax 24.5 → 20.1 MHz, cycle counts unchanged.

**2. ~~`mulsr rd, ra, rb, k`~~ DONE** — op 0x0C, `k` in 1..16 biased by
one in f4, sharing `mul`'s datapath; reachable from Elixir as
`:erlang.mulsr(a, b, 12)`. This was the real ISA finding, and it was not
a convenience. The front end exposes `+ - * band bor bxor` and comparisons
and *nothing else* — no `div`, no `rem`, **no shifts at all**, even though
the ISA has `shl` and EHDL uses it. So today fixed-point arithmetic is not
merely awkward, it is inexpressible. Adding `bsr` would fix that badly:
`a * b` would produce a 32-bit fixnum that overflows before the shift ever
happens, so every Q12 product would raise `overflow` spuriously and the
only workaround would be pre-scaling away the precision you wanted. Fusing
them means **the 64-bit intermediate never becomes a term** — it lives
inside the DSP tile between the two halves of one instruction — so the
overflow check applies to the shifted result, which is the number the
program actually meant. Fixed point becomes safe by construction rather
than by convention. One opcode, one MULT18 pair, no new datapath.

**3. Heap, tuples, and the M4 serialiser.** `{:sp, node, pos, vel}` is an
arity-4 tuple. `has_wb2` is tied 0 and neither Heap nor LitPool is
instantiated in `barrel_engine.ex`. The serialiser is the last M4 item and
it is the one that makes a segment a message.

**4. Ports.** Zero built. `notes/10`'s `api` block, the CSR/handshake RTL
it emits, the ring endpoint that makes a block answer to a PID — all
designed, none implemented. The CAN controller that already transmits a
real CANopen SYNC lives in the **ehdl** repo with no binding to picoBEAM at
all. This is the largest chunk of work and the one with the most existing
material to build on.

**5. ~~Overflow must trap.~~ DONE** — `notes/09` consequence 4, open
since M1, closed. `INT_MAX + 1` was silently becoming `INT_MIN` with a
clean INT tag; position accumulators were the exact case it named.

**6. `receive ... after N`** with a positive integer — supported in the
model, needs the per-context timer on silicon (`notes/13` records the op as
TBD at M3; M3 shipped without it). `Feed`'s 25 ms deadline is the whole
look-ahead promise, so this is load-bearing, not decorative.

Two things that look like gaps and are not:

- **No registered names.** So PIDs are threaded down from the root at
  spawn, which is visible in every signature above. This is better than a
  name table: the tree's topology is in the tree's code.
- **No generic supervisor**, per above.

---

## The fit

Per tick, at 250 Hz — 48 000 cycles at the current cautious 12 MHz:

| | bundles | notes |
|---|---|---|
| 6 axes × hermite + send | ~170 | concurrent, B2 says ~1.02 cycles/bundle |
| 3 buses × fan-out + 2 RPDO + flush | ~60 | |
| feed, when a window arrives | ~40 | 1 tick in 1 at 250 Hz windows |
| **messaging** | — | 21 messages × ~26 cy = ~550 cy |
| **swap** (9 runnable on T=4) | — | ~2 rounds × ~132 cy = ~260 cy |
| | | **≈ 1 100 cycles ≈ 92 µs** |

**2.3% of the tick**, on first-silicon clocking. At the 27 MHz that already
closes, 41 µs. At 1 kHz the tick is 12 000 cycles and this is 9% — still
comfortable, and the ret-fill burst optimisation from `notes/18` (70% of
call-heavy code is the return path) is sitting unspent.

The interesting number is not the 2.3%. It is that **there is no
distribution behind it.** No scheduler decision occurs anywhere in the
path; the SYNC is a counter; the rotation is a counter; every cost above is
a fixed count of turns. The guard band stops being something you measure
and start being something you state.

One honest wrinkle: nine runnable processes on four seats means the axes
swap, and swapping is the one cost in this machine that is large
(~33 turns). T=8 removes it entirely — 9 processes, 8 seats, one swap —
and `notes/09` already argued `:wide` for exactly this application on
exactly these grounds. **T should be a solver input driven by a declared
latency budget, not a constant**, and this program is the first concrete
thing to declare one.

---

## What did not move

None of this touches METRONOME.md's boundary. Bit timing, CRC15, the SYNC
transmitter, the RPDO packer, the guard-band comparator and the STO line
are all still fabric, because their deadlines are shorter than a bundle.
Kinematics, IK, blending, path planning, `CartesianStream`, mastering
policy and everything with a name in it are all still host, because their
deadlines are longer than a USB round trip.

What changed is that the middle — the part METRONOME.md had to describe as
a fixed-function window format because there was nowhere else to put it —
is now ~400 lines of supervised Elixir that deploys by copying a file onto
an SD card, and the *"three logical channels"*, the *"published look-ahead
depth"*, the *"cross-bus fault domain"* and the *"acyclic tunnel"* stop
being RTL specifications and become process structure.

The split rule gains a tier:

> Shorter than a bundle → fabric.
> Between a bundle and a USB round trip → **a process on picoBEAM.**
> Longer than a USB round trip → the host.
