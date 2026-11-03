defmodule PicoBEAM.Wire do
  @moduledoc """
  Host terms to flits and back: the host port's half of `PicoBEAM.Serial`.

  A message on the ring is its postfix flit list (`Serial`): immediates
  as their words, a tuple's elements then `hdr|n`, a cons's head and
  tail then `wcons`. The board-side driver moves those flits through
  `RingHost`; this turns them into Elixir terms and back.

  Atoms are numbered by the machine's table, so both directions take the
  link state (`PicoBEAM.Link`) that numbered them. Pids and refs come
  back as `Pid` and `Ref` structs and go out as the words they came in
  as. A boxed word the wire cannot carry (a fun, map or binary pointer:
  `Serial` walks only tuples and conses) decodes as `{:pb_box, tag,
  payload}`, which is what it is: an address in another heap.
  """

  import Bitwise

  alias PicoBEAM.{Link, Serial, Term}

  defmodule Pid do
    @moduledoc "A picoBEAM pid: engine (15 = the host), slot, serial."
    defstruct [:engine, :slot, :serial]

    def word(%__MODULE__{engine: e, slot: s, serial: n}), do: Term.pid(e, s, n)

    defimpl Inspect do
      def inspect(%{engine: e, slot: s, serial: n}, _), do: "#PBPid<#{e}.#{s}.#{n}>"
    end
  end

  defmodule Ref do
    @moduledoc "A picoBEAM reference."
    defstruct [:serial]

    defimpl Inspect do
      def inspect(%{serial: n}, _), do: "#PBRef<#{n}>"
    end
  end

  defmodule Error do
    defexception [:message]
  end

  @doc """
  Flits for `term`, and the state with any new atoms interned. Raises on
  what the wire cannot carry (floats, binaries, maps, funs, integers
  outside 32 bits) and past `Serial`'s depth and length bounds.
  """
  def encode(term, %Link{} = st) do
    st = Link.intern(st, atoms_of(term))
    out = walk(term, st, 0, [])

    if length(out) > Serial.max_flits() do
      raise Error, message: "#{length(out)} flits; a message holds #{Serial.max_flits()}"
    end

    {st, Enum.reverse(out)}
  end

  @doc "The term a flit list rebuilds to."
  def decode(flits, %Link{} = st) do
    flits
    |> Enum.reduce([], fn w, stack ->
      cond do
        w == Serial.wcons_word() ->
          [t, h | rest] = stack
          [[h | t] | rest]

        Term.is?(w, :hdr) ->
          n = Term.payload(w)
          {elems, rest} = Enum.split(stack, n)
          [elems |> Enum.reverse() |> List.to_tuple() | rest]

        true ->
          [word(w, st) | stack]
      end
    end)
    |> case do
      [one] -> one
      other -> raise Error, message: "flits rebuild to #{length(other)} terms"
    end
  end

  @doc "One immediate word as a host term."
  def word(w, st) do
    p = Term.payload(w)

    case Term.tag_name(w) do
      :int -> Term.int_value(w)
      :atom -> Link.atom_name(st, p) || {:pb_atom, p}
      :nil -> []
      :pid -> %Pid{engine: p >>> 28 &&& 0xF, slot: p >>> 22 &&& 0x3F, serial: p &&& 0x3FFFFF}
      :ref -> %Ref{serial: p}
      tag -> {:pb_box, tag, p}
    end
  end

  # ---------------------------------------------------------------------------

  defp walk(_t, _st, depth, _acc) when depth > 8,
    do: raise(Error, message: "nested deeper than #{Serial.max_depth()}")

  defp walk(t, st, depth, acc) when is_tuple(t) do
    acc = t |> Tuple.to_list() |> Enum.reduce(acc, &walk(&1, st, depth + 1, &2))
    [Term.hdr(tuple_size(t)) | acc]
  end

  defp walk([h | t], st, depth, acc) do
    acc = walk(h, st, depth + 1, acc)
    acc = walk(t, st, depth + 1, acc)
    [Serial.wcons_word() | acc]
  end

  defp walk(t, st, _depth, acc), do: [imm(t, st) | acc]

  defp imm([], _st), do: Term.nil_word()
  defp imm(n, _st) when is_integer(n) and n >= -0x8000_0000 and n <= 0x7FFF_FFFF, do: Term.int(n)
  defp imm(a, st) when is_atom(a), do: Term.atom(Link.atom_index(st, a))
  defp imm(%Pid{} = p, _st), do: Pid.word(p)
  defp imm(%Ref{serial: n}, _st), do: Term.ref(n)
  defp imm(other, _st), do: raise(Error, message: "the wire cannot carry #{inspect(other)}")

  defp atoms_of(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&atoms_of/1)
  defp atoms_of([h | t]), do: atoms_of(h) ++ atoms_of(t)
  defp atoms_of(a) when is_atom(a), do: [a]
  defp atoms_of(_), do: []
end
