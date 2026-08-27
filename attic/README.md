# attic — M2, kept and not deleted

Eight RTL modules and six scripts, 2,478 lines, that ran on silicon and
were then superseded module for module. `notes/23` counted them, so did
`notes/27`, and both ended the same way: *"Keeping them is defensible;
leaving the decision unmade is not."*

The decision is: keep them, out of the compile path.

| here | superseded by |
|---|---|
| `rtl/engine.ex` (730) | `RTL.BarrelEngine` |
| `rtl/reg_window.ex` (492) | `RTL.RegWindowCtx` |
| `rtl/sequencer.ex` (268) | `RTL.BarrelSeq` |
| `rtl/reg_window_ram.ex` (260) | `RTL.RegWindowCtx` |
| `rtl/reg_window_narrow.ex` (246) | `RTL.RegWindowCtx` |
| `rtl/ulx3s_top.ex` (236) | `RTL.Ulx3sM3Top` / `M4Top` / `M5Top` |
| `rtl/demo_fib.ex` (139) | `priv/demo/*.ex` through the real compiler |
| `rtl/frame_ram.ex` (107) | `RTL.FrameRamProc` |

Plus the scripts that only ever drove them — `emit_engine.exs`,
`emit_ulx3s.exs`, `probe_c.exs`, `probe_c.sh`, `build_ulx3s.sh`,
`calib_m2.sh` — and five later orphans that nothing references at all:
`emit_alu.exs` and `emit_m3_parts.exs`, which emitted subsets before
`emit_all.exs` existed, and `mk_probes.exs`, `probe_sdboot.exs` and
`sim_sdboot.exs`, the SD-boot bring-up probes that `tb_sdboot` replaced
when the card model landed (`notes/34`).

## Why kept

M2 is the sequential engine every M3 number was measured against.
`notes/15`'s calibration, `notes/18`'s benchmarks and the whole "barrel
multithreading is worth it" argument are comparisons to this code. A
benchmark whose baseline has been deleted is a number without a
denominator.

## Why out of the compile path

They were dragging every ratio in the repo. `mix test --cover` averages
in each `PicoBEAM.RTL.*` module at 0% — hardware descriptions are
exercised by iverilog, not ExUnit — and eight modules nothing runs made
the project look a third less tested than it is. Same for "RTL modules
exercised by the gate", which `notes/23` reported as 18 of 31 with eight
of the thirteen misses being these.

Nothing here is referenced by anything under `lib/`, `scripts/` or
`test/`. Moving them changed no netlist and no test.

## Bringing one back

`mv attic/rtl/<name>.ex lib/pico_beam/rtl/` and its script beside it.
They compiled on the day they were moved and the EHDL they use has not
changed since.
