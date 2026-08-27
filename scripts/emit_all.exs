# Emit every standalone RTL part into _emit/all — the regression gate's
# input. One flat directory so a testbench can name whatever it needs.
File.mkdir_p!("_emit/all")

mods = [
  {PicoBEAM.RTL.Alu, "alu"},
  {PicoBEAM.RTL.Classify, "classify"},
  {PicoBEAM.RTL.Decode, "decode"},
  {PicoBEAM.RTL.CodeMem, "code_mem"},
  {PicoBEAM.RTL.ProcTable, "proc_table"},
  {PicoBEAM.RTL.RunQueue, "run_queue"},
  {PicoBEAM.RTL.BarrelSeq, "barrel_seq"},
  {PicoBEAM.RTL.RegWindowCtx, "reg_window_ctx"},
  {PicoBEAM.RTL.FrameRamProc, "frame_ram_proc"},
  {PicoBEAM.RTL.SeatUnit, "seat_unit"},
  {PicoBEAM.RTL.Heap, "heap"},
  {PicoBEAM.RTL.SerUnit, "ser_unit"},
  {PicoBEAM.RTL.DeserUnit, "deser_unit"},
  {PicoBEAM.RTL.SignalTable, "signal_table"},
  {PicoBEAM.RTL.Timer, "timer"},
  {PicoBEAM.RTL.LitPool, "lit_pool"},
  {PicoBEAM.RTL.ShapeHash, "shape_hash"},
  {PicoBEAM.RTL.Mailbox, "mailbox"},
  {PicoBEAM.RTL.SendUnit, "send_unit"},
  {PicoBEAM.RTL.BarrelEngine, "barrel_engine"},
  {PicoBEAM.RTL.DbgUart, "dbg_uart"},
  {PicoBEAM.RTL.Collector, "collector"},
  {PicoBEAM.RTL.RootWalker, "root_walker"},
  {PicoBEAM.RTL.RingLink, "ring_link"},
  # notes/53 — the node registry stands alone now
  {PicoBEAM.RTL.NameTable, "name_table"},
  # two engines with `N_ENG: 2` folded in — the only way to get a
  # multi-engine configuration into a testbench (`notes/49`)
  {PicoBEAM.RTL.Duo, "duo"},
  # `notes/26` bug 9 — 525 lines and no testbench. It has one now.
  {PicoBEAM.RTL.ImageParser, "image_parser"},
  {PicoBEAM.RTL.UartRx, "uart_rx"},
  {PicoBEAM.RTL.UartLoader, "uart_loader"},
  {PicoBEAM.RTL.SdBoot, "sd_boot"},
  {PicoBEAM.RTL.SdBootSim, "sd_boot_sim"}
]

for {mod, name} <- mods do
  v = mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()
  File.write!("_emit/all/#{name}.v", v)
end

IO.puts("__EMIT_ALL_DONE__ (#{length(mods)})")
