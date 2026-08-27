# 41 — Stopping the world

`notes/40` designed the integration and built `RootWalker`. This is the
rest of it: the collector is in the engine, it runs when the heap fills,
and `tb_fixed:gcloop` — four hundred iterations through twelve
collections on a 128-cell semispace — matches the model's `out` stream
word for word on the netlist.

That test is the one `notes/40` said had to exist before any of this was
believed, and it exists for a specific reason: a program that survives
ONE collection proves the evacuation. A program that survives more
collections than its heap has cells proves the ROOTS were rewritten,
because the second collection has to walk what the first one moved.

## `heap_full` is a request now

`Heap` still raises `fault` with reason 6 when a bump would cross the
semispace. What changed is who listens:

```elixir
gc_hf_x = band(band(hp_f, hp_fr == 6), band(band(any_heap, x_en), bnot(dz_grant)))
gc_park = band(gc_hf_x, bnot(gc_tried))
hp_f_e  = band(hp_f, bnot(gc_park))
```

`hp_f_e` is what reaches `any_fault`. The first `heap_full` from a given
asker is swallowed and turns into a collection; the second, with
`gc_tried` still set, is a real death. That is exactly the shape of
`Machine.alloc/3` — collect, retry, throw `:heap_full` if it still does
not fit — and it is why both sides run out of memory on the same
allocation rather than merely on the same program.

`gc_tried` is cleared when the asker gets what it wanted, not when
anybody does:

```elixir
gc_clear =
  bor(band(bnot(gc_from_dz),
        band(band(any_heap, x_en),
          band(bnot(hp_full), x_seat == gc_ret_seat))),
    band(gc_from_dz, take_go))
```

Clearing it on any successful heap op would have been a livelock: three
other seats allocating happily would keep resetting the flag while the
one that cannot fit collected, failed, collected, failed.

## The park that repeats

`BarrelSeq` gained state 17 and it is the only park in the machine that
resumes at the SAME bundle rather than the next one. In each of the four
context blocks:

```elixir
if gc_park == 1 do
  cstate0 = 17
else
  <the whole existing X-stage decision>
end
```

and, beside the `kill_en` claim:

```elixir
if band(gc_resume, cstate0 == 17) == 1 do
  cstate0 = 1
end
```

`pc0` is never touched in either. That is the whole trick, and it is why
nothing about the allocation has to be latched and carried across the
pause: **nothing of it happened.** The store refuses the bump on
`heap_full`, so the bundle's only effect was the fault it no longer
raises. `notes/40` chose re-execution over latching operands precisely
so `extra_roots` — the model's "the allocation in flight is a root" —
would have no counterpart here to get wrong.

## Quiet, not merely frozen

`frozen = bor(vm_halt, gc_active)` was supposed to be the whole of "stop
the world". It is not, and the reason is not the one `notes/40`
anticipated.

`notes/40` knew that `frozen` stops FETCHING and that bundles at D and X
still retire, and prescribed a two-rotation drain. That much was right.
What it missed is that **`SerUnit` owns heap port B** — the collector's
port — and a serialisation in flight does not care that the barrel has
stopped:

```elixir
hpb_addr = hpb_space * 128 + ser_haddr[6..0]
```

So the condition is not a counter, it is quiescence:

```elixir
gc_quiet =
  band(bnot(ser_busy),
    band(bnot(dz_busy), band(bnot(mb_busy), band(sd_st == 0, drain_ready))))
```

Nothing serialising, nothing rebuilding, no mailbox scan, no signal
being emitted, no window drain in flight — AND eight cycles gone by. A
drain counter alone would have handed the heap to the collector while
somebody else was reading it, at a rate of about one program in twenty.

`hpb_space` is worth its own sentence. `SerUnit` addresses a cell within
the ACTIVE semispace, and the space bit is applied here. It has been
correct only because nothing had ever flipped; the first collection
would have sent every subsequent serialisation reading into the dead
half.

## The rebuild cannot park, so it is asked first

A message rebuild is the other allocator, and the context that wants it
is ALREADY parked waiting for the deserialiser. There is nowhere to park
it again. So the room is checked before the rebuild starts:

```elixir
dz_fits = bnot((hp_hp + dz_len) > 128)
deser_free = band(bnot(dz_busy), bor(dz_fits, gc_tried))
gc_req_dz = band(take_want, band(bnot(dz_busy), band(bnot(dz_fits), bnot(gc_tried))))
```

`take_claim` is an F-slot claim that repeats every rotation while the
context is in state 14, so withholding it costs nothing and needs no new
state: the context simply claims again after the collection.

The bound is sound rather than generous. A message of `n` flits rebuilds
into at most `n` cells, because every allocation the deserialiser makes
is triggered by consuming at least one flit — `WCONS` consumes one and
allocates one; `HDR|n` consumes `n + 1` and allocates `ceil((n+1)/2)`.

