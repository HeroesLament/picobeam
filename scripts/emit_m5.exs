# Elaborate the two-engine design — the board top for the bitstream, the
# core-with-a-fast-card for iverilog.
#
#   mix run scripts/emit_m5.exs

File.mkdir_p!("_emit/ulx3s")

for {mod, name} <- [
      {PicoBEAM.RTL.Ulx3sM5Top, "ulx3s_m5_top"},
      {PicoBEAM.RTL.M5CoreSim, "m5_core_sim"}
    ] do
  v = mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()
  File.write!("_emit/ulx3s/#{name}.v", v)
  # the regression gate names its inputs out of one flat directory
  File.mkdir_p!("_emit/all")
  File.write!("_emit/all/#{name}.v", v)
  mods = Regex.scan(~r/^module\s+(\w+)/m, v) |> Enum.map(fn [_, m] -> m end)
  IO.puts("#{name}: modules=#{Enum.join(mods, ",")} bytes=#{byte_size(v)}")
end

IO.puts("__M5_EMIT_DONE__")
