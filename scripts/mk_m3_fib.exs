# The M2 fib program, unchanged, plus a spawn wrapper: the root spawns
# TWO fib workers with different arguments, so the barrel runs two
# independent recursions concurrently through one pipeline.
alias PicoBEAM.{Asm, Encoding}

program = %{
  main:
    {0,
     [
       [{:ldi, 1, 10}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :fibp, 1}],
       [{:ldi, 1, 7}],
       [{:arg, 0, 1}],
       [{:spawn, 3, :fibp, 1}],
       # `ret`, not `halt` — see `mk_m3_spawn8`. `halt` stops the VM
       # since `notes/33`, and the root spawning two workers and then
       # halting would freeze both before either recursed.
       [{:ret, 1}]
     ]},
  fibp:
    {1,
     [
       [{:arg, 0, 0}],
       [{:call, 1, :fib, 1}],
       [{:out, 1}],
       [{:ret, 1}]
     ]},
  fib:
    {1,
     [
       [{:ldi, 1, 2}, {:ldi, 3, 1}],
       [{:cmplt, 2, 0, 1}],
       [{:bift, 2, :base}],
       [{:sub, 4, 0, 3}],
       [{:arg, 0, 4}],
       [{:call, 5, :fib, 1}],
       [{:sub, 7, 0, 1}],
       [{:arg, 0, 7}],
       [{:call, 8, :fib, 1}],
       [{:add, 9, 5, 8}],
       [{:ret, 9}],
       :base,
       [{:ret, 0}]
     ]}
}

img = Encoding.image(Asm.assemble(program), :main)
File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/fib_spawn.hex",
  Enum.join(Enum.map(img.image, fn w ->
    w |> Integer.to_string(16) |> String.pad_leading(18, "0")
  end), "\n") <> "\n")
IO.puts("bundles=#{length(img.image)} entry=#{img.entry} fibp=#{img.bases.fibp} fib=#{img.bases.fib}")
