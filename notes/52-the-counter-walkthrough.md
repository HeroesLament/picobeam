# 52 — The counter walkthrough, and what it shook loose

Mac asked for the demo rehearsal: one ordinary Elixir app, traced from
source to silicon. `priv/demo/counter.ex` — a registered counter
server, the gen_server call shape, 53 lines — became the most
productive program this project has run: it found two latent RTL bugs
at the two-minute testbench level, exposed a state leak across image
pushes on the board, and cracked a foundational assumption open
(`notes/53`). This note records the pipeline and the two bugs; the
ledger carries them as entries 34 and 35.

## The pipeline, measured

    counter.ex        53 lines of Elixir, nothing FPGA-shaped in it
    Ex.compile_file   real elixirc -> Core Erlang -> bundles
    four functions    main/0 61 · incr/1 51 · get/0 49 · server/1 70
    the image         pBM2, 231 bundles, 2,091 bytes
    the model         out=[42], 1,325 cycles, deaths [:normal, :killed]
    the push          325 ms
    the board         OO=2a, XX=01, clean halt

The server loop's 70 bundles read like annotated assembly: peek, the
pattern tests, the tgets, take, add, mktup/tset, send, arg+tailcall.
Every receive-loop idea in BEAM is visible in five registers of window.

## Entry 34: the completion that ate writebacks

The w0 write port's priority chain assumes every late writer belongs
to a parked context whose X slot is free "by construction". True of
the ret-fill, the spawn-fill, the pid and dest writes — each paces
itself to its owner's turn. False of exactly one: the deserialiser's
`dz_done` fired the cycle a rebuild finished, on whatever seat's X
cycle that was, and a running context's ALU writeback silently lost
the port. In the counter, the eaten write was `lda r0, false` — the
peek-ok flag — so `incr`'s receive branched on stale truth, skipped a
message that did not exist, and spun. Fixed by making the claim true:
the completion latches and writes back on the OWNER's own X slot.

Latent since the rebuild-at-peek design. Every prior program either
parked its receivers (waking post-completion) or spun with patterns
that matched first try; the counter's fast ping-pong aligned the
pulses within a few thousand cycles, every run.

## Entry 35: the half-arrived message

A local compound send streams one flit per cycle and stamps the head
entry FIRST, so a polling receiver — no wake involved — could match a
message whose continuations had not landed and hand the deserialiser
a partial term. The ring ingress avoids exactly this by waking on the
last flit; a poller needs no wake. The mailbox scan now treats a head
whose `len` runs past the slot's tail as not-there-yet: no match, the
scan stops, and the cursor parks ON it so the next pass finds it
whole. Found while hunting entry 34; real on its own.

## The board's two answers

The first push after the fixed bitstream wedged with `XX=0a` and a
live process on ENGINE 1 — which is the tell. `sp_rr`, the spawn
round-robin counter, is not on the image-push reset path: the names
demo left it odd, so the counter's spawn placed the server on the
other engine, and `register/2` — node-local, as built — correctly
refused the "remote" pid. The second push (counter advanced back to
even) ran perfectly: 42 off the UART, `:killed` in the reason byte.

Two findings, filed forward: programs must not inherit scheduler
state from their predecessors (entry 36 — and the name CAM is the
same class of leak), and "correctly refused" is doing heavy lifting
in that sentence — whether an engine IS a node is `notes/53`, where
Mac answers it: no.
