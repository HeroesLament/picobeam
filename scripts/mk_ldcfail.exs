# `ldc` and `fail`: the two ops that were in the ISA table, in the
# model, and nowhere in the gates.
#
#   mix run scripts/mk_ldcfail.exs  -> _emit/m3/ldcfail{,_expect,_pool}.hex
#
# `ldc` is the reason this program can say 40000 in one bundle. The
# Hermite demo in notes/21 spends three — `ldi 2000; ldi 20; mul` —
# because the 12-bit immediate reaches 2047 and nothing wider had a
# way to be written down.
#
# It ends with `fail`, so the expectation is a DEATH with a named
# reason as well as a list of outputs.

alias PicoBEAM.{Asm, Encoding, Machine, Term}

program = %{
  main:
    {0,
     [
       # constants no immediate can express, in one bundle each
       [{:ldc, 1, 40000}],
       [{:out, 1}],
       [{:ldc, 2, -70000}],
       [{:out, 2}],
       [{:ldc, 3, 2_147_483_647}],
       [{:out, 3}],
       [{:ldc, 4, -2_147_483_648}],
       [{:out, 4}],
       # the same value again: the pool interns, so this is index 0
       [{:ldc, 5, 40000}],
       [{:add, 6, 1, 5}],
       [{:out, 6}],
       # a pool entry used as an ordinary operand, through the wb2 turn
       [{:ldc, 7, 100_000}],
       [{:sub, 8, 7, 1}],
       [{:out, 8}],
       # and an exit the program asked for, by name
       [{:fail, :badarg}]
     ]}
}

asm = Asm.assemble(program)
m = asm |> Machine.new() |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

img = Encoding.image(asm, :main)
File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/ldcfail.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/ldcfail_pool.hex",
  Enum.map_join(img.pool, "\n", &hx.(&1, 9)) <> "\n")
File.write!("_emit/m3/ldcfail_expect.hex",
  Enum.map_join(m.out, "\n", &hx.(Term.int(&1), 9)) <> "\n")

reason = Machine.deaths(m) |> List.first() |> elem(1)
idx = Enum.find_index(Term.reserved_atoms(), &(&1 == reason))

IO.puts("status=#{status} bundles=#{length(img.image)} pool=#{inspect(img.pool)}")
IO.puts("model outs = #{inspect(m.out)}")
IO.puts("death reason = #{inspect(reason)} (reserved index #{idx})")
IO.puts("__LDCFAIL_DONE__")
