# The image tb_m3_pass8 runs: a root that spawns EIGHT workers, each of
# which emits the argument it was handed and then dies.
#
#   mix run scripts/mk_m3_spawn8.exs      -> _emit/m3/spawn8.hex
#
# Separate from `mk_m3_image.exs` on purpose. That script builds the
# BOARD demo — six workers that spin forever so the LEDs have something
# to show — and at some point it was edited into that shape while
# `_emit/m3/demo_spawn.hex` still held the eight-worker build the
# testbench was written against. The artifact outlived its generator,
# and the drift only surfaced when the regression gate regenerated
# everything from source. One script, one artifact, one testbench.

alias PicoBEAM.{Asm, Encoding}

n = 8

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
       # `ret`, not `halt`. `notes/33` made `halt` stop the VM, which is
       # what `erlang:halt/0` means — so a root that halted here would
       # freeze eight workers that had not run yet, and a worker that
       # halted would freeze its seven siblings. "This process is
       # finished" is `ret`, and since `notes/31` a top-level `ret`
       # exits with reason `normal`, which is exactly what this program
       # wants said eight times.
       [{:ret, 5}]
     ]},
  worker:
    {1,
     [
       [{:out, 0}],
       [{:ret, 0}]
     ]}
}

img = Encoding.image(Asm.assemble(program), :main)
File.mkdir_p!("_emit/m3")

lines = Enum.map(img.image, fn w ->
  w |> Integer.to_string(16) |> String.pad_leading(18, "0")
end)

File.write!("_emit/m3/spawn8.hex", Enum.join(lines, "\n") <> "\n")

IO.puts("bundles=#{length(img.image)} entry=#{img.entry} worker=#{img.bases.worker} n=#{n}")
IO.puts("__M3_SPAWN8_DONE__")
