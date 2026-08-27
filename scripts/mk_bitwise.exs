# The four ALU micro-ops no program had ever run, plus `yield` and
# `unlink` (`notes/23`, `notes/27`, `notes/48`).
#
#   mix run scripts/mk_bitwise.exs -> _emit/m3/bitwise{,_expect}.hex
#
# `bor`, `bxor` and `cmple` have been unit-tested in `tb_alu_signed`
# against the model since M2 and had never been through the ENGINE:
# `PicoBEAM.Erl` does not emit them and no hand-written image used one.
# `yield` and `unlink` were wired into `BarrelEngine` and never
# exercised anywhere. Three notes in a row listed them as the cheapest
# thing on the board; this is that hour.

alias PicoBEAM.{Asm, Encoding, Machine}

program =
  Asm.assemble(%{
    main:
      {0,
       [
         [{:ldi, 1, 12}],
         [{:ldi, 2, 10}],
         [{:band, 3, 1, 2}],
         [{:out, 3}],
         [{:bor, 4, 1, 2}],
         [{:out, 4}],
         [{:bxor, 5, 1, 2}],
         [{:out, 5}],
         # both directions, because `cmple` is the one comparison whose
         # false case is a different opcode's true case
         [{:cmple, 6, 2, 1}],
         [{:out, 6}],
         [{:cmple, 7, 1, 2}],
         [{:out, 7}],
         # give up the rest of the turn on purpose. With one process the
         # only observable is that execution continues afterwards, which
         # is exactly the assertion that has been missing.
         [{:yield}],
         [{:ldi, 8, 99}],
         [{:out, 8}],
         # link then unlink: the child outlives neither, and the point
         # is that the second op runs and the parent does not die when
         # the child exits
         [{:spawn, 9, :child, 0}],
         [{:link, 9}],
         [{:unlink, 9}],
         [{:ldi, 10, 7}],
         [{:out, 10}],
         [{:ret, 10}]
       ]},
    child: {0, [[{:ldi, 0, 1}], [{:ret, 0}]]}
  })

img = Encoding.image(program, :main)
m = program |> Machine.new() |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 100_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/bitwise.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/bitwise_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("deaths = #{inspect(Machine.deaths(m))}")
IO.puts("__BITWISE_DONE__")
