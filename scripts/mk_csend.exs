# `send` of a COMPOUND term: the transmit half, end to end.
#
#   mix run scripts/mk_csend.exs   -> _emit/m3/csend{,_expect}.hex
#
# Until now `send` enqueued the message WORD. For a tuple or a list
# that word is a pointer into the sender's heap, so what landed in the
# receiver's mailbox was an address, not a message — working only
# because there is one heap and every process on the engine shares it
# (`notes/26` bug 1). `SerUnit` is now wired in: a compound send parks,
# the term is walked, and it goes into the mailbox as a flit stream
# that `DeserUnit` rebuilds on the receiving side.
#
# The process sends to ITSELF, which is not a simplification that
# weakens the test — the message still goes out as flits and comes
# back rebuilt at a DIFFERENT heap address, which is the whole point.
# It just removes spawn and scheduling from the picture so a failure
# here means the transmit path.
#
# What the outputs prove, in order:
#   * the sender's own pointer, before the send
#   * the REBUILT pointer, which must differ — a fresh allocation
#   * every element read back through it, including a nested list
#   * the arity, so a truncated stream cannot pass
#
# Every one of those is compared word-for-word against the model,
# pointers included, which `notes/26` bug 5 made possible this morning.

alias PicoBEAM.{Asm, Encoding, Machine}

program = %{
  main:
    {0,
     [
       [{:self, 0}],
       [{:ldi, 1, 7}],
       [{:ldi, 2, 8}],
       [{:ldi, 3, 9}],
       # a nested list [8|9] so the walk has to descend
       [{:cons, 10, 2, 3}],
       [{:mktup, 4, 3}],
       [{:tset, 4, 0, 1}],
       [{:tset, 4, 1, 10}],
       [{:tset, 4, 2, 3}],
       # the pointer the SENDER holds
       [{:out, 4}],
       [{:send, 0, 4}],
       [{:recv_start}],
       :scan,
       [{:recv_peek, 5, :none}],
       # the pointer the RECEIVER holds: a different cell, same shape
       [{:out, 5}],
       [{:recv_take, 5}],
       [{:tget, 6, 5, 0}],
       [{:out, 6}],
       [{:tget, 7, 5, 2}],
       [{:out, 7}],
       # the nested cell, walked back out
       [{:tget, 8, 5, 1}],
       [{:hd, 11, 8}],
       [{:out, 11}],
       [{:tl, 12, 8}],
       [{:out, 12}],
       [{:tarity, 9, 5}],
       [{:out, 9}],
       [{:halt}],
       :none,
       [{:fail, :badarg}]
     ]}
}

asm = Asm.assemble(program)
m = asm |> Machine.new(heap_words: 256) |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

img = Encoding.image(asm, :main)
File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/csend.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/csend_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("status=#{status} bundles=#{length(img.image)}")
IO.puts("model outs  = #{inspect(m.out)}")
IO.puts("model words = #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("__CSEND_DONE__")
