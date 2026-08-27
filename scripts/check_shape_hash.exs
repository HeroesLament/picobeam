# The shape-hash tripwire (notes/17): Encoding and ShapeHash must agree
# on every shape the assembler can express, or `recv_hash` filters
# messages the mailbox stamped differently and selective receive
# silently never matches.
#
#   mix run scripts/check_shape_hash.exs

alias PicoBEAM.{Encoding, Term}

File.mkdir_p!("_emit/m4")

for {mod, name} <- [
      {PicoBEAM.RTL.ShapeHash, "shape_hash"},
      {PicoBEAM.RTL.Mailbox, "mailbox"},
      {PicoBEAM.RTL.SendUnit, "send_unit"},
      {PicoBEAM.RTL.ProcTable, "proc_table"}
    ] do
  design = Hw.Compile.Elaborate.elaborate(mod)
  File.write!("_emit/m4/#{name}.v", Hw.emit(design))
end

# --- 1. the packing is a function of the shape, and distinct where it must be
specs = [
  :other,
  :cons,
  {:atom, 0},
  {:atom, 1},
  {:atom, 7},
  {:atom, 9},
  {:tuple, 1, nil},
  {:tuple, 2, nil},
  {:tuple, 2, 3},
  {:tuple, 2, 11},
  {:tuple, 9, 4}
]

for s <- specs do
  h = Encoding.shape_hash(s)
  unless h in 0..255, do: raise("#{inspect(s)} hashed outside a byte: #{h}")
  unless h == Encoding.shape_hash(s), do: raise("#{inspect(s)} is not deterministic")
end

# atoms 1 and 9 collide by design (low 3 bits); atoms 0 and 1 must not
unless Encoding.shape_hash({:atom, 1}) == Encoding.shape_hash({:atom, 9}),
  do: raise("the documented atom collision is missing")

unless Encoding.shape_hash({:atom, 0}) != Encoding.shape_hash({:atom, 1}),
  do: raise("distinct low atom indices must not collide")

unless Encoding.shape_hash({:tuple, 2, 3}) != Encoding.shape_hash({:tuple, 3, 3}),
  do: raise("arity must discriminate")

unless Encoding.shape_hash({:atom, 0}) != Encoding.shape_hash(:cons),
  do: raise("kinds must discriminate")

# --- 2. word-level agreement with what the RTL will see
cases =
  [
    {Term.make(:int, 42), 0, nil},
    {Term.make(:nil, 0), 0, nil},
    {Term.make(:atom, 5), 0, nil},
    {Term.make(:atom, 13), 0, nil},
    {Term.make(:pid, 7), 0, nil},
    {Term.make(:cons, 100), 0, nil},
    {Term.make(:tuple, 200), 2, Term.make(:atom, 3)},
    {Term.make(:tuple, 200), 2, Term.make(:int, 3)},
    {Term.make(:tuple, 200), 9, Term.make(:atom, 4)}
  ]

vectors =
  for {w, ar, first} <- cases do
    h = Encoding.shape_hash_of_word(w, ar, first)
    {w, ar, first || 0, h}
  end

# hand the vectors to the Verilog testbench
File.write!(
  "_emit/m4/shape_vectors.hex",
  Enum.map_join(vectors, "\n", fn {w, ar, f, h} ->
    [w, ar, f, h]
    |> Enum.zip([9, 2, 9, 2])
    |> Enum.map_join(" ", fn {v, n} ->
      v |> Integer.to_string(16) |> String.pad_leading(n, "0")
    end)
  end) <> "\n"
)

IO.puts("specs=#{length(specs)} vectors=#{length(vectors)}")
IO.puts("sample: atom(5)=0x#{Integer.to_string(Encoding.shape_hash({:atom, 5}), 16)} " <>
        "tuple(2,atom3)=0x#{Integer.to_string(Encoding.shape_hash({:tuple, 2, 3}), 16)}")
IO.puts("__SHAPE_HASH_CHECK_OK__")
