# Probe C (M2) — price the clean-on-call register window unit.
#
# Emits Verilog for the two variants:
#
#   * PicoBEAM.RTL.RegWindow        — 6R3W + 3 arg ports (the LIW shape)
#   * PicoBEAM.RTL.RegWindowNarrow  — 2R1W + 1 arg port (sequential-slot)
#
# The synthesis run (yosys synth_ecp5, then nextpnr-ecp5 for fmax) is
# driven by scripts/probe_c.sh; this script only elaborates and emits.
#
#   mix run scripts/probe_c.exs

File.mkdir_p!("_emit/probe_c")

for {mod, name} <- [
      {PicoBEAM.RTL.RegWindow, "reg_window"},
      {PicoBEAM.RTL.RegWindowNarrow, "reg_window_narrow"},
      {PicoBEAM.RTL.RegWindowRam, "reg_window_ram"}
    ] do
  design = Hw.Compile.Elaborate.elaborate(mod)
  v = Hw.emit(design)
  File.write!("_emit/probe_c/#{name}.v", v)

  top =
    case Regex.run(~r/^module\s+(\w+)/m, v) do
      [_, t] -> t
      _ -> "UNKNOWN"
    end

  IO.puts("#{name}: top=#{top} bytes=#{byte_size(v)}")
end

IO.puts("__PROBE_C_EMIT_DONE__")
