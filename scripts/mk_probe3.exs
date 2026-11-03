# Is the lost bit one code-memory lane, or the ldi decode?
#   probe_slots: ldi in slot 0, 1 and 2 of a bundle (immediates land in
#                different code-memory bits; slot 0 only => one lane)
#   probe_eng1:  walk1 run on engine 1 (its own code memory and decoder)
#
#   mix run scripts/mk_probe3.exs
alias PicoBEAM.{Encoding, Machine}

hx = fn v, w -> v |> Integer.to_string(16) |> String.pad_leading(w, "0") |> String.downcase() end

write = fn name, bundles, e0_main? ->
  prog = PicoBEAM.Asm.assemble(%{main: {0, bundles}})
  img = Encoding.image(prog, :main)
  {e0, e1} = if e0_main?, do: {img.entry, 0x1FF}, else: {0x1FF, img.entry}

  body =
    <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little, e0::16-little,
      e1::16-little>> <>
      (for w <- img.image, into: <<>>, do: <<w::72>>) <>
      (for w <- img.pool, into: <<>>, do: <<w::40>>)

  File.write!("_emit/sd/probe_#{name}.img", body)
  File.write!("_emit/xc7/imgs/probe_#{name}.hex", Enum.map_join(:binary.bin_to_list(body), "\n", &hx.(&1, 2)) <> "\n")
  m = prog |> Machine.new() |> Machine.boot(:main, [])
  {status, m} = Machine.run(m, 100_000)
  expect = Enum.map(m.out_raw, &("0x" <> hx.(Bitwise.band(&1, 0xFFFF), 3)))
  IO.puts("probe_#{name}: #{byte_size(body)} bytes, model #{inspect(status)}, expect #{Enum.join(expect, ",")}")
end

vals = [2, 3, 0xAB, 0x7FF]

slot_bundles =
  for(v <- vals, do: [[{:ldi, 0, v}], [{:out, 0}]]) ++
    for(v <- vals, do: [[{:nop}, {:ldi, 1, v}], [{:out, 1}]]) ++
    for(v <- vals, do: [[{:nop}, {:nop}, {:ldi, 2, v}], [{:out, 2}]])

write.("slots", Enum.concat(slot_bundles) ++ [[{:ret, 0}]], true)

walk = for(k <- 0..10, do: Bitwise.bsl(1, k)) ++ [0x7FF]
write.("eng1", Enum.flat_map(walk, fn v -> [[{:ldi, 0, v}], [{:out, 0}]] end) ++ [[{:ret, 0}]], false)
