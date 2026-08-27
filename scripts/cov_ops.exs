import Bitwise
# Opcode coverage: which op bytes actually appear in every `.hex` image
# any testbench loads (`notes/23`, `notes/27`, `notes/45`).
#
#   mix run scripts/cov_ops.exs
#
# Run the gate first — this reads what is in `_emit/`, so it reports on
# the images that exist, not the images that could exist. The op-byte
# table is re-derived from `encoding.ex`'s source rather than exported,
# because the map is private and making it public to measure it would
# be the measurement changing the thing measured.
# fall back: read @op module attribute via the private map is not exported,
# so re-derive from the source table
src = File.read!("lib/pico_beam/encoding.ex")
pairs =
  Regex.scan(~r/^\s{4}(\w+):\s*0x([0-9A-Fa-f]{2}),?\s*$/m, src)
  |> Enum.map(fn [_, n, h] -> {String.to_atom(n), String.to_integer(h, 16)} end)
map = Map.new(pairs, fn {n, b} -> {b, n} end)

files = Path.wildcard("_emit/*/*.hex") |> Enum.reject(&String.contains?(&1, ["_expect", "_pool", "_bytes", "sdimg_pool", "vectors"]))

seen =
  Enum.reduce(files, MapSet.new(), fn f, acc ->
    File.read!(f)
    |> String.split("\n", trim: true)
    |> Enum.reduce(acc, fn line, acc ->
      line = String.trim(line)
      if String.length(line) == 18 do
        w = String.to_integer(line, 16)
        Enum.reduce(0..2, acc, fn i, acc ->
          slot = (w >>> (i * 24)) &&& 0xFFFFFF
          op = (slot >>> 16) &&& 0xFF
          if slot == 0, do: acc, else: MapSet.put(acc, op)
        end)
      else
        acc
      end
    end)
  end)

all = Map.keys(map) |> MapSet.new()
exec = MapSet.intersection(seen, all)
IO.puts("images scanned: #{length(files)}")
IO.puts("op bytes in the table: #{MapSet.size(all)}")
IO.puts("executed: #{MapSet.size(exec)}")
IO.puts("EXECUTED: " <> (exec |> Enum.map(&map[&1]) |> Enum.sort() |> Enum.join(" ")))
IO.puts("NOT EXECUTED: " <> (MapSet.difference(all, seen) |> Enum.map(&map[&1]) |> Enum.sort() |> Enum.join(" ")))
