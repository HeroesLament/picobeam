defmodule PicoBEAM.RTL.Classify do
  @moduledoc """
  M2 — per-slot opcode classification. One instance per bundle slot.

  Mirrors `PicoBEAM.Encoding`'s bit discipline (the ONE source of binary
  truth — change the table there, then here): op byte = `[group:4][sel:4]`,
  so almost everything below is a nibble slice or a single byte compare.

      grp 0 ALU (sel = Alu micro-op)   grp 3 control   grp 4+ system
      grp 1 load/stage                 grp 2 heap

  `rs_in_f1` marks the rs+imm12 shapes (`bift`/`biff`/`ret`/`out`/
  `recv_waitt`) whose source register rides the f1 (rd) field because
  imm12 covers f2..f4 — the engine muxes that slot's window read address
  from f1 when this is up. By the bundle contract these are system ops,
  at most one per bundle, so the mux is never contended.

  `wr_alu` covers only what the ALU datapath can produce today (ALU
  group + `ldi`/`ldn`); `ldc`/`lda`/`self` write rd too but their data
  comes from the pool/atom/pid paths — wired when those land, tracked
  as `wr_other`.

  M3 strobes (encoding deltas pass, 2026-08-23): `is_spawn`/`is_yield`/
  `is_self` classify the barrel's three ops. The opcodes were in
  `Encoding`'s table since M2 scaffolding — only the strobes are new.
  `spawn` is call-shaped (rd in f1, target in imm12, arity rides the
  staging frame); its rd write lands late through the engine's
  identity/alloc path at the spawn pass, NOT via `wr_alu`/`wr_other`.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :op, 8

  output :grp, 4
  output :alu_sel, 5
  output :wr_alu, 1
  output :wr_other, 1
  output :rs_in_f1, 1
  output :is_jmp, 1
  output :is_bift, 1
  output :is_biff, 1
  output :is_call, 1
  output :is_cfun, 1
  output :is_mseti, 1
  output :is_tail, 1
  output :is_ret, 1
  output :is_arg, 1
  output :is_halt, 1
  # `try`/`catch` (notes/32): `try_begin rd, handler` is a CALL that
  # does not change the pc — it spills the window into a frame and
  # marks that frame as catchable — and `try_end` is the pop that
  # throws the spill away when the protected expression survived.
  output :is_try, 1
  output :is_tend, 1
  output :is_sys, 1
  output :is_heap, 1
  output :is_ldc, 1
  output :is_out, 1
  output :is_fail, 1
  # supervision (notes/13): mechanism in gates, policy in code
  output :is_link, 1
  output :is_unlink, 1
  output :is_exit2, 1
  output :is_trapexit, 1
  output :is_monitor, 1
  # M3 barrel strobes
  output :is_spawn, 1
  output :is_yield, 1
  output :is_self, 1
  # M4
  output :is_send, 1
  # registered names (`notes/50`)
  output :is_regn, 1
  output :is_wher, 1
  output :is_unreg, 1
  output :is_rstart, 1
  output :is_rhash, 1
  output :is_rpeek, 1
  output :is_rskip, 1
  output :is_rtake, 1
  output :is_rwait, 1
  output :is_rwaitt, 1

  wire :is_ldi, 1
  wire :is_msr, 1
  wire :is_ldn, 1
  wire :is_lda, 1

  comb do
    grp = op[7..4]
    is_msr = op == 0x0C
    is_ldi = op == 0x10
    is_ldn = op == 0x11
    is_lda = op == 0x13
    is_heap = grp == 2
    is_ldc = op == 0x12
    is_out = op == 0x51
    # `fail rs, reason` — a deliberate exit with a reserved-atom reason
    # in imm12. Its whole implementation is a strobe into the die path
    # the ALU and the heap already use.
    is_fail = op == 0x50
    is_link = op == 0x4A
    is_unlink = op == 0x4B
    is_exit2 = op == 0x4D
    is_trapexit = op == 0x4E
    is_monitor = op == 0x4C

    # ALU micro-op: the low nibble for grp 0, the ldi/ldn extensions for
    # the two loads the ALU serves, pass-through (15) otherwise — never 0,
    # so a non-ALU slot cannot alias `add` and raise a phantom badarith.
    # The terms are one-hot, so the sum is a mux.
    # `mulsr` (0x0C) is in the ALU group but its low nibble, 12, already
    # names ldi's extension sel — the 4-bit sel space was full. So sel is
    # 5 bits, mulsr is 16, and 0x0C is carved out of the group-0 term
    # rather than renumbering a table the ALU's testbench is written
    # against.
    alu_sel =
      band(band(grp == 0, bnot(is_msr)), 1) * op[3..0] + is_msr * 16 +
        is_ldi * 12 + is_ldn * 13 + is_lda * 14 +
        bnot(bor(grp == 0, bor(is_ldi, bor(is_ldn, is_lda)))) * 15

    wr_alu = bor(grp == 0, bor(is_ldi, bor(is_ldn, is_lda)))
    # ldc writes rd through the wb2 late path; self pends on M3 identity
    wr_other = bor(op == 0x12, op == 0x14)

    rs_in_f1 =
      bor(op == 0x35, bor(op == 0x36, bor(op == 0x3A, bor(op == 0x51, op == 0x49))))

    # tailcall reuses the window: to the SEQUENCER it is just a jump
    # (is_jmp covers it), but the WINDOW must still promote staging into
    # current — is_tail drives that strobe (no push, no spill, no wait)
    is_jmp = bor(op == 0x30, op == 0x39)
    is_bift = op == 0x35
    is_biff = op == 0x36
    is_call = op == 0x38
    # `callfun` (`notes/42`) — a call whose target is not in the bundle.
    # It parks like a call and commits like a call; what differs is where
    # `tgt` comes from, and that is the engine's business, not this
    # table's.
    is_cfun = op == 0x3B

    # `mseti ri` (`notes/42`) — latch the index the next `mset` writes at.
    # A map's fill loop computes its index, and a heap op has only two
    # register reads: the map and the value. So the index arrives in a
    # separate, PURE op, and what it latches is an integer — which is why
    # it is safe across a collection in a way a latched POINTER would not
    # be.
    is_mseti = op == 0x17
    is_tail = op == 0x39
    is_ret = op == 0x3A
    is_arg = op == 0x16
    is_halt = op == 0x52
    is_try = op == 0x53
    is_tend = op == 0x54
    is_sys = op[6]
    # 0x58..0x5F: `spawn` with the arity in the opcode's low three bits
    is_spawn = op[7..3] == 11
    is_yield = op == 0x4F
    is_self = op == 0x14
    is_send = op == 0x41
    is_regn = op == 0x55
    is_wher = op == 0x56
    is_unreg = op == 0x57
    is_rstart = op == 0x43
    is_rhash = op == 0x44
    is_rpeek = op == 0x45
    is_rskip = op == 0x46
    is_rtake = op == 0x47
    is_rwait = op == 0x48
    is_rwaitt = op == 0x49
  end
end
