defmodule PicoBEAM.RTL.ShapeHash do
  @moduledoc """
  M4 — the message shape hash, in gates.

  The mailbox writer stamps every arriving message with this value; the
  assembler stamps `recv_hash`'s immediate with `PicoBEAM.Encoding`'s
  identical function. `scripts/check_shape_hash.exs` proves the two
  agree, which is the same discipline the opcode table gets.

      [kind:2][arity:3][atom:3]

      kind 0  any other immediate      kind 2  tuple
      kind 1  atom                     kind 3  cons

  Tuples need one heap resolution — the arity word and the first
  element — which the engine supplies when it enqueues a compound
  message (M4's serialiser pass). For an immediate, `tup_arity` and
  `tup_first` are ignored, so a send of a fixnum, atom, pid or nil
  needs no heap access at all: that is what lets ping-pong run before
  the heap comes back.

  Pure combinational; no state, no clock edge in the path.
  """

  use Hw.Component

  # Term tags come from `PicoBEAM.Term`, not from memory. Module
  # attributes are compile-time Elixir and do not survive into a `comb`
  # block, so they reach the datapath as params — which elaboration
  # folds straight back to the literals that used to be written here by
  # hand. `notes/40` is why: the collector spent a milestone comparing
  # against a 7 that had become `:fun` somewhere else.
  param :T_ATOM, default: PicoBEAM.Term.tag_value(:atom)
  param :T_CONS, default: PicoBEAM.Term.tag_value(:cons)
  param :T_TUPLE, default: PicoBEAM.Term.tag_value(:tuple)

  clock :clk, freq: 50.0

  input :word, 36
  # heap resolution for tuples (ignored otherwise)
  input :tup_arity, 8
  input :tup_first, 36

  output :hash, 8

  wire :tag, 4
  wire :is_atom, 1
  wire :is_cons, 1
  wire :is_tuple, 1
  wire :first_is_atom, 1
  wire :ar3, 3
  wire :at3, 3

  comb do
    tag = word[35..32]
    is_atom = tag == T_ATOM
    is_cons = tag == T_CONS
    is_tuple = tag == T_TUPLE
    first_is_atom = band(is_tuple, tup_first[35..32] == T_ATOM)

    # arity saturates at 7 — the same lossy step Encoding takes
    ar3 = is_tuple * ((tup_arity > 7) * 7 + bnot(tup_arity > 7) * tup_arity[2..0])
    at3 = is_atom * word[2..0] + first_is_atom * tup_first[2..0]

    hash = is_atom * 64 + is_tuple * 128 + is_cons * 192 + ar3 * 8 + at3
  end
end
