# M3 pass 2 — elaborate + emit the barrel's standalone parts.
#
#   mix run scripts/emit_m3_parts.exs
#
# iverilog-first is the M3 discipline (notes/16): these netlists meet
# scripts/tb_m3_pass2.v under vvp BEFORE any engine integration.

File.mkdir_p!("_emit/m3")

for {mod, name} <- [
      {PicoBEAM.RTL.ProcTable, "proc_table"},
      {PicoBEAM.RTL.RunQueue, "run_queue"},
      {PicoBEAM.RTL.BarrelSeq, "barrel_seq"},
      {PicoBEAM.RTL.RegWindowCtx, "reg_window_ctx"},
      {PicoBEAM.RTL.FrameRamProc, "frame_ram_proc"},
      {PicoBEAM.RTL.SeatUnit, "seat_unit"},
      {PicoBEAM.RTL.BarrelEngine, "barrel_engine"}
    ] do
  design = Hw.Compile.Elaborate.elaborate(mod)
  v = Hw.emit(design)
  File.write!("_emit/m3/#{name}.v", v)
  IO.puts("#{name}: bytes=#{byte_size(v)}")
end

IO.puts("__M3_PARTS_EMIT_DONE__")
