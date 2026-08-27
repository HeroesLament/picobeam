# Bisection probe: emit SdBoot standalone (its own :clk port, no PLL).
File.mkdir_p!("_emit/probe_sd")
design = Hw.Compile.Elaborate.elaborate(PicoBEAM.RTL.SdBoot)
v = Hw.emit(design)
File.write!("_emit/probe_sd/sd_boot.v", v)
IO.puts("bytes: #{byte_size(v)}")
IO.puts("__SD_EMIT_DONE__")
