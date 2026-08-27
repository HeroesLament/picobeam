# The board tops, for the regression gate. `notes/15` set the rule that
# made M2 close on the first try — "simulate the top, not just the
# parts" — and then the top testbenches quietly stopped being run.
File.mkdir_p!("_emit/all")

for {mod, name} <- [
      {PicoBEAM.RTL.Ulx3sM3Top, "ulx3s_m3_top"},
      {PicoBEAM.RTL.Ulx3sM4Top, "ulx3s_m4_top"}
    ] do
  v = mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()
  File.write!("_emit/all/#{name}.v", v)
end

IO.puts("__EMIT_TOPS_DONE__")
