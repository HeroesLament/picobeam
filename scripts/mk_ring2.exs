# Two engines, one ring, one message across it.
#
#   mix run scripts/mk_ring2.exs   -> _emit/m3/ring2{a,b}{,_expect}.hex
#
# The first program on picoBEAM whose correctness depends on there
# being MORE THAN ONE engine. `notes/12`: an engine is a node, not a
# scheduler thread — private heap, copied messages, the ring as the
# distribution channel — and this is the first time any of that is
# load-bearing rather than architectural intent.
#
# Engine 0 builds `{7, [8|9], 9}` on ITS heap and sends it to a process
# on engine 1. What arrives has to be a copy on engine 1's heap: there
# is no shared memory for it to be anything else, and until `notes/22`'s
# postscript what would have crossed was the sender's heap ADDRESS,
# which is exactly the memory corruption `notes/26` bug 1 predicted for
# the moment a second engine existed.
#
# The peer's PID is a literal, loaded through the pool. Cross-engine
# SPAWN is a later increment — placement is round-robin in the model and
# the ring has to carry a spawn request for it — so for bring-up both
# engines are booted directly and engine 0 names its peer by
# construction: boot puts the root process in slot 0 with serial 1, so
# the pid is {engine 1, slot 0, serial 1}. That is a shortcut in the
# TEST, not in the machine: the pid is checked at the far end against
# engine 1's own proc table exactly as any other would be.

alias PicoBEAM.{Asm, Encoding, Term}

peer = Term.pid(1, 0, 1)

# --- engine 0: build a compound term and send it away
prog_a = %{
  main:
    {0,
     [
       [{:ldi, 1, 7}],
       [{:ldi, 2, 8}],
       [{:ldi, 3, 9}],
       [{:cons, 10, 2, 3}],
       [{:mktup, 4, 3}],
       [{:tset, 4, 0, 1}],
       [{:tset, 4, 1, 10}],
       [{:tset, 4, 2, 3}],
       # what the SENDER holds, on engine 0's heap
       [{:out, 4}],
       [{:ldc, 5, peer}],
       [{:send, 5, 4}],
       [{:ldi, 6, 1}],
       [{:out, 6}],
       # NOT a halt. `notes/33` made `halt` stop the VM rather than the
       # process, and the VM is both engines — so an engine 0 that
       # halted here would freeze engine 1 before the message it just
       # sent had even landed. It blocks instead, and engine 1's halt at
       # the end of ITS program is what stops the machine.
       #
       # Which makes this testbench's terminating condition — five
       # outputs from engine 1 AND engine 0 idle — evidence in its own
       # right: engine 0 is idle because a halt crossed the sideband,
       # and there is nothing else that could have unblocked it.
       [{:recv_start}],
       [{:recv_wait}]
     ]}
}

# --- engine 1: receive it and read it back
prog_b = %{
  main:
    {0,
     [
       [{:recv_start}],
       :scan,
       [{:recv_peek, 1, :none}],
       [{:recv_take, 1}],
       [{:tget, 2, 1, 0}],
       [{:out, 2}],
       [{:tget, 3, 1, 2}],
       [{:out, 3}],
       [{:tget, 4, 1, 1}],
       [{:hd, 5, 4}],
       [{:out, 5}],
       [{:tl, 6, 4}],
       [{:out, 6}],
       [{:tarity, 7, 1}],
       [{:out, 7}],
       [{:halt}],
       :none,
       [{:jmp, :scan}]
     ]}
}

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end
File.mkdir_p!("_emit/m3")

# The model runs both engines in one machine, which is the point: its
# `wire/4` already carries a copied term with `@wire_base + hops + flits`
# of latency, so the expectations below are the two-engine semantics the
# RTL has to reproduce, not a single-engine approximation of them.
asm_a = Asm.assemble(prog_a)
asm_b = Asm.assemble(prog_b)

for {name, asm} <- [{"ring2a", asm_a}, {"ring2b", asm_b}] do
  img = Encoding.image(asm, :main)

  File.write!("_emit/m3/#{name}.hex",
    Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

  File.write!("_emit/m3/#{name}_pool.hex",
    (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

  IO.puts("#{name}: #{length(img.image)} bundles pool=#{inspect(Enum.map(img.pool, &hx.(&1, 9)))}")
end

# Engine 1 reports CONTENTS, not the pointer. Its heap starts empty, so
# where the rebuilt term lands says nothing interesting; that the term
# is there, with the right elements and arity, is the property. The
# testbench asserts separately that engine 1's allocation pointer moved
# — that is the evidence a copy was made rather than an address
# forwarded, and it is the assertion `notes/26` bug 1 was really about.
File.write!("_emit/m3/ring2b_expect.hex",
  Enum.map_join([7, 9, 8, 9, 3], "\n", &hx.(Term.int(&1), 9)) <> "\n")

# Engine 0 reports its own pointer and a completion marker.
File.write!("_emit/m3/ring2a_expect.hex",
  Enum.map_join([Term.tuple(2), Term.int(1)], "\n", &hx.(&1, 9)) <> "\n")

IO.puts("peer pid = #{hx.(peer, 9)}")
IO.puts("__RING2_DONE__")
