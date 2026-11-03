# Bit-lane probes for picoBEAM on silicon (fabfarm pb_fmax with PB_IMG).
#
#   mix run scripts/mk_probe.exs
#     -> _emit/sd/probe_{walk1,walk0,regs}.img and _emit/xc7/imgs/probe_*.hex
#
# Each program is a run of `ldi` / `out` pairs, so its expected out words
# are its literals, in order: a wrong bit in an out word names the bit lane,
# and the register it went through.
alias PicoBEAM.Encoding

hx = fn v, w -> v |> Integer.to_string(16) |> String.pad_leading(w, "0") |> String.downcase() end

programs = %{
  "walk1" => for(k <- 0..10, do: {0, Bitwise.bsl(1, k)}) ++ [{0, 0x7FF}],
  "walk0" => for(k <- 0..10, do: {0, Bitwise.bxor(0x7FF, Bitwise.bsl(1, k))}),
  "regs" => for(n <- 0..15, do: {n, 0xAB})
}

for {name, pairs} <- programs do
  bundles = Enum.flat_map(pairs, fn {r, v} -> [[{:ldi, r, v}], [{:out, r}]] end) ++ [[{:ret, 0}]]
  prog = PicoBEAM.Asm.assemble(%{main: {0, bundles}})
  img = Encoding.image(prog, :main)

  body =
    <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
      img.entry::16-little, 0x1FF::16-little>> <>
      (for w <- img.image, into: <<>>, do: <<w::72>>)

  File.write!("_emit/sd/probe_#{name}.img", body)
  File.write!("_emit/xc7/imgs/probe_#{name}.hex", Enum.map_join(:binary.bin_to_list(body), "\n", &hx.(&1, 2)) <> "\n")
  expect = Enum.map(pairs, fn {_, v} -> "0x" <> hx.(v, 3) end) |> Enum.join(",")
  IO.puts("probe_#{name}: #{byte_size(body)} bytes, expect #{expect}")
end
