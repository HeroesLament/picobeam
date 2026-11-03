# Compile and link a session of shell inputs against the pb_shell boot
# image, with no board: what `FabFarm.PbShell` does before it writes.
#
#   mix run scripts/shell_check.exs
#
# Prints one line per input: what it became and how many hot-load writes,
# or the error the shell would show.

alias PicoBEAM.{Ex, Encoding, Link, ShellLine}

img = Encoding.image(Ex.compile_file("priv/demo/pb_shell.ex"), :"main/0")
tramp = Map.fetch!(img.bases, :"line/1")

inputs = [
  "1 + 2",
  "x = 6 * 7",
  "y = {x, :hello, [1, 2, 3]}",
  "elem(y, 0) + x",
  "[h | t] = [10, 20, 30]",
  "self()",
  ~S"""
  defmodule Counter do
    def start(n), do: spawn(Counter, :loop, [n])
    def loop(n) do
      receive do
        {:inc, k} -> Counter.loop(n + k)
        {:get, p} -> send(p, {:count, n}); Counter.loop(n)
      end
    end
  end
  """,
  "c = Counter.start(5)",
  "send(c, {:inc, 10})",
  "send(c, {:get, self()}); receive do {:count, n} -> n end",
  ~S"""
  defmodule Counter do
    def start(n), do: spawn(Counter, :loop, [n])
    def loop(n) do
      receive do
        {:inc, k} -> Counter.loop(n + 2 * k)
        {:get, p} -> send(p, {:count, n, :v2}); Counter.loop(n)
      end
    end
  end
  """,
  "send(c, {:get, self()}); receive do {:count, n, v} -> {n, v} end",
  "f = fn a -> a * x end",
  "f.(2)",
  "Enum.map([1, 2], fn a -> a end)",
  "lists_rev = :lists.reverse([1, 2, 3])"
]

Enum.reduce(inputs, {Link.from_image(img), [], 1}, fn input, {st, names, n} ->
  label = input |> String.split("\n") |> hd() |> String.slice(0, 50)

  try do
    case ShellLine.build(input, names, n) do
      {:module, src} ->
        [unit] = Ex.compile_modules(src)
        {st, writes, info} = Link.link_module(st, unit)
        IO.puts("ok   #{label}  ->  module v#{info.version}, #{length(writes)} writes, #{Link.free(st)} free")
        {st, names, n + 1}

      {:expr, src, _mod, names2} ->
        [unit] = Ex.compile_modules(src)
        {st, writes, entry} = Link.link_line(st, unit, tramp)
        IO.puts("ok   #{label}  ->  line @#{entry}, #{length(writes)} writes, binds #{inspect(names2)}")
        {st, names2, n + 1}
    end
  rescue
    e ->
      IO.puts("ERR  #{label}  ->  #{e.__struct__ |> inspect()}: #{Exception.message(e) |> String.slice(0, 160)}")
      {st, names, n + 1}
  end
end)

IO.puts("__SHELL_CHECK_DONE__")
