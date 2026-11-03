defmodule PicoBEAM.Encoding do
  @moduledoc """
  THE opcode table — the one source of binary truth shared by the
  assembler (this module encodes `Asm.assemble/1` output into 72-bit
  bundle words) and the hardware decoder (`PicoBEAM.RTL.Classify`
  mirrors the bit discipline below; change either only through here).

  ## The bit discipline (what makes hardware decode ~free)

  The op byte is `[group:4][sel:4]`, chosen so classification is a
  nibble slice and the ALU micro-op needs NO translation table:

      group 0x0_  ALU        sel IS PicoBEAM.RTL.Alu's micro-op select
      group 0x1_  load/stage ldi/ldn/ldc/lda/self/arg/nop
      group 0x2_  heap       cons/hd/tl/mktup/tset/tget/tarity
      group 0x3_  control    jmp/bift/biff/call/tailcall/ret
      group 0x4_+ system     spawn/send/receive family/links/halt...

  ## Slot layout (24 bits), matching `PicoBEAM.RTL.Decode`

      [op:8][f1:4][f2:4][f3:4][f4:4]     three-register shapes
      [op:8][f1:4][   imm12          ]   register + immediate shapes
      [op:8][f1:4][f2:4][    i8      ]   heap-index shapes (tset/tget)

  `f1` is the slot's rd position. Register-reading ops address the
  window through f2/f3 (decode's ra/rb) — EXCEPT the rs+imm shapes
  (`bift`, `biff`, `ret`, `out`, `recv_waitt`...), whose register sits
  in f1 because imm12 covers f2..f4; the engine muxes that slot's read
  address from f1 when the op group demands it (one 2:1 mux, only ever
  exercised by the bundle's single system op).

  ## `recv` is sugar and is not encodable — by decision

  `recv rd` in the model means "take the mailbox head or block". It has
  an opcode reserved (0x42) and no gates, and after `notes/23` counted
  coverage the question was whether to build it.

  The answer is no, on the same grounds as the two-register branches
  below. The receive FAMILY — `recv_start`/`recv_wait`/`recv_peek`/
  `recv_take`/`recv_skip` — is fully implemented and covers it; the
  Core Erlang front end has never emitted `recv` and never will,
  because `receive` with any pattern needs the filter; and a fused op
  used only by hand-written test programs is ISA surface with no user,
  which is the kind of thing that rots quietly and then misleads
  whoever reads the table next.

  The model keeps the fused form — it costs nothing there and documents
  intent — and `encode_slot/1` refuses it at the doorstep with the
  lowering spelled out. If the unfiltered receive ever measures hot,
  the answer is a PEEPHOLE in the assembler that recognises the
  four-bundle idiom, not a second matcher FSM.

  ## Two-register branches are not encodable — by decision

  `beq/bne/blt/bge ra, rb, label` needs 28 bits (scaffolding-pass
  finding, `notes/15`). The bytes 0x31..0x34 stay RESERVED and
  `encode_slot/1` raises: emitters must lower to `cmp*` + `bift`, which
  the front end can always do (it owns a scratch register; the
  assembler does not). The model ISA keeps the fused forms legal —
  they cost nothing there and document intent — so lowering happens at
  encode time's doorstep, not in `Machine`.

  ## Not yet encoded here

  `ldc`/`lda` pool and atom indices pass through as given (the
  flattener does not yet build the literal pool from `Machine`-style
  programs — that lands with the loader path).

  `spawn`'s arity used to ride the staging frame rather than the
  instruction — clean-on-call, the args are already there — and the
  hardware never saw it. Cross-engine spawn needs it (`notes/49`): the
  sender has to know how many staged words are the arguments before it
  can ask whether they are all immediates, and the receiver has to know
  how many to install. It is three bits above the nine-bit target in
  `spawn`'s twelve-bit immediate, which caps spawn arity at **seven** —
  a limit worth stating beside the sixteen-register window rather than
  hidden behind it.
  """

  import Bitwise

  alias PicoBEAM.Term

  @opcodes %{
    # group 0x0_ — ALU; low nibble = Alu sel
    add: 0x00,
    sub: 0x01,
    mul: 0x02,
    mulsr: 0x0C,
    band: 0x03,
    bor: 0x04,
    bxor: 0x05,
    cmpeq: 0x06,
    cmpne: 0x07,
    cmplt: 0x08,
    cmple: 0x09,
    istag: 0x0A,
    mov: 0x0B,
    # group 0x1_ — load / stage
    ldi: 0x10,
    ldn: 0x11,
    ldc: 0x12,
    lda: 0x13,
    self: 0x14,
    arg: 0x16,
    mseti: 0x17,
    nop: 0x1F,
    # group 0x2_ — heap
    cons: 0x20,
    hd: 0x21,
    tl: 0x22,
    mktup: 0x23,
    tset: 0x24,
    tget: 0x25,
    tarity: 0x26,
    # `notes/42` — a fun is a boxed object, so `mkfun` is a heap op
    mkfun: 0x27,
    # cmd 8 in the store, which is why `cmd` there is four bits now
    fget: 0x28,
    mapat: 0x29,
    mkmap: 0x2A,
    mset: 0x2B,
    mkbin: 0x2C,
    binat: 0x2D,
    # group 0x3_ — control (0x31..0x34 reserved: two-reg branches, see above)
    jmp: 0x30,
    bift: 0x35,
    biff: 0x36,
    call: 0x38,
    tailcall: 0x39,
    ret: 0x3A,
    # the indirect call. Same group as `call` because it IS a call; the
    # target comes from a register instead of the bundle.
    callfun: 0x3B,
    # group 0x4_/0x5_ — system
    # 0x58 + arity (0..7): the twelve-bit immediate is all target, so the
    # arity moved from it into the opcode (code memory 4096 bundles)
    spawn: 0x58,
    send: 0x41,
    recv: 0x42,
    recv_start: 0x43,
    recv_hash: 0x44,
    recv_peek: 0x45,
    recv_skip: 0x46,
    recv_take: 0x47,
    recv_wait: 0x48,
    recv_waitt: 0x49,
    link: 0x4A,
    unlink: 0x4B,
    monitor: 0x4C,
    exit2: 0x4D,
    trapexit: 0x4E,
    yield: 0x4F,
    # try/catch. `notes/30`: a supervisor that cannot catch is half a
    # supervisor, and the shape erlc actually emits wraps a CALL, so
    # this has to unwind frames rather than just redirect a pc.
    try_begin: 0x53,
    try_end: 0x54,
    # registered names (notes/50): one CAM, node-local per notes/12
    reg_name: 0x55,
    whereis: 0x56,
    unreg: 0x57,
    fail: 0x50,
    out: 0x51,
    halt: 0x52
  }

  def opcodes, do: @opcodes
  def opcode(op), do: Map.fetch!(@opcodes, op)

  # ---------------------------------------------------------------------------
  # The shape hash — a HARDWARE contract (notes/17)
  # ---------------------------------------------------------------------------

  @doc """
  Pack a message's match-shape into 8 bits.

  `recv_hash` carries this value as an immediate, computed HERE at
  assembly time; `PicoBEAM.RTL.ShapeHash` computes the same value in
  gates for each arriving message, and the mailbox stores it beside the
  word. The two must agree exactly, so — like the opcode table — this
  function is the single definition and `scripts/check_shape_hash.exs`
  is the tripwire. The model's `:erlang.phash2/2` does not survive into
  hardware; the model moves, as it did for heap cell addressing.

      [kind:2][arity:3][atom:3]

      kind 0  any other immediate (fixnum, pid, nil, ...)
      kind 1  atom              — low 3 bits of the atom index
      kind 2  tuple             — arity (saturating at 7) and the low
                                  3 bits of the leading atom, if the
                                  first element IS an atom
      kind 3  cons

  The hash is a FILTER, never a decision: the real pattern match is
  ordinary code after `recv_peek`. A collision costs one wasted peek,
  so the packing is allowed to be lossy — a tuple led by atom index 0
  and a tuple of the same arity led by a non-atom deliberately share a
  hash. What it may never do is give two different values for the same
  shape, which is why saturation and masking are the only lossy steps.
  """
  def shape_hash(:other), do: 0
  def shape_hash({:atom, idx}) when is_integer(idx), do: 0x40 ||| (idx &&& 7)
  def shape_hash(:cons), do: 0xC0

  def shape_hash({:tuple, arity, nil}),
    do: 0x80 ||| (min(arity, 7) &&& 7) <<< 3

  def shape_hash({:tuple, arity, atom_idx}) when is_integer(atom_idx),
    do: 0x80 ||| ((min(arity, 7) &&& 7) <<< 3) ||| (atom_idx &&& 7)

  @doc """
  The shape hash of a concrete term WORD, given the heap resolution a
  tuple needs. Mirrors `PicoBEAM.RTL.ShapeHash` exactly; used by the
  tripwire and by co-simulation.
  """
  def shape_hash_of_word(word, tuple_arity \\ 0, tuple_first \\ nil) do
    case Term.tag(word) do
      0x1 -> shape_hash({:atom, Term.payload(word)})
      0x3 -> shape_hash(:cons)
      0x4 ->
        if is_integer(tuple_first) and Term.tag(tuple_first) == 0x1 do
          shape_hash({:tuple, tuple_arity, Term.payload(tuple_first)})
        else
          shape_hash({:tuple, tuple_arity, nil})
        end

      _ -> shape_hash(:other)
    end
  end

  defmodule Error do
    defexception [:message]
  end

  # ---------------------------------------------------------------------------
  # Slot encoding
  # ---------------------------------------------------------------------------

  defp s(op, f1 \\ 0, f2 \\ 0, f3 \\ 0, f4 \\ 0) do
    opcode(op) <<< 16 ||| (f1 &&& 0xF) <<< 12 ||| (f2 &&& 0xF) <<< 8 |||
      (f3 &&& 0xF) <<< 4 ||| (f4 &&& 0xF)
  end

  defp si(op, f1, imm12) do
    opcode(op) <<< 16 ||| (f1 &&& 0xF) <<< 12 ||| (imm12 &&& 0xFFF)
  end

  defp s8(op, f1, f2, i8) do
    opcode(op) <<< 16 ||| (f1 &&& 0xF) <<< 12 ||| (f2 &&& 0xF) <<< 8 ||| (i8 &&& 0xFF)
  end

  @doc """
  Encode one resolved slot tuple (as `Asm.assemble/1` emits them, labels
  already integers) into its 24-bit word. Call/spawn/tailcall function
  targets must already be flattened to absolute bundle addresses — see
  `image/2`.
  """
  def encode_slot(slot) do
    case slot do
      {:nop} -> s(:nop)
      # ALU three-register
      {op, rd, ra, rb} when op in [:add, :sub, :mul, :band, :bor, :bxor, :cmpeq, :cmpne, :cmplt, :cmple] ->
        s(op, rd, ra, rb)
      # mulsr rides the four-field shape: rd, ra, rb, and the shift in
      # f4. The shift is BIASED BY ONE — encoded 0..15 means 1..16 —
      # because a shift of zero is just `mul`, so spending the code
      # point on it would cost the only value that reaches Q16.
      {:mulsr, rd, ra, rb, k} when k in 1..16 -> s(:mulsr, rd, ra, rb, k - 1)
      {:mulsr, _rd, _ra, _rb, k} ->
        raise Error,
          message: "mulsr shift #{k} is outside 1..16 (f4 is four bits, biased by one)"
      {:istag, rd, rs, tag} -> s(:istag, rd, rs, Term.tag_value(tag))
      {:mov, rd, rs} -> s(:mov, rd, rs)
      # loads / staging
      {:ldi, rd, imm} -> si(:ldi, rd, imm)
      {:ldn, rd} -> s(:ldn, rd)
      {:ldc, rd, idx} -> si(:ldc, rd, idx)
      {:lda, rd, idx} when is_integer(idx) -> si(:lda, rd, idx)
      # A programmer writes an atom, not an index. Reserved atoms have
      # fixed indices by ABI (`Term.reserved_atoms/0`), so they encode
      # here; application atoms need the image's atom table, which
      # arrives with the loader (`notes/11`), and until then they are
      # refused rather than guessed at.
      # An atom name reaching HERE has not been through `image/2`'s atom
      # table, which is the only thing that can number an application
      # atom. Reserved ones still encode directly, because their indices
      # are ABI and need no table.
      {:lda, rd, name} when is_atom(name) ->
        case Enum.find_index(Term.reserved_atoms(), &(&1 == name)) do
          nil ->
            raise Error,
              message:
                "lda #{inspect(name)}: an application atom must be numbered by " <>
                  "`Encoding.image/2` before encoding — encode the IMAGE, not the slot"

          i ->
            si(:lda, rd, i)
        end
      {:self, rd} -> s(:self, rd)
      {:arg, i, rs} -> s(:arg, i, rs)
      # heap
      {:cons, rd, rh, rt} -> s(:cons, rd, rh, rt)
      {:hd, rd, rs} -> s(:hd, rd, rs)
      {:tl, rd, rs} -> s(:tl, rd, rs)
      {:mktup, rd, arity} -> s8(:mktup, rd, 0, arity)
      # tset needs TWO register reads (pointer + value), so rt/rs ride the
      # ra/rb port fields (f2/f3) and the index drops to f4 — 4 bits, so
      # tset's index ceiling is 15 in v1 hardware (tget keeps 8 bits: one
      # read). The model allows 255; encode refuses what gates can't do.
      {:tset, rt, i, rs} when i in 0..15 -> s(:tset, 0, rt, rs, i)
      {:tset, _rt, i, _rs} ->
        raise Error, message: "tset index #{i} exceeds the v1 hardware ceiling (15)"
      {:tget, rd, rt, i} -> s8(:tget, rd, rt, i)
      {:fget, rd, rf, i} -> s8(:fget, rd, rf, i)
      # `mapat`'s index is a REGISTER, so it rides the rb port the way
      # `tset`'s value does; f4 is spare
      {:mapat, rd, rm, ri} -> s(:mapat, rd, rm, ri)
      # the pair count is a REGISTER, on the ra port
      {:mkmap, rd, rn} -> s(:mkmap, rd, rn)
      # binaries take the same two shapes: a count in a register, and a
      # BYTE index in one. The layout under them is the store's business
      {:mkbin, rd, rn} -> s(:mkbin, rd, rn)
      {:binat, rd, rb, ri} -> s(:binat, rd, rb, ri)
      # `mset` is `tset` with the index in a per-process latch: the map
      # and the value take the two read ports and there is no third
      {:mset, rm, rv} -> s(:mset, 0, rm, rv)
      {:mseti, ri} -> s(:mseti, 0, ri)
      {:tarity, rd, rt} -> s(:tarity, rd, rt)
      # `mkfun rd, k, nfree` — k is a POOL index by the time it encodes,
      # the way `lda`'s atom is a table index by then. The pool word IS
      # the funinfo the object carries, so the entry, the fun's arity and
      # the free-variable count are decided once, at image time.
      {:mkfun, rd, k, nfree} when is_integer(k) and nfree in 0..14 ->
        s8(:mkfun, rd, nfree, k)

      {:mkfun, _rd, f, _nfree} when is_atom(f) ->
        raise Error,
          message:
            "mkfun #{inspect(f)}: a fun's entry must be resolved by " <>
              "`Encoding.image/2` before encoding — encode the IMAGE, not the slot"
      # control — rs+imm shapes carry their register in f1 (see moduledoc)
      {:jmp, t} -> si(:jmp, 0, t)
      {op, _ra, _rb, _t} when op in [:beq, :bne, :blt, :bge] ->
        raise Error,
          message:
            "#{op} is not encodable (28 bits > 24, notes/15): lower to cmp* + bift/biff"

      {:recv, _rd} ->
        raise Error,
          message:
            "recv is sugar and has no encoding: lower to recv_start + recv_wait + " <>
              "recv_peek + recv_take (notes/23). The model keeps the fused form " <>
              "because it documents intent for free; gates do not, because the " <>
              "family already covers it and the front end never emits it."
      {:bift, rs, t} -> si(:bift, rs, t)
      {:biff, rs, t} -> si(:biff, rs, t)
      {:call, rd, t, _arity} -> si(:call, rd, t)
      {:tailcall, t, _arity} -> si(:tailcall, 0, t)
      {:ret, rs} -> s(:ret, rs)
      # callfun READS the fun through the ra port (f2) and writes rd, so
      # it needs no immediate at all: the target is in the object.
      {:callfun, rd, rf, arity} -> s(:callfun, rd, rf, arity)
      # system
      {:spawn, rd, t, arity} ->
        if arity > 7 do
          raise Error,
            message: "spawn arity #{arity} > 7: the arity rides `spawn`'s " <>
              "opcode (0x58 + arity), and there are eight of them"
        end

        (opcode(:spawn) + arity) <<< 16 ||| (rd &&& 0xF) <<< 12 ||| (t &&& 0xFFF)
      # send reads TWO registers and writes none, so the pid and the
      # message ride f2/f3 — the slot's ordinary ra/rb read ports — and
      # f1 (the rd position) stays empty. Same trick `tset` uses; it
      # costs the engine no extra address mux at all.
      {:send, rp, rm} -> s(:send, 0, rp, rm)
      {:recv_start} -> s(:recv_start)
      {:recv_hash, shape} when is_integer(shape) -> si(:recv_hash, 0, shape)
      {:recv_hash, spec} -> si(:recv_hash, 0, shape_hash(spec))
      {:recv_peek, rd, t} -> si(:recv_peek, rd, t)
      {:try_begin, rd, t} -> si(:try_begin, rd, t)
      {:try_end} -> s(:try_end)
      {:recv_skip} -> s(:recv_skip)
      {:recv_take, rd} -> s(:recv_take, rd)
      {:recv_wait} -> s(:recv_wait)
      {:recv_waitt, rt, t} -> si(:recv_waitt, rt, t)
      # Like `send`, these read through the slot's ordinary ra/rb ports
      # (f2/f3) with f1 — the rd position — left empty, rather than
      # claiming an `rs_in_f1` mux they do not need. `monitor` is the
      # exception: it WRITES a ref, so its rd really is in f1.
      {:link, rp} -> s(:link, 0, rp)
      {:unlink, rp} -> s(:unlink, 0, rp)
      {:monitor, rd, rp} -> s(:monitor, rd, rp)
      {:reg_name, rn, rp} -> s(:reg_name, 0, rn, rp)
      {:whereis, rd, rn} -> s(:whereis, rd, rn)
      {:unreg, rn} -> s(:unreg, 0, rn)
      {:exit2, rp, rr} -> s(:exit2, 0, rp, rr)
      {:trapexit, imm} -> si(:trapexit, 0, imm)
      {:yield} -> s(:yield)
      {:fail, idx} when is_integer(idx) -> si(:fail, 0, idx)

      {:fail, reason} when is_atom(reason) ->
        si(:fail, 0, Enum.find_index(Term.reserved_atoms(), &(&1 == reason)) || 0)
      {:out, rs} -> s(:out, rs)
      {:halt} -> s(:halt)
      other ->
        raise Error, message: "unencodable slot #{inspect(other)}"
    end
  end

  @doc "Encode one normalized bundle {a, b, c} into its 72-bit word."
  def encode_bundle({a, b, c}) do
    encode_slot(a) <<< 48 ||| encode_slot(b) <<< 24 ||| encode_slot(c)
  end

  # ---------------------------------------------------------------------------
  # Program flattening — Asm output to a code image
  # ---------------------------------------------------------------------------

  @doc """
  Flatten assembled output (`%{fun => %{name, arity, code}}`) into one
  code image: `%{image: [int72], bases: %{fun => addr}, entry: addr}`.

  Function bases are assigned with the entry function first, the rest in
  sorted-name order (determinism). Local branch/receive targets shift by
  the function's base; `call`/`tailcall`/`spawn` fun atoms resolve to the
  callee's base address.
  """
  @pool_depth 256

  @doc """
  Build the literal pool and rewrite every `ldc` to its index.

  A program writes `{:ldc, rd, 40000}` — a VALUE — because that is what
  the programmer means. The 12-bit `ldi` immediate reaches -2048..2047,
  and everything wider had to be built with arithmetic: the Hermite
  demo in `notes/21` spends three bundles on `ldi 2000; ldi 20; mul` to
  say 40000, which is both slower and a lie about what the code is
  doing.

  Interning happens HERE rather than in `encode_slot/1` because it is a
  whole-image property: the same constant in two functions must get one
  slot, and the index is only knowable once every function has been
  seen. Values are deduped and ordered by first appearance, so the pool
  is deterministic — the Gensym lesson from `notes/10`, applied before
  the mistake rather than after.

  An integer is interned as its `Term.int/1` word; a `{:atom, i}` or a
  raw 36-bit word passes through as itself.
  """
  @doc """
  The program's atom table: every atom the code names that is not one
  of the reserved ones, in a deterministic order.

  Reserved atoms hold indices 0..#{length(Term.reserved_atoms()) - 1} by
  ABI (`notes/13`) so a signal can name a reason without allocating.
  Everything a PROGRAM says — `inc`, `ok`, `badmatch`, a record tag —
  gets an index after them.

  This function exists so the table is defined ONCE. `Encoding.image/2`
  numbers atoms with it and `Machine.new/2` interns with it, which is
  the only way the two can be guaranteed to agree about what `lda 19`
  means. A table computed independently on each side is a table that
  drifts, and the symptom would be a program printing the wrong atom
  name — the kind of bug that looks like a typo for a week.
  """
  def program_atoms(assembled) do
    reserved = Term.reserved_atoms()

    assembled
    |> Enum.sort_by(fn {f, _} -> to_string(f) end)
    |> Enum.flat_map(fn {_f, %{code: code}} ->
      code |> Tuple.to_list() |> Enum.flat_map(&Tuple.to_list/1)
    end)
    |> Enum.flat_map(fn
      {:lda, _rd, name} when is_atom(name) -> [name]
      {:fail, reason} when is_atom(reason) -> [reason]
      _ -> []
    end)
    |> Enum.reject(&(&1 in reserved))
    |> Enum.uniq()
  end

  @doc "Index of an atom in the ABI + program table."
  def atom_index(name, program_atoms) do
    reserved = Term.reserved_atoms()

    case Enum.find_index(reserved, &(&1 == name)) do
      nil ->
        case Enum.find_index(program_atoms, &(&1 == name)) do
          nil ->
            raise Error, message: "atom #{inspect(name)} is not in the program's table"

          i ->
            length(reserved) + i
        end

      i ->
        i
    end
  end

  @doc """
  Every function in the program, numbered. `notes/42`: a fun carries its
  entry in a heap word, and an entry is a pc — a function NAME in the
  model, a bundle address in an image. This is the model's numbering,
  and it lives here for the same reason `program_atoms/1` does: so that
  the two sides agree by construction rather than by both being careful.
  """
  def fun_index_table(assembled) do
    assembled |> Map.keys() |> Enum.sort() |> Enum.with_index() |> Map.new()
  end

  def build_pool(assembled, bases \\ %{}) do
    slots =
      assembled
      |> Map.values()
      |> Enum.flat_map(fn %{code: code} ->
        code |> Tuple.to_list() |> Enum.flat_map(&Tuple.to_list/1)
      end)

    values =
      slots
      |> Enum.flat_map(fn
        {:ldc, _rd, v} -> [pool_word(v)]
        # `notes/42` — a closure's `funinfo` is a literal like any other,
        # so it rides the pool the atom table's numbering rides `lda`.
        # It has to be built HERE rather than at the slot, because the
        # entry is a bundle address and only `image/2` knows those.
        {:mkfun, _rd, f, nfree} when is_atom(f) -> [funinfo_word(assembled, bases, f, nfree)]
        _ -> []
      end)
      |> Enum.uniq()

    if length(values) > @pool_depth do
      raise Error,
        message: "#{length(values)} distinct literals; LitPool holds #{@pool_depth}"
    end

    {values, values |> Enum.with_index() |> Map.new()}
  end

  defp pool_word(v) when is_integer(v) and v >= 0 and v < 1 <<< 36, do: v
  defp pool_word(v) when is_integer(v), do: Term.int(v)
  defp pool_word({:atom, i}), do: Term.atom(i)
  # a tagged word the program cannot spell any other way: `erlang:host/0`'s
  # pid on ring node 15
  defp pool_word({:raw, w}) when is_integer(w) and w >= 0 and w < 1 <<< 36, do: w

  # The fun's VISIBLE arity is the lifted function's arity minus one: the
  # closure rides as the last parameter and the captured variables are
  # unpacked out of it, not passed beside it (`notes/42`). `nfree` is
  # carried for the object's own sake and is not part of the count.
  #
  # This said `total - nfree` for one commit, because that is what the
  # first design did, and every closure over nothing reported an arity
  # one too high — which `callfun` then refused with `badarity`. The two
  # halves of a packed word have to be decided in one place; they are
  # decided in `Term.funinfo/3`, and this is the only caller on this side.
  defp funinfo_word(assembled, bases, f, nfree) do
    case Map.fetch(assembled, f) do
      {:ok, %{arity: total}} when total >= 1 ->
        Term.funinfo(Map.fetch!(bases, f), total - 1, nfree)

      {:ok, %{arity: total}} ->
        raise Error,
          message: "mkfun #{f}/#{total} has no room for the closure it must carry"

      :error ->
        raise Error, message: "mkfun target #{inspect(f)} is not a function in this program"
    end
  end

  def image(assembled, entry) do
    order =
      [entry | assembled |> Map.keys() |> Enum.reject(&(&1 == entry)) |> Enum.sort()]

    {bases, total} =
      Enum.reduce(order, {%{}, 0}, fn f, {bases, addr} ->
        {Map.put(bases, f, addr), addr + tuple_size(Map.fetch!(assembled, f).code)}
      end)

    if total > 4096 do
      raise Error, message: "image is #{total} bundles; CodeMem holds 4096"
    end

    {pool, pool_idx} = build_pool(assembled, bases)
    atoms = program_atoms(assembled)

    # `notes/42` — every `mkfun` target, resolved to the pool slot its
    # `funinfo` landed in. Built once here because the funinfo word needs
    # both the arity (from `assembled`) and the entry (from `bases`), and
    # `patch` has neither.
    funpool =
      assembled
      |> Map.values()
      |> Enum.flat_map(fn %{code: code} ->
        code |> Tuple.to_list() |> Enum.flat_map(&Tuple.to_list/1)
      end)
      |> Enum.flat_map(fn
        {:mkfun, _rd, f, nfree} when is_atom(f) -> [{f, nfree}]
        _ -> []
      end)
      |> Enum.uniq()
      |> Map.new(fn {f, nfree} ->
        {{f, nfree}, Map.fetch!(pool_idx, funinfo_word(assembled, bases, f, nfree))}
      end)

    image =
      Enum.flat_map(order, fn f ->
        %{code: code} = Map.fetch!(assembled, f)
        base = bases[f]

        code
        |> Tuple.to_list()
        |> Enum.map(fn {a, b, c} ->
          encode_bundle({
            patch(a, base, bases, pool_idx, atoms, funpool),
            patch(b, base, bases, pool_idx, atoms, funpool),
            patch(c, base, bases, pool_idx, atoms, funpool)
          })
        end)
      end)

    %{image: image, bases: bases, entry: bases[entry], pool: pool, atoms: atoms}
  end

  # shift local targets by base; resolve callee atoms to their base
  # address; turn an `ldc` VALUE into its pool index; number atoms
  defp patch({:ldc, rd, v}, _base, _bases, pool_idx, _atoms, _funpool),
    do: {:ldc, rd, Map.fetch!(pool_idx, pool_word(v))}

  defp patch({:lda, rd, name}, _base, _bases, _pool_idx, atoms, _funpool) when is_atom(name),
    do: {:lda, rd, atom_index(name, atoms)}

  defp patch({:fail, reason}, _base, _bases, _pool_idx, atoms, _funpool) when is_atom(reason),
    do: {:fail, atom_index(reason, atoms)}

  # `notes/42` — the closure's funinfo was numbered into the pool above
  defp patch({:mkfun, rd, f, nfree}, _base, _bases, _pool_idx, _atoms, funpool)
       when is_atom(f),
       do: {:mkfun, rd, Map.fetch!(funpool, {f, nfree}), nfree}

  defp patch(slot, base, bases, _pool_idx, _atoms, _funpool), do: patch(slot, base, bases)

  defp patch(slot, base, bases) do
    case slot do
      {:jmp, t} when is_integer(t) -> {:jmp, t + base}
      {:bift, rs, t} -> {:bift, rs, t + base}
      {:biff, rs, t} -> {:biff, rs, t + base}
      {:recv_peek, rd, t} -> {:recv_peek, rd, t + base}
      {:try_begin, rd, t} when is_integer(t) -> {:try_begin, rd, t + base}
      {:recv_waitt, rt, t} -> {:recv_waitt, rt, t + base}
      {:call, rd, f, a} when is_atom(f) -> {:call, rd, Map.fetch!(bases, f), a}
      {:tailcall, f, a} when is_atom(f) -> {:tailcall, Map.fetch!(bases, f), a}
      {:spawn, rd, f, a} when is_atom(f) -> {:spawn, rd, Map.fetch!(bases, f), a}
      other -> other
    end
  end
end
