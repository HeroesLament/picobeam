# M2 — elaborate the engine scaffold and emit its Verilog.
#
#   mix run scripts/emit_engine.exs
#
# A structure check, not a test: proves the component tree wires up and
# the emitter accepts it. Synthesis of the full engine belongs in the
# probe log workflow (notes/15) once the opcode table lands.

File.mkdir_p!("_emit/engine")

for {mod, name} <- [
      {PicoBEAM.RTL.Engine, "engine"},
      {PicoBEAM.RTL.DemoFib, "demo_fib"}
    ] do
  design = Hw.Compile.Elaborate.elaborate(mod)
  v = Hw.emit(design)
  File.write!("_emit/engine/#{name}.v", v)

  mods = Regex.scan(~r/^module\s+(\w+)/m, v) |> Enum.map(fn [_, m] -> m end)
  IO.puts("#{name}: modules=#{Enum.join(mods, ",")} bytes=#{byte_size(v)}")
end

IO.puts("__ENGINE_EMIT_DONE__")
