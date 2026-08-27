# Cross-engine spawn: one image, two engines, one ring.
#
#   mix run scripts/mk_spawn2.exs   -> _emit/m3/spawn2{,_pool,_expect}.hex
#
# `tb_ring2` proved two engines can pass a MESSAGE. This is the program
# that proves they can hand each other WORK — the gap `notes/47` sized
# and `notes/49` closed.
#
# `main` spawns twice with one immediate argument each. Placement is
# round-robin from home (`notes/47`), so with the counter starting at
# zero the FIRST spawn stays on engine 0 and the SECOND crosses to
# engine 1. The argument is the parent's own pid, and the whole test
# hangs off it: an `echo` that did not receive its argument correctly
# has nobody to reply to, and the program never finishes.
#
# Everything engine 0 prints is deterministic because it prints in
# program order and the two children only speak when spoken to. Engine 1
# prints nothing at all — what proves it hosted a process is the ENGINE
# FIELD of the second pid, which engine 0 reports, and which could only
# be 1 if the child was created over there.

alias PicoBEAM.{Asm, Encoding, Machine}

prog = %{
  main:
    {0,
     [
       [{:self, 15}],
       # spawn 1 — round robin says HOME
       [{:arg, 0, 15}],
       [{:spawn, 1, :echo, 1}],
       # spawn 2 — round robin says the other engine
       [{:arg, 0, 15}],
       [{:spawn, 2, :echo, 1}],
       [{:out, 1}],
       [{:out, 2}],
       # a token each, one at a time, so the replies cannot race
       [{:ldi, 5, 11}],
       [{:send, 1, 5}],
       :w1,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 6, :w1}],
       [{:recv_take, 6}],
       [{:out, 6}],
       [{:ldi, 7, 22}],
       [{:send, 2, 7}],
       :w2,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 8, :w2}],
       [{:recv_take, 8}],
       [{:out, 8}],
       [{:ldi, 9, 42}],
       [{:out, 9}],
       [{:halt}]
     ]},
  echo:
    {1,
     [
       :loop,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 1, :loop}],
       [{:recv_take, 1}],
       [{:send, 0, 1}],
       [{:jmp, :loop}]
     ]}
}

asm = Asm.assemble(prog)
img = Encoding.image(asm, :main)

{status, m} =
  asm
  |> Machine.new(engines: 2)
  |> Machine.boot(:main)
  |> Machine.run(200_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end
File.mkdir_p!("_emit/m3")

File.write!("_emit/m3/spawn2.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!(
  "_emit/m3/spawn2_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n"
)

File.write!(
  "_emit/m3/spawn2_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n"
)

IO.puts("spawn2: #{length(img.image)} bundles")
IO.puts("model out: #{inspect(m.out)}")
IO.puts("model raw: #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("status=#{status} halted=#{m.halted} cycles=#{m.cycle}")
IO.puts("__SPAWN2_DONE__")
