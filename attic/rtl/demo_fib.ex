defmodule PicoBEAM.RTL.DemoFib do
  @moduledoc """
  M2 demo top — `fib(10)` on the engine, image-loading path included.

  The toolchain eats its own output at Elixir compile time: the program
  below goes through `Asm.assemble/1` (contract checks, label
  resolution) and `Encoding.image/2` (binary bundles, flattened, entry
  first) into a module attribute, which lands in a top-level ROM. A
  boot FSM then streams that ROM through the Engine's loader side-door
  into CodeMem while the engine sits in reset, and releases it when the
  last word has landed — the M2 miniature of `notes/11`'s boot design,
  where the SD loader replaces the ROM but the side-door stays.

  The program exercises the whole sequential machine: register windows
  (real recursion, depth 10), call/ret with link bookkeeping, arg
  staging, the lowered branch idiom (`cmplt` + `bift` — the two-reg
  branch decision from `notes/15` in the flesh), and `out` as the
  witness: fib(10) = 55 lands on `led` (0b0011_0111), `done` goes high
  on `halt`, `bad` on any fault.

  NOT simulated — the EHDL simulator cannot execute MemWrite
  (`../ehdl/AGENTS.md`), and this top is memories all the way down.
  Synthesis-shaped only; the sim gap is now M2's verification blocker
  and is logged in `notes/15`.
  """

  use Hw.Component

  @program %{
    main:
      {0,
       [
         [{:ldi, 0, 10}],
         [{:arg, 0, 0}],
         [{:call, 1, :fib, 1}],
         [{:out, 1}],
         [{:halt}]
       ]},
    fib:
      {1,
       [
         [{:ldi, 1, 2}, {:ldi, 3, 1}],
         [{:cmplt, 2, 0, 1}],
         [{:bift, 2, :base}],
         [{:sub, 4, 0, 3}],
         [{:arg, 0, 4}],
         [{:call, 5, :fib, 1}],
         [{:sub, 7, 0, 1}],
         [{:arg, 0, 7}],
         [{:call, 8, :fib, 1}],
         [{:add, 9, 5, 8}],
         [{:ret, 9}],
         :base,
         [{:ret, 0}]
       ]}
  }

  @img PicoBEAM.Encoding.image(PicoBEAM.Asm.assemble(@program), :main)
  if length(@img.image) > 32, do: raise("demo image exceeds the 32-bundle ROM")
  @image_words @img.image ++ List.duplicate(0, 32 - length(@img.image))

  clock :clk, freq: 50.0

  input :rst_in, 1

  output :led, 8
  output :running, 1
  output :done, 1
  output :bad, 1

  memory :rom, width: 72, depth: 32, sync_read: :clk, init: @image_words

  wire :ld_i, 5, init: 0
  wire :ld_i_d, 5, init: 0
  wire :ld_en_d, 1, init: 0
  wire :loading, 1, init: 1
  wire :ld_addr9, 9
  wire :rom_q, 72
  wire :eng_rst, 1
  wire :eng_out_v, 1
  wire :eng_out, 36
  wire :eng_halt, 1
  wire :eng_fault, 1
  wire :eng_fr, 8
  wire :eng_pc, 9
  wire :led_r, 8, init: 0

  comb do
    rom_q = rom[ld_i]
    ld_addr9 = ld_i_d
    # hold the engine until the last delayed write has landed
    eng_rst = bor(rst_in, bor(loading, ld_en_d))
    led = led_r
    done = eng_halt
    bad = eng_fault
    running = bnot(bor(loading, bor(eng_halt, eng_fault)))
  end

  on :clk do
    # one-cycle delay pair: ROM reads are sync, so the write trails the
    # index — the same discipline as the engine's ret-fill path
    ld_en_d = loading
    ld_i_d = ld_i

    if rst_in == 1 do
      ld_i = 0
      loading = 1
      led_r = 0
    else
      if loading == 1 do
        if ld_i == 31 do
          loading = 0
        else
          ld_i = ld_i + 1
        end
      end

      if eng_out_v == 1 do
        led_r = eng_out[7..0]
      end
    end
  end

  instance :engine, PicoBEAM.RTL.Engine,
    clk: :clk,
    rst: :eng_rst,
    ld_code_en: :ld_en_d,
    ld_code_addr: :ld_addr9,
    ld_code_data: :rom_q,
    ld_pool_en: 0,
    ld_pool_addr: 0,
    ld_pool_data: 0,
    out_valid: :eng_out_v,
    out_data: :eng_out,
    halted: :eng_halt,
    faulted: :eng_fault,
    fault_reason: :eng_fr,
    pc_dbg: :eng_pc
end
