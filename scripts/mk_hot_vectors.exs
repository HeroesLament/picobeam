# The hot-load bench's inputs, made by the same compiler, linker and wire
# codec the shell uses (`PicoBEAM.Ex`, `Link`, `Wire`, `ShellLine`):
#
#   mix run scripts/mk_hot_vectors.exs [OUTDIR]
#
# writes OUTDIR/pb_shell_bytes.hex (the boot image, one byte a line, for
# `tb_xc7_m5 -DHOT +IMG=... +LEN=...`) and OUTDIR/hot_script.hex (one
# host op a line, 92 bits: op[91:88] arg[87:72] data[71:0]):
#
#   1 code write: arg = bundle address, data = the bundle
#   2 pool write: arg = pool index, data[35:0] = the word
#   3 push a head to the evaluator (the pid the hello named): arg = len
#   4 push a payload flit: data[35:0]
#   5 pop and expect a head for the host: arg = len, data[35:0] = pid
#   6 pop and expect a payload flit: data[35:0]
#   7 pop a payload flit and keep it as the evaluator's pid
#   0 end
#
# The session: boot pb_shell, take the hello, load `Adder` (add = a + b),
# run `x = Adder.add(40, 2)` (42) and `x + 1` (43, the binding kept on
# the machine), load `Adder` again with add = a - b and run
# `Adder.add(x, 2)` (40: the trampoline moved). The last line prints
# the expected values for the log.

alias PicoBEAM.{Ex, Encoding, Link, Wire, ShellLine}

out = List.first(System.argv()) || "_emit/sd"
File.mkdir_p!(out)

prog = Ex.compile_file("priv/demo/pb_shell.ex")
img = Encoding.image(prog, :"main/0")
tramp = Map.fetch!(img.bases, :"line/1")

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <>
    for(w <- img.image, into: <<>>, do: <<w::72>>) <>
    for(w <- img.pool, into: <<>>, do: <<w::40>>)

File.write!(Path.join(out, "pb_shell.img"), body)
File.write!(
  Path.join(out, "pb_shell_bytes.hex"),
  for(<<b <- body>>, into: "", do: Integer.to_string(b, 16) |> String.pad_leading(2, "0") |> Kernel.<>("\n"))
)

st = Link.from_image(img)
host = %Wire.Pid{engine: 15, slot: 1, serial: 7}

line = fn op, arg, data ->
  v = Bitwise.bsl(op, 88) + Bitwise.bsl(arg, 72) + data
  Integer.to_string(v, 16) |> String.pad_leading(23, "0")
end

writes_ops = fn writes ->
  Enum.map(writes, fn
    {:code, a, b} -> line.(1, a, b)
    {:pool, i, w} -> line.(2, i, w)
  end)
end

# hello: {:pb_shell, Evaluator}
{st, hello} = Wire.encode({:pb_shell, %Wire.Pid{engine: 0, slot: 0, serial: 0}}, st)
hello_ops = [line.(5, length(hello), Wire.Pid.word(%Wire.Pid{engine: 15, slot: 0, serial: 0}))] ++
  [line.(6, 0, Enum.at(hello, 0)), line.(7, 0, 0), line.(6, 0, Enum.at(hello, 2))]

load = fn st, src ->
  [unit] = Ex.compile_modules(src)
  {st, writes, _info} = Link.link_module(st, unit)
  {st, writes_ops.(writes)}
end

eval = fn st, input, names, n, want ->
  {:expr, src, mod, names2} = ShellLine.build(input, names, n)
  [unit] = Ex.compile_modules(src)
  ^mod = unit.module
  {st, writes, entry} = Link.link_line(st, unit, tramp)
  {st, msg} = Wire.encode({:eval, host, n}, st)
  {st, reply} = Wire.encode({:pb_ok, n, want}, st)

  ops =
    writes_ops.(writes) ++
      [line.(3, length(msg), 0)] ++
      Enum.map(msg, &line.(4, 0, &1)) ++
      [line.(5, length(reply), Wire.Pid.word(host))] ++
      Enum.map(reply, &line.(6, 0, &1))

  IO.puts("  #{input}  ->  #{inspect(want)}  (#{length(writes)} writes, entry #{entry})")
  {st, ops, names2}
end

{st, a1} = load.(st, "defmodule Adder do\n  def add(a, b), do: a + b\nend\n")
{st, e1, names} = eval.(st, "x = Adder.add(40, 2)", [], 1, 42)
{st, e2, names} = eval.(st, "x + 1", names, 2, 43)
{st, a2} = load.(st, "defmodule Adder do\n  def add(a, b), do: a - b\nend\n")
{_st, e3, _names} = eval.(st, "Adder.add(x, 2)", names, 3, 40)

ops = hello_ops ++ a1 ++ e1 ++ e2 ++ a2 ++ e3 ++ [line.(0, 0, 0)]
File.write!(Path.join(out, "hot_script.hex"), Enum.join(ops, "\n") <> "\n")

IO.puts(
  JSON.encode!(%{
    img: Path.expand(Path.join(out, "pb_shell_bytes.hex")),
    bytes: byte_size(body),
    bundles: length(img.image),
    line_tramp: tramp,
    ops: length(ops)
  })
)
