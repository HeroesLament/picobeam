# Where is bit 1 lost? Values with bit 1 set, made four different ways:
# from an ldi immediate, from the literal pool (ldc), by the ALU from
# immediates without bit 1, and copied register to register (mov).
# Expected out words come from the ISA model (PicoBEAM.Machine).
#
#   mix run scripts/mk_probe2.exs   -> _emit/sd/probe_alu.img
alias PicoBEAM.{Encoding, Machine}

hx = fn v, w -> v |> Integer.to_string(16) |> String.pad_leading(w, "0") |> String.downcase() end

bundles = [
  # 1: ALU makes bit 1 from immediates that lack it: 1 + 1
  [{:ldi, 0, 1}], [{:add, 1, 0, 0}], [{:out, 1}],
  # 2: immediate with bit 1
  [{:ldi, 2, 3}], [{:out, 2}],
  # 3: literal pool with bit 1
  [{:ldc, 3, 2}], [{:out, 3}],
  # 4: ALU: 4 - 1 = 3
  [{:ldi, 8, 4}], [{:ldi, 9, 1}], [{:sub, 10, 8, 9}], [{:out, 10}],
  # 5: ALU: 0x7FD | (1 + 1) = 0x7FF
  [{:ldi, 11, 0x7FD}], [{:bor, 14, 11, 1}], [{:out, 14}],
  # 6: register copy of a value with bit 1 (r2 = 3)
  [{:mov, 15, 2}], [{:out, 15}],
  [{:ret, 0}]
]

prog = PicoBEAM.Asm.assemble(%{main: {0, bundles}})
img = Encoding.image(prog, :main)

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <>
    (for w <- img.image, into: <<>>, do: <<w::72>>) <>
    (for w <- img.pool, into: <<>>, do: <<w::40>>)

File.write!("_emit/sd/probe_alu.img", body)
File.write!("_emit/xc7/imgs/probe_alu.hex", Enum.map_join(:binary.bin_to_list(body), "\n", &hx.(&1, 2)) <> "\n")

m = prog |> Machine.new() |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 100_000)
expect = Enum.map(m.out_raw, &("0x" <> hx.(Bitwise.band(&1, 0xFFFF), 4)))
IO.puts("probe_alu: #{byte_size(body)} bytes, pool #{length(img.pool)}, model #{inspect(status)}, expect #{Enum.join(expect, ",")}")
