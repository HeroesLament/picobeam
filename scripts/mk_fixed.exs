# The fixed-point demo: cubic Hermite interpolation, the kernel every
# motion axis in `notes/20` runs once per SYNC tick.
#
#   mix run scripts/mk_fixed.exs   -> _emit/m3/fixed.hex + fixed_expect.hex
#
# It exercises, in one program, everything the fixed-point pass added:
# signed `mul` (building constants larger than ldi's 12-bit immediate),
# `mulsr` at Q12 with both signs, signed add/sub crossing zero, and a
# call/ret with five staged arguments.
#
# The expected outputs are not hand-computed. The program is run on the
# reference model and ITS `out` values are written as the expectation,
# so the testbench compares gates against `machine.ex` rather than
# against my arithmetic.

alias PicoBEAM.{Asm, Encoding, Machine}

# p0 = 0, v0 = 8000, p1 = 40000, v1 = -4000, u stepping 0..4096 by 1024.
# ldi's immediate is a sign-extended 12 bits (-2048..2047), so the big
# constants are BUILT with `mul` — which is only possible at all as of
# this pass.
program = %{
  main:
    {0,
     [
       [{:ldi, 1, 2000}],
       [{:ldi, 2, 20}],
       [{:mul, 3, 1, 2}],           # p1 = 40000
       [{:ldi, 2, 4}],
       [{:mul, 4, 1, 2}],           # v0 = 8000
       [{:ldi, 2, -2}],
       [{:mul, 5, 1, 2}],           # v1 = -4000
       [{:ldi, 6, 0}],              # p0
       [{:ldi, 7, 0}],              # u
       [{:ldi, 8, 1024}],           # du (Q12: a quarter)
       [{:ldi, 9, 5}],              # ticks remaining
       [{:ldi, 10, 1}],
       [{:ldi, 11, 0}],
       :loop,
       [{:arg, 0, 6}],
       [{:arg, 1, 4}],
       [{:arg, 2, 3}],
       [{:arg, 3, 5}],
       [{:arg, 4, 7}],
       [{:call, 12, :hermite, 5}],
       [{:out, 12}],
       [{:add, 7, 7, 8}],
       [{:sub, 9, 9, 10}],
       [{:cmpeq, 13, 9, 11}],
       [{:bift, 13, :done}],
       [{:jmp, :loop}],
       :done,
       [{:halt}]
     ]},

  # hermite(p0, v0, p1, v1, u) in Q12, delta form:
  #   p = p0 + dp*(3u^2 - 2u^3) + v0*(u - 2u^2 + u^3) + v1*(u^3 - u^2)
  hermite:
    {5,
     [
       [{:mulsr, 5, 4, 4, 12}],     # u2
       [{:mulsr, 6, 5, 4, 12}],     # u3
       [{:add, 7, 5, 5}],           # hp = 3u2 - 2u3
       [{:add, 7, 7, 5}],
       [{:sub, 7, 7, 6}],
       [{:sub, 7, 7, 6}],
       [{:sub, 8, 4, 5}],           # h0 = u - 2u2 + u3
       [{:sub, 8, 8, 5}],
       [{:add, 8, 8, 6}],
       [{:sub, 9, 6, 5}],           # h1 = u3 - u2
       [{:sub, 10, 2, 0}],          # dp = p1 - p0
       [{:mulsr, 11, 10, 7, 12}],
       [{:add, 11, 11, 0}],
       [{:mulsr, 12, 1, 8, 12}],
       [{:add, 11, 11, 12}],
       [{:mulsr, 13, 3, 9, 12}],
       [{:add, 11, 11, 13}],
       [{:ret, 11}]
     ]}
}

asm = Asm.assemble(program)

# --- the model's answer, which becomes the expectation ---
m = asm |> Machine.new() |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)
outs = m.out

img = Encoding.image(asm, :main)
File.mkdir_p!("_emit/m3")

File.write!(
  "_emit/m3/fixed.hex",
  Enum.map_join(img.image, "\n", fn w ->
    w |> Integer.to_string(16) |> String.pad_leading(18, "0")
  end) <> "\n"
)

# expectations as 36-bit words, the same shape the engine's `out` port
# presents, so the testbench compares words and not decoded integers
File.write!(
  "_emit/m3/fixed_expect.hex",
  Enum.map_join(outs, "\n", fn v ->
    PicoBEAM.Term.int(v) |> Integer.to_string(16) |> String.pad_leading(9, "0")
  end) <> "\n"
)

IO.puts("status=#{status} bundles=#{length(img.image)} entry=#{img.entry}")
IO.puts("hermite base=#{img.bases.hermite}")
IO.puts("model outs = #{inspect(outs)}")
IO.puts("__FIXED_IMAGE_DONE__")
