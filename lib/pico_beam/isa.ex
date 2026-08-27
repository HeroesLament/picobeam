defmodule PicoBEAM.ISA do
  @moduledoc """
  The picoBEAM v1 instruction set — a 3-slot LIW, clean-on-call register
  machine (Q1 and Q4a decided 2026-08-22: ECOMP's shape, run in full).

  ## The bundle

  One bundle = up to three slots, issued together in one context turn of the
  barrel. Encoding budget (bit-level packing is an M2 concern; the assembler
  enforces these ranges NOW so nothing unencodable creeps into programs):

    * bundle = 72 bits = two 36-bit code words; 24 bits per slot
    * slot   = op:8 | three 4-bit register fields | imm as noted
    * registers r0..r15 — one WINDOW of the per-context register stack
    * LDI immediate: signed 12 bits; wider constants via LDC (literal pool)
    * branch offsets: 12 bits (function length < 2048 bundles)

  ## The bundle contract (hardware has no bypass network — these rules ARE
  the hardware's simplicity; the assembler rejects violations)

    1. All slots read PRE-bundle register state; writes commit together
       after the bundle. Therefore no slot may read a register any slot in
       the same bundle writes, and no two slots may write the same register.
    2. At most one HEAP op per bundle (one port-A access per turn).
    3. At most one SYSTEM op (control flow / comm / process ops) per bundle,
       and it must be the last occupied slot.
    4. Housekeeping (mailbox enqueue, exit-signal hops, timer wheel) is NOT
       in any slot — it runs in autonomous port-B FSMs (Q4b).

  ## Clean-on-call register windows

  `call` pushes a fresh window (a bump of the window base into the
  per-context register stack — allocation is a pointer bump here too) and
  clean-on-call means the callee simply owns r0..r15 with args in r0..N-1;
  nothing is saved or restored. Outgoing args are staged with `arg` slots
  (they write through to the NEXT window), so single assignment does the
  rest. `ret rs` copies the callee's rs into the caller's destination
  register recorded at the call, pops the window. Deep call chains
  spill/fill the register stack against frame RAM — the frame cache is
  M2's version of JOP's stack cache.

  Every op below is data (`:pure`), heap (`:heap`), or system (`:system`).
  """

  # op => {class, doc}
  @ops %{
    nop: {:pure, "no operation"},

    # -- data / registers ----------------------------------------------------
    ldi: {:pure, "ldi rd, imm — load small int (signed 12-bit)"},
    ldn: {:pure, "ldn rd — load nil"},
    ldc: {:pure, "ldc rd, const — load from literal pool (any term word)"},
    lda: {:pure, "lda rd, atom — load atom (assembler interns)"},
    mov: {:pure, "mov rd, rs"},
    self: {:pure, "self rd — own pid"},

    # -- fixnum arithmetic (tag-checked; overflow TRAPS, never wraps) --------
    add: {:pure, "add rd, ra, rb"},
    sub: {:pure, "sub rd, ra, rb"},
    mul: {:pure, "mul rd, ra, rb"},
    # multiply then arithmetic-shift-right, as ONE op. k is 1..16, and
    # the 64-bit intermediate never becomes a term — so the overflow
    # check applies to the shifted result and a Q12 product cannot trap
    # on a value the program never asked to see. Fixed point needs this;
    # `mul` + a separate shift cannot express it safely.
    mulsr: {:pure, "mulsr rd, ra, rb, k — (ra * rb) >> k, k in 1..16"},
    band: {:pure, "band rd, ra, rb"},
    bor: {:pure, "bor rd, ra, rb"},
    bxor: {:pure, "bxor rd, ra, rb"},

    # -- comparisons producing true/false atoms ------------------------------
    cmpeq: {:pure, "cmpeq rd, ra, rb — word equality (immediates/pids/refs)"},
    cmpne: {:pure, "cmpne rd, ra, rb — word inequality"},
    cmplt: {:pure, "cmplt rd, ra, rb — fixnum <"},
    cmple: {:pure, "cmple rd, ra, rb — fixnum =<"},
    istag: {:pure, "istag rd, rs, tag — type test, true/false"},

    # -- heap ----------------------------------------------------------------
    cons: {:heap, "cons rd, rh, rt — allocate 2-word cell (1 cycle, bump)"},
    hd: {:heap, "hd rd, rs"},
    tl: {:heap, "tl rd, rs"},
    mktup: {:heap, "mktup rd, arity — allocate header + arity words"},
    tset: {:heap, "tset rt, i, rs — fill freshly made tuple slot"},
    tget: {:heap, "tget rd, rt, i"},
    tarity: {:heap, "tarity rd, rt — arity of tuple as fixnum"},

    # -- calls / control (system) --------------------------------------------
    arg: {:pure, "arg i, rs — stage outgoing arg i (writes through to next window)"},
    call: {:system, "call rd, f, arity — push window, args r0..N-1, result to rd"},
    tailcall: {:system, "tailcall f, arity — reuse window"},
    ret: {:system, "ret rs — pop window, deliver rs to caller's dest"},
    jmp: {:system, "jmp label"},
    beq: {:system, "beq ra, rb, label — branch on word equality"},
    bne: {:system, "bne ra, rb, label"},
    blt: {:system, "blt ra, rb, label — fixnum <"},
    bge: {:system, "bge ra, rb, label — fixnum >="},
    bift: {:system, "bift rs, label — branch if rs is atom true"},
    biff: {:system, "biff rs, label — branch if rs is atom false"},

    # -- funs and closures (`notes/42`) --------------------------------------
    # A fun is a boxed object shaped exactly like a tuple — a header, then
    # `funinfo` and the captured free variables — with tag `fun` on the
    # POINTER. Same shape so the collector needs no second kind of object;
    # a different tag so `element/2` on a fun raises, as BEAM guarantees.
    mkfun:
      {:heap,
       "mkfun rd, f, nfree — allocate a closure over f with nfree free " <>
         "variables; fill them with `tset rd, 1 + j, rs`"},
    fget:
      {:heap,
       "fget rd, rf, i — read inside a closure: 0 is funinfo, 1 + j is " <>
         "captured variable j. Tag-checked as a fun, so it is not a back " <>
         "door into a tuple and `tget` is not one into a closure"},
    # -- maps, and structs behind them (`notes/42`) --------------------------
    mkmap:
      {:heap,
       "mkmap rd, rn — allocate a flatmap of rn pairs. Fill it with " <>
         "`tset rd, 1 + 2j, key` and `tset rd, 2 + 2j, value`; pair j is " <>
         "cell j + 1, so one heap read returns both halves of it"},
    mapat:
      {:heap,
       "mapat rd, rm, ri — read inside a map, at a REGISTER index: 0 is the " <>
         "pair count, 1 + 2j is key j, 2 + 2j is value j. The one indexed " <>
         "heap read whose index is not an immediate, because the probe loop " <>
         "that walks a map computes it"},
    mseti:
      {:pure,
       "mseti ri — latch the index the next `mset` writes at. A heap op has " <>
         "two register reads and a map fill needs three things, so the index " <>
         "comes in its own PURE op; what it latches is an integer, which is " <>
         "why it survives a collection where a latched pointer would not"},
    mset:
      {:heap, "mset rm, rv — write the map at the latched index"},
    # -- binaries and strings (`notes/43`) -----------------------------------
    mkbin:
      {:heap,
       "mkbin rd, rn — allocate a binary of rn BYTES. Fill it with `mset`, " <>
         "or with `tset rd, 1 + i, byte` while the index fits four bits"},
    binat:
      {:heap,
       "binat rd, rb, ri — byte ri of a binary; index 0 is the byte count. " <>
         "Byte indexed, so how many bytes share a word is the store's business " <>
         "and not the program's"},
    callfun:
      {:system,
       "callfun rd, rf, arity — call the fun in rf with the args staged " <>
         "0..arity-1. The CLOSURE rides as argument `arity` (stage it with " <>
         "`arg arity, rf` in the same bundle) and the callee unpacks its " <>
         "captured variables with `fget`"},

    # -- concurrency / OTP (system) ------------------------------------------
    spawn: {:system, "spawn rd, f, arity — staged args; placement policy per machine opts (Q6 open)"},
    send: {:system, "send rp, rm — copy term to dest heap via ring; bounded by hops+flits"},
    recv: {:system, "recv rd — sugar: take mailbox head or block"},

    # -- selective receive (the shape-hash matcher; notes/03). The matcher
    # -- runs on the mailbox BRAM's port B, so scans cost the mutator nothing
    # -- and worst-case receive latency is mailbox_depth + |match program|.
    recv_start: {:system, "recv_start — reset scan cursor, clear hash filter"},
    recv_hash: {:system, "recv_hash shape — set the 8-bit shape filter for peek"},
    recv_peek: {:system, "recv_peek rd, none_label — next filter-matching candidate, or branch"},
    recv_skip: {:system, "recv_skip — candidate did not truly match; advance cursor"},
    recv_take: {:system, "recv_take rd — remove the peeked candidate; reset cursor+filter"},
    try_begin:
      {:system,
       "try_begin rd, handler — push a catch frame; on a raise the machine unwinds " <>
         "to it, jumps to `handler`, and leaves the class in rd and the reason in rd+1"},
    try_end: {:system, "try_end — the protected expression completed; pop the catch frame"},
    recv_wait: {:system, "recv_wait — block until an unseen message arrives, then fall through"},
    recv_waitt: {:system, "recv_waitt rt, timeout_label — recv_wait with a cycle timeout"},
    link: {:system, "link rp"},
    unlink: {:system, "unlink rp"},
    monitor: {:system, "monitor rd, rp — returns ref"},
    exit2: {:system, "exit2 rp, rreason — exit/2 signal"},
    reg_name: {:system, "reg_name rn, rp — register the atom rn for local pid rp (notes/50)"},
    whereis: {:system, "whereis rd, rn — rd = pid registered under rn, or :undefined"},
    unreg: {:system, "unreg rn — release the atom rn; badarg if not registered"},
    trapexit: {:system, "trapexit imm — set/clear trap_exit"},
    yield: {:system, "yield — end turn voluntarily"},
    fail: {:system, "fail reason — trap: exit with the given reserved/interned reason atom"},
    out: {:system, "out rs — model-only observability port (erlang:display/1 lands here)"},
    halt: {:system, "halt — model-only: stop the machine (demos/tests)"}
  }

  def ops, do: @ops
  def class(op), do: elem(Map.fetch!(@ops, op), 0)
  def known?(op), do: Map.has_key?(@ops, op)

  @doc """
  Does this op write its destination through the LATE (wb2) path?

  The sequencer allocates exactly ONE wb2 turn per bundle, so two such
  ops in one bundle is not merely slow, it is unrepresentable — the
  second one's result would have nowhere to land. The bundle contract
  therefore forbids it (rule 5), and this is the predicate.

  `tset` is a heap op and takes no wb2 turn: it returns nothing.
  """
  def wb2?({:tset, _, _, _}), do: false
  def wb2?(slot) when is_tuple(slot) and tuple_size(slot) > 0 do
    op = elem(slot, 0)
    op == :ldc or (known?(op) and class(op) == :heap)
  end
  def wb2?(_), do: false

  @doc "Registers named by a slot: {reads, writes}. Staging (`arg`) counts as neither."
  def regs({:nop}), do: {[], []}
  def regs({:ldi, rd, _}), do: {[], [rd]}
  def regs({:ldn, rd}), do: {[], [rd]}
  def regs({:recv_start}), do: {[], []}
  def regs({:recv_hash, _}), do: {[], []}
  def regs({:recv_peek, rd, _}), do: {[], [rd]}
  # a catch frame WRITES its class/reason pair, but only on the raising
  # path — the assembler still has to know they are written, or a later
  # slot reading them would look like an uninitialised read
  def regs({:try_begin, rd, _}), do: {[], [rd, rd + 1]}
  def regs({:try_end}), do: {[], []}
  def regs({:recv_skip}), do: {[], []}
  def regs({:recv_take, rd}), do: {[], [rd]}
  def regs({:recv_wait}), do: {[], []}
  def regs({:recv_waitt, rt, _}), do: {[rt], []}
  def regs({:ldc, rd, _}), do: {[], [rd]}
  def regs({:lda, rd, _}), do: {[], [rd]}
  def regs({:mov, rd, rs}), do: {[rs], [rd]}
  def regs({:self, rd}), do: {[], [rd]}
  def regs({op, rd, ra, rb})
      when op in [:add, :sub, :mul, :band, :bor, :bxor, :cmpeq, :cmpne, :cmplt, :cmple],
      do: {[ra, rb], [rd]}
  def regs({:mulsr, rd, ra, rb, _k}), do: {[ra, rb], [rd]}
  def regs({:istag, rd, rs, _tag}), do: {[rs], [rd]}
  def regs({:cons, rd, rh, rt}), do: {[rh, rt], [rd]}
  def regs({:hd, rd, rs}), do: {[rs], [rd]}
  def regs({:tl, rd, rs}), do: {[rs], [rd]}
  def regs({:mktup, rd, _arity}), do: {[], [rd]}
  def regs({:tset, rt, _i, rs}), do: {[rt, rs], []}
  def regs({:tget, rd, rt, _i}), do: {[rt], [rd]}
  def regs({:tarity, rd, rt}), do: {[rt], [rd]}
  def regs({:mkfun, rd, _f, _nfree}), do: {[], [rd]}
  def regs({:fget, rd, rf, _i}), do: {[rf], [rd]}
  def regs({:mkmap, rd, rn}), do: {[rn], [rd]}
  def regs({:mkbin, rd, rn}), do: {[rn], [rd]}
  def regs({:binat, rd, rb, ri}), do: {[rb, ri], [rd]}
  def regs({:mapat, rd, rm, ri}), do: {[rm, ri], [rd]}
  def regs({:mset, rm, rv}), do: {[rm, rv], []}
  def regs({:mseti, ri}), do: {[ri], []}
  def regs({:callfun, rd, rf, _arity}), do: {[rf], [rd]}
  def regs({:arg, _i, rs}), do: {[rs], []}
  def regs({:call, rd, _f, _a}), do: {[], [rd]}
  def regs({:tailcall, _f, _a}), do: {[], []}
  def regs({:ret, rs}), do: {[rs], []}
  def regs({:jmp, _}), do: {[], []}
  def regs({op, ra, rb, _label}) when op in [:beq, :bne, :blt, :bge], do: {[ra, rb], []}
  def regs({op, rs, _label}) when op in [:bift, :biff], do: {[rs], []}
  def regs({:spawn, rd, _f, _a}), do: {[], [rd]}
  def regs({:send, rp, rm}), do: {[rp, rm], []}
  def regs({:recv, rd}), do: {[], [rd]}
  def regs({:link, rp}), do: {[rp], []}
  def regs({:unlink, rp}), do: {[rp], []}
  def regs({:monitor, rd, rp}), do: {[rp], [rd]}
  def regs({:reg_name, rn, rp}), do: {[rn, rp], []}
  def regs({:whereis, rd, rn}), do: {[rn], [rd]}
  def regs({:unreg, rn}), do: {[rn], []}
  def regs({:exit2, rp, rr}), do: {[rp, rr], []}
  def regs({:trapexit, _}), do: {[], []}
  def regs({:yield}), do: {[], []}
  def regs({:fail, _reason}), do: {[], []}
  def regs({:out, rs}), do: {[rs], []}
  def regs({:halt}), do: {[], []}
end
