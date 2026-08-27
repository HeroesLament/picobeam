# M3 encoding-deltas check — spawn / yield / self.
#
#   mix run scripts/check_m3_ops.exs
#
# Two proofs, cheap and load-bearing:
#
# 1. SEMANTICS: the reference model runs a spawn/yield/self program to
#    the expected out log — the spec the barrel RTL must meet at co-sim.
# 2. BITS: the assembled program round-trips through `Encoding.image/2`
#    and the three ops' slot words match hand-computed patterns, so the
#    RTL `Classify` strobes (0x40/0x4F/0x14) decode the same bytes the
#    encoder emits. The opcode table is the ONE source of truth; this
#    script is the tripwire on both its consumers.

alias PicoBEAM.{Asm, Encoding, Machine}

# main: records its own pid tag, spawns W workers (args staged like
# call), yields the seat around, halts. worker(n): outs n+100, dies.
w = 6

spawns =
  Enum.flat_map(0..(w - 1), fn i ->
    [
      [{:ldi, 1, i}],
      [{:arg, 0, 1}],
      [{:spawn, 2, :worker, 1}]
    ]
  end)

yields = List.duplicate([{:yield}], 40)

program = %{
  main:
    {0,
     [[{:self, 3}], [{:out, 3}]] ++
       spawns ++ yields ++ [[{:halt}]]},
  worker:
    {1,
     [
       [{:ldi, 1, 100}],
       [{:add, 2, 0, 1}],
       [{:out, 2}],
       [{:ret, 2}]
     ]}
}

assembled = Asm.assemble(program)

# --- 1. semantics on the model --------------------------------------------

m = assembled |> Machine.new(engines: 1, contexts: 4, budget: 16) |> Machine.boot(:main, [])
{:halted, m} = Machine.run(m, 200_000)

{pids, nums} = Enum.split_with(m.out, &match?({:pid, _, _, _}, &1))

unless length(pids) == 1, do: raise("expected exactly one self pid in out, got #{inspect(m.out)}")
unless Enum.sort(nums) == Enum.map(0..(w - 1), &(&1 + 100)),
  do: raise("worker outs wrong: #{inspect(Enum.sort(nums))}")

IO.puts("model: self=#{inspect(hd(pids))} workers=#{inspect(Enum.sort(nums))} — OK")

# --- 2. bits ---------------------------------------------------------------

import Bitwise

# hand-computed slot words (op<<16 | f1<<12 | fields)
expected = %{
  {:yield} => 0x4F0000,
  {:self, 3} => 0x143000
}

for {slot, want} <- expected do
  got = Encoding.encode_slot(slot)
  unless got == want,
    do: raise("#{inspect(slot)} encoded 0x#{Integer.to_string(got, 16)}, want 0x#{Integer.to_string(want, 16)}")
end

# spawn's target is patched to the callee's base address by image/2:
# worker's base = main's bundle count (entry first, then sorted names).
img = Encoding.image(assembled, :main)
worker_base = img.bases.worker
spawn_word = Encoding.encode_slot({:spawn, 2, worker_base, 1})
want = 0x40 <<< 16 ||| 2 <<< 12 ||| worker_base

unless spawn_word == want,
  do: raise("spawn encoded 0x#{Integer.to_string(spawn_word, 16)}, want 0x#{Integer.to_string(want, 16)}")

# and the patched word must actually APPEAR in the image (slot a of the
# spawn bundles): scan for it.
found =
  Enum.any?(img.image, fn b ->
    Enum.any?([b >>> 48, b >>> 24 &&& 0xFFFFFF, b &&& 0xFFFFFF], &(&1 == spawn_word))
  end)

unless found, do: raise("patched spawn word not found in image")

IO.puts("bits: yield=0x4F0000 self=0x143000 spawn=0x#{Integer.to_string(spawn_word, 16)} (worker@#{worker_base}) — OK")
IO.puts("__M3_OPS_CHECK_OK__")