This also fixes something that was already broken. A rebuild that
overflowed the heap raised `hp_f`, and `any_fault` is consumed by
whichever context is at X that cycle — so a message too big for the heap
killed a **random process**. It was never reached because no test filled
a heap during a rebuild. It is unreachable now.

What is left is on the scoreboard as entry 16: if the live set exceeds
half the semispace and a long message arrives, the collection does not
free enough, and the receiver takes the old path. Fixing it properly
means giving an out-of-X death its own reason, which is a change to the
death path and not to the collector.

## What it costs

Measured on `gcloop`, one process, 128-cell semispace:

| | |
|---|---|
| collection every | ~6,400 cycles |
| pause | ~490 cycles |
| of which the root walk | ~450 |
| of which Cheney's scan | ~32 |
| live data | 6 cells |

Eight percent, and it is almost entirely the walk — which is what
`notes/28` predicted when it measured live data at 8 words and said "the
copy is nothing; the cost is entirely in walking the ROOTS".

The walk is two cycles per root plus a round trip per pointer, and it is
serial. The obvious next move is to pipeline it — present root `n+1`'s
address while root `n` is at the collector — which would roughly halve
the pause. It is not done, because a correct collector that pauses for
490 cycles is worth more than a fast one that has never run.

`notes/28`'s zero-cycle claim is now formally a divergence: the model
charges the mutator nothing for a collection, the machine charges it
about 490 cycles. It is a divergence in TIMING and not in RESULTS —
`gcloop` proves the `out` streams are identical — but a cycle count
taken from the model is no longer a prediction of the board for any
program that allocates.

## The bug this cost a morning to find

Two nets, silently merged, with no warning from anything.

`RootWalker` had an output port called `fr_depth`. `barrel_engine` had a
net called `fr_depth` — implicitly, from `depth_out: :fr_depth` on the
frame store's instance. When the walker was flattened in, EHDL merged
them, and the emitted Verilog had:

```verilog
assign rk_fr_depth = frames_fill_depth;   // the engine's own net
assign rk_fr_depth = _slice_27166;        // the walker's output
```

Two continuous drivers on one wire. Where they agreed, the wire was
fine; where they disagreed, one bit went `x` — and that `x` was
`frames`' write address, so every spill went nowhere and every process
read zeros out of its own frames. `tb_fixed` produced one `out` and
halted.

This is the third instance of the same family. `notes/34` had
`instance :sd` colliding with a wire called `sd_lrx`. `notes/36` had an
internal clock promoted to a port when a component was flattened. Now a
PORT NAME colliding with a net name in the parent. All three are the
same missing thing: EHDL's flattener does not namespace, and it does not
complain.

The check is one line and it is now in the toolbox rather than in
someone's head:

```elixir
ports_of(child) ∩ nets_of(parent) == ∅
```

`scripts/check_ports.exs` runs it over every instance in every
component. Where a name is deliberately shared — `rst`, `clk`,
`live_vec`, `seat_val`, all connected to themselves — the connection
says so, and the check only complains when a port name matches a net the
instance does NOT connect it to.

The renaming, in the end, was `fr_*` to `frm_*` on nine ports of one
module.

## What it fits in

Two engines, ECP5-85F, yosys `synth_ecp5`:

| | `notes/36`, collector unwired | wired |
|---|---|---|
| LUT4 | 38,516 | **49,150** |
| DP16KD | 114 | **114** |
| MULT18X18D | 24 | 28 |
| TRELLIS_FF | — | 10,051 |

**+27.6% LUT4 and not one more block RAM**, which was not true of the
first version and is the more interesting number.

The first version cost **32 extra EBRs** — 114 to 146 of the device's
208 — and every one of them was the frame store. `gc_q = frames[gc_addr]`
beside `fill_data = frames[...]` is a second read port on an 8192x36
memory, which is sixteen EBRs per engine, and it was written that way
out of habit while the two ports beside it (`RegWindowCtx`'s read 0,
`SeatUnit`'s save area) were deliberately MUXED for exactly this reason.

The barrel is frozen while the collector runs. The ret-fill port is
idle. One address mux later, 146 is 114 again, and 15% of the device's
memory is back for maps and closures to spend.

The lesson is small and it is about attention rather than technique:
the same trick had already been applied twice, in the same commit, by
the same person, and the third memory got a new port because it was
written on a different afternoon.

Fmax is not measured here — nextpnr is not in this container, and
`notes/36`'s 17.13 MHz was a place-and-route number. The critical path
was `core_eng0_lt_links` (22.19 ns logic, 33.08 ns routing) and the new
mux is on the register file's port 0, which is not on it; but that is a
prediction, not a measurement, until the board top is placed again.

## What is not done

* The pause is serial. Pipelining the walk — presenting root n+1's
  address while root n is at the collector — would roughly halve it.
* `notes/26` entry 16: a rebuild that still does not fit after a
  collection takes the pre-existing path.
* Place-and-route, and therefore Fmax, on the two-engine top.
