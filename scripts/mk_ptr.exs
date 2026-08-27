# The oracle test: `out` a raw heap POINTER and compare it word-for-word
# against the model.
#
#   mix run scripts/mk_ptr.exs   -> _emit/m3/ptr{,_expect}.hex
#
# This program could not have existed before today. `machine.ex`
# addressed the heap in words and the RTL in cells, so a pointer's
# payload legitimately differed between the two and every heap
# testbench had to report only immediates that had come back OUT of
# the heap (see the header of `mk_heapprog.exs`, which says exactly
# that). That was `notes/26` bug 5, and it was not a wrong answer — it
# was a hole in the oracle, because every compound-term result on the
# gates was unverifiable.
#
# `Term.cons/1` and `Term.tuple/1` now carry the CELL index, and
# `alloc` rounds to whole cells. So the pointers below are assertions
# about the model AND about the hardware allocator's bump sequence:
# where each object lands, and how much a tuple of even arity wastes.
#
# The arity-2 tuple is the load-bearing case. It is three words —
# header plus two elements — so it occupies TWO cells and wastes the
# odd word. If the model did not round, every allocation after it
# would sit one word lower than the hardware's and the last pointer
# here would disagree.

alias PicoBEAM.{Asm, Encoding, Machine}

program = %{
  main:
    {0,
     [
       [{:ldi, 1, 1}],
       [{:ldi, 2, 2}],
       # a cons: 2 words = exactly one cell
       [{:cons, 3, 1, 2}],
       [{:out, 3}],
       # another: the bump moved by one cell
       [{:cons, 4, 1, 2}],
       [{:out, 4}],
       # arity 2: hdr + 2 elems = 3 words, rounds to 2 cells
       [{:mktup, 5, 2}],
       [{:tset, 5, 0, 1}],
       [{:tset, 5, 1, 2}],
       [{:out, 5}],
       # the cons that proves the rounding: if the odd word were not
       # wasted on both sides, this pointer would differ
       [{:cons, 6, 1, 2}],
       [{:out, 6}],
       # arity 3: hdr + 3 elems = 4 words = 2 cells exactly, no waste
       [{:mktup, 7, 3}],
       [{:tset, 7, 0, 1}],
       [{:tset, 7, 1, 2}],
       [{:tset, 7, 2, 1}],
       [{:out, 7}],
       [{:cons, 8, 1, 2}],
       [{:out, 8}],
       # and the contents still read back correctly through the pointers
       [{:tget, 9, 7, 1}],
       [{:out, 9}],
       [{:hd, 10, 8}],
       [{:out, 10}],
       [{:halt}]
     ]}
}

asm = Asm.assemble(program)
# the RTL semispace is 128 cells = 256 words; make the model agree so
# both allocators run out at the same allocation
m = asm |> Machine.new(heap_words: 256) |> Machine.boot(:main, [])
{status, m} = Machine.run(m, 200_000)

img = Encoding.image(asm, :main)
File.mkdir_p!("_emit/m3")

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/ptr.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

# The expectation is `out_raw` — the model's own 36-bit words, pointers
# included, with no re-encoding step in between to get wrong.
File.write!("_emit/m3/ptr_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("status=#{status} bundles=#{length(img.image)}")
IO.puts("model outs = #{inspect(m.out)}")
IO.puts("__PTR_DONE__")
