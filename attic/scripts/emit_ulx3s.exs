# Elaborate the ULX3S board top and emit its Verilog.
#
#   mix run scripts/emit_ulx3s.exs

File.mkdir_p!("_emit/ulx3s")

design = Hw.Compile.Elaborate.elaborate(PicoBEAM.RTL.Ulx3sTop)
v = Hw.emit(design)
File.write!("_emit/ulx3s/ulx3s_top.v", v)

mods = Regex.scan(~r/^module\s+(\w+)/m, v) |> Enum.map(fn [_, m] -> m end)
IO.puts("modules: #{Enum.join(mods, ",")} bytes: #{byte_size(v)}")
IO.puts("__ULX3S_EMIT_DONE__")
