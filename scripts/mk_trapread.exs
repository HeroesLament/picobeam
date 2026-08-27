# The other half of trap_exit: a supervisor that READS the exit signal.
#
#   mix run scripts/mk_trapread.exs
#
# `super_trap` proved a trapping process survives its linked child and
# is woken. It could not prove the message was legible, because
# `recv_take` returned one word — so the testbench had to assert the
# shape from OUTSIDE, by reading the mailbox entry's hash and length.
#
# With the deserialiser in the engine, `recv_take` rebuilds the whole
# term on the heap and hands back a pointer. This program takes that
# pointer apart: element 0 is the atom 'EXIT', element 2 is the reason
# the child died of, and the arity is 3. That is a supervisor reading
# its child's obituary, which is the entire point of notes/13.

alias PicoBEAM.{Asm, Encoding, Machine, Term}

program = %{
  main:
    {0,
     [
       [{:trapexit, 1}],
       [{:ldi, 1, 0}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :child, 1}],
       [{:link, 2}],
       [{:recv_start}],
       :again,
       [{:recv_wait}],
       [{:recv_peek, 5, :again}],
       [{:recv_take, 6}],
       # the rebuilt term, taken apart
       [{:tarity, 9, 6}],
       [{:out, 9}],
       [{:tget, 7, 6, 0}],
       [{:out, 7}],
       [{:tget, 8, 6, 2}],
       [{:out, 8}],
       [{:halt}]
     ]},
  child:
    {1,
     [
       [{:ldi, 1, 1}],
       [{:ldn, 2}],
       [{:add, 3, 1, 2}],
       [{:halt}]
     ]}
}

asm = Asm.assemble(program)
img = Encoding.image(asm, :main)
m = asm |> Machine.new() |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/trapread.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/trapread_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

# the model decodes `out` to Elixir terms; the gates present words, so
# the expectation is written in words
File.write!("_emit/m3/trapread_expect.hex",
  Enum.map_join(m.out, "\n", fn
    v when is_integer(v) -> hx.(Term.int(v), 9)
    v -> hx.(Term.atom(Enum.find_index(Term.reserved_atoms(), &(&1 == v))), 9)
  end) <> "\n")

IO.puts("status=#{status} bundles=#{length(img.image)}")
IO.puts("model outs = #{inspect(m.out)}")
IO.puts("__TRAPREAD_DONE__")
