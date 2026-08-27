# M3 demo image: a root that spawns N workers; each worker emits the
# argument it was handed, then dies. Written as a hex file the
# testbench (and later the ROM/SD path) streams into CodeMem.
#
#   mix run scripts/mk_m3_image.exs

alias PicoBEAM.{Asm, Encoding}

n = 6

program = %{
  main:
    {0,
     [
       [{:ldi, 1, n}],
       [{:ldi, 3, 1}],
       [{:ldi, 5, 0}],
       :loop,
       [{:arg, 0, 1}],
       [{:spawn, 2, :worker, 1}],
       [{:sub, 1, 1, 3}],
       [{:cmpeq, 4, 1, 5}],
       [{:bift, 4, :done}],
       [{:jmp, :loop}],
       :done,
       [{:halt}]
     ]},
  worker:
    {1,
     [
       [{:out, 0}],
       :spin,
       [{:ldi, 2, 1}],
       [{:cmpeq, 3, 2, 2}],
       [{:jmp, :spin}]
     ]}
}

img = Encoding.image(Asm.assemble(program), :main)

File.mkdir_p!("_emit/m3")

lines = Enum.map(img.image, fn w ->
  w |> Integer.to_string(16) |> String.pad_leading(18, "0")
end)

File.write!("_emit/m3/demo_spawn.hex", Enum.join(lines, "\n") <> "\n")

IO.puts("bundles=#{length(img.image)} entry=#{img.entry} worker=#{img.bases.worker} n=#{n}")
IO.puts("__M3_IMAGE_DONE__")
