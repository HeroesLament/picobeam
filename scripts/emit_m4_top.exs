File.mkdir_p!("_emit/m4top")
design = Hw.Compile.Elaborate.elaborate(PicoBEAM.RTL.Ulx3sM4Top)
File.write!("_emit/m4top/ulx3s_m4_top.v", Hw.emit(design))
IO.puts("__M4_TOP_EMIT_DONE__")
