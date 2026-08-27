# `mk_ptr` proves the two allocators agree about WHERE an object lands.
# It proves it in semispace 0, which is the only semispace a program
# that never collects has ever been in.
#
#   mix run scripts/mk_ptrgc.exs   -> _emit/m3/ptrgc{,_expect}.hex
#
# This is the same assertion on the other side of a collection: keep one
# cons alive, allocate two hundred cells of garbage past it, and `out`
# the survivor's POINTER. After an odd number of collections the live
# data is in the far semispace, and the question is whether the model
# and the gates agree about what a pointer into it says.
#
# `notes/46` is the answer, and it is no.

alias PicoBEAM.{Asm, Encoding, Machine}

program = %{
  main:
    {0,
     [
       [{:ldi, 1, 1}],
       [{:ldi, 2, 2}],
       # the survivor — one cons, held in r3 for the whole run
       [{:cons, 3, 1, 2}],
       [{:out, 3}],
       # 200 cells of garbage. The semispace is 128 cells, so this
       # collects at least once and the survivor moves.
       [{:ldi, 5, 200}],
       # loop:
       [{:cons, 4, 1, 2}],
       [{:ldi, 6, 1}],
       [{:sub, 5, 5, 6}],
       [{:ldi, 7, 0}],
       [{:cmpne, 8, 5, 7}],
       [{:bift, 8, 5}],
       # ...and the same pointer again, from the far side
       [{:out, 3}],
       # its contents, so a pointer that is merely SELF-consistent is
       # not enough to pass: it has to still address the right cell
       [{:hd, 9, 3}],
       [{:out, 9}],
       [{:tl, 10, 3}],
       [{:out, 10}],
       [{:halt}]
     ]}
}

prog = Asm.assemble(program)
img = Encoding.image(prog, :main)

m = prog |> Machine.new(heap_words: 256) |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/ptrgc.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/ptrgc_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

gcs = length(Map.get(m.stats, :gc, []))
IO.puts("bundles=#{length(img.image)} status=#{status} collections=#{gcs}")
IO.puts("out      = #{inspect(m.out)}")
IO.puts("out_raw  = #{inspect(Enum.map(m.out_raw, &"0x#{hx.(&1, 9)}"))}")
IO.puts("__PTRGC_DONE__")
