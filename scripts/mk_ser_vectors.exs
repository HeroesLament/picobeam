# Vectors for the serialiser: a heap image laid out exactly as
# `heap.ex` addresses it, a set of root terms living in it, and the
# flit stream `PicoBEAM.Serial` says each one flattens to.
#
#   mix run scripts/mk_ser_vectors.exs
#
# The point is the same as `check_shape_hash.exs`: the wire format is
# defined once, in Elixir, and the netlist has to agree with it. A
# format specified twice drifts.

import Bitwise
alias PicoBEAM.{Serial, Term}

defmodule Lay do
  @moduledoc false
  import Bitwise
  alias PicoBEAM.Term

  # bump allocator over cells, mirroring heap.ex:
  #   cons c   -> h0[c] = head, h1[c] = tail
  #   tuple c  -> word0 = HDR|arity at h0[c]; element i at word i+1,
  #               cell c + (i+1)>>1, bank (i+1)&1
  def put(t, st) when is_integer(t), do: {Term.int(t), st}
  def put(t, st) when is_atom(t) and t in [nil], do: {Term.nil_term(), st}

  def put({:atom, i}, st), do: {Term.atom(i), st}
  def put({:pid, p}, st), do: {Term.make(:pid, p), st}

  def put(t, st) when is_tuple(t) do
    elems = Tuple.to_list(t)
    n = length(elems)
    {ews, st} = Enum.map_reduce(elems, st, &put/2)
    cells = div(n + 2, 2)
    c = st.ap
    st = %{st | ap: st.ap + cells}
    st = write(st, c, 0, Term.make(:hdr, n))

    st =
      ews
      |> Enum.with_index()
      |> Enum.reduce(st, fn {w, i}, st ->
        word = i + 1
        write(st, c + (word >>> 1), word &&& 1, w)
      end)

    # `c` is a CELL here — this script hand-rolls heap.ex's allocator —
    # and Term.tuple/1 takes a word address, so say so rather than
    # relying on the two happening to coincide (they no longer do)
    {Term.tuple(Term.cell_word(c)), st}
  end

  def put([h | t], st) do
    {hw, st} = put(h, st)
    {tw, st} = put(t, st)
    c = st.ap
    st = %{st | ap: st.ap + 1}
    st = write(st, c, 0, hw)
    st = write(st, c, 1, tw)
    {Term.cons(Term.cell_word(c)), st}
  end

  def put([], st), do: {Term.nil_term(), st}

  defp write(st, cell, 0, w), do: %{st | h0: Map.put(st.h0, cell, w)}
  defp write(st, cell, 1, w), do: %{st | h1: Map.put(st.h1, cell, w)}
end

terms = [
  42,
  -7,
  {:atom, 14},
  {1, 2, 3},
  [1 | 2],
  {1, [2 | 3]},
  {{1, 2}, {3, 4}},
  [1, 2, 3],
  {},
  {{:atom, 12}, {:pid, 0x50_0C0_0001}, {:atom, 3}},
  {1, {2, {3, {4, 5}}}}
]

st0 = %{ap: 0, h0: %{}, h1: %{}}

{roots, st} = Enum.map_reduce(terms, st0, &Lay.put/2)

# the resolver reads the SAME image the netlist will
resolve = fn w ->
  cond do
    Term.is?(w, :tuple) ->
      c = Term.payload(w)
      n = Term.payload(Map.get(st.h0, c, 0))

      elems =
        for i <- 0..(n - 1)//1 do
          word = i + 1
          bank = if (word &&& 1) == 1, do: st.h1, else: st.h0
          Map.get(bank, c + (word >>> 1), 0)
        end

      {:tuple, n, elems}

    Term.is?(w, :cons) ->
      c = Term.payload(w)
      {:cons, Map.get(st.h0, c, 0), Map.get(st.h1, c, 0)}

    true ->
      :immediate
  end
end

vecs =
  Enum.map(roots, fn r ->
    {:ok, f} = Serial.flits(r, resolve)
    {r, f}
  end)

File.mkdir_p!("_emit/m4")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m4/ser_h0.hex",
  Enum.map_join(0..255, "\n", &hx.(Map.get(st.h0, &1, 0), 9)) <> "\n")
File.write!("_emit/m4/ser_h1.hex",
  Enum.map_join(0..255, "\n", &hx.(Map.get(st.h1, &1, 0), 9)) <> "\n")
File.write!("_emit/m4/ser_roots.hex",
  Enum.map_join(vecs, "\n", fn {r, _} -> hx.(r, 9) end) <> "\n")
File.write!("_emit/m4/ser_lens.hex",
  Enum.map_join(vecs, "\n", fn {_, f} -> hx.(length(f), 2) end) <> "\n")
File.write!("_emit/m4/ser_flits.hex",
  Enum.map_join(vecs, "\n", fn {_, f} -> Enum.map_join(f, "\n", &hx.(&1, 9)) end) <> "\n")

IO.puts("cells used = #{st.ap}")

Enum.zip(terms, vecs)
|> Enum.each(fn {t, {r, f}} ->
  IO.puts("  #{String.pad_trailing(inspect(t), 34)} root=#{hx.(r, 9)} flits=#{length(f)}")
end)

IO.puts("__SER_VECTORS_DONE__ (#{length(vecs)} terms, #{Enum.sum(Enum.map(vecs, fn {_, f} -> length(f) end))} flits)")

File.write!("_emit/m4/ser_cells.hex", hx.(st.ap, 2) <> "\n")
