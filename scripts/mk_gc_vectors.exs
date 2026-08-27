# Vectors for the collector: a from-space heap image, a root set, and
# the flit stream each surviving root must still flatten to afterwards.
#
#   mix run scripts/mk_gc_vectors.exs
#
# The oracle here is the SERIALISER, which is a better check than a
# bit-for-bit comparison of to-space would be. Where each object lands
# after a copy is an implementation detail; that the graph reachable
# from every root is unchanged is the property. So the testbench runs a
# collection and then serialises each rewritten root, comparing against
# `PicoBEAM.Serial`'s answer for the ORIGINAL term. Identical streams
# mean the graph survived — structure, contents, and sharing.
#
# The image is deliberately built with three things in it:
#
#   * GARBAGE — objects reachable from no root at all. They must not be
#     copied, which is what makes `to_hp` a meaningful assertion.
#   * SHARING — two roots pointing at the SAME object. It must be
#     copied once and both roots must end up naming that one copy;
#     copying it twice is the failure forwarding pointers exist to
#     prevent, and a serialisation comparison alone would not catch it,
#     so the testbench checks the two rewritten roots are equal.
#   * NESTING — so the Cheney scan has to find pointers inside copied
#     objects and evacuate those too.

import Bitwise
alias PicoBEAM.{Serial, Term}

defmodule GcLay do
  @moduledoc false
  import Bitwise
  alias PicoBEAM.Term

  # the same bump allocator over cells that mk_ser_vectors.exs uses,
  # which is heap.ex's layout by hand
  def put(t, st) when is_integer(t), do: {Term.int(t), st}
  def put({:atom, i}, st), do: {Term.atom(i), st}

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

st0 = %{ap: 0, h0: %{}, h1: %{}}

# --- laid down in this order, so garbage sits BETWEEN live objects and
# a collector that merely compacted rather than traced would be caught
{live1, st} = GcLay.put({1, [2 | 3], 4}, st0)
{_garbage1, st} = GcLay.put({9, 9, 9, 9}, st)
{shared, st} = GcLay.put({7, 8}, st)
{_garbage2, st} = GcLay.put([5, 6, 7], st)
{live2, st} = GcLay.put(42, st)

# two roots naming the SAME object
roots = [live1, shared, shared, live2]

# what each root must still serialise to afterwards
terms = [{1, [2 | 3], 4}, {7, 8}, {7, 8}, 42]

resolve = fn w ->
  cond do
    Term.is?(w, :tuple) ->
      c = Term.payload(w)
      n = Term.payload(Map.get(st.h0, c, 0))

      elems =
        Enum.map(0..(n - 1)//1, fn i ->
          word = i + 1
          bank = if (word &&& 1) == 1, do: st.h1, else: st.h0
          Map.get(bank, c + (word >>> 1), 0)
        end)

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
    f
  end)

# live cells: the two distinct live objects, counted once each.
# {1,[2|3],4} is 1 tuple cell pair + 1 cons cell; {7,8} is one pair.
live_cells =
  [{1, [2 | 3], 4}, {7, 8}]
  |> Enum.map_reduce(%{ap: 0, h0: %{}, h1: %{}}, &GcLay.put/2)
  |> elem(1)
  |> Map.get(:ap)

File.mkdir_p!("_emit/m4")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m4/gc_h0.hex",
  Enum.map_join(0..255, "\n", &hx.(Map.get(st.h0, &1, 0), 9)) <> "\n")
File.write!("_emit/m4/gc_h1.hex",
  Enum.map_join(0..255, "\n", &hx.(Map.get(st.h1, &1, 0), 9)) <> "\n")
File.write!("_emit/m4/gc_roots.hex",
  Enum.map_join(roots, "\n", &hx.(&1, 9)) <> "\n")
File.write!("_emit/m4/gc_lens.hex",
  Enum.map_join(vecs, "\n", &hx.(length(&1), 2)) <> "\n")
File.write!("_emit/m4/gc_flits.hex",
  Enum.map_join(vecs, "\n", fn f -> Enum.map_join(f, "\n", &hx.(&1, 9)) end) <> "\n")
File.write!("_emit/m4/gc_live.hex", hx.(live_cells, 2) <> "\n")

IO.puts("from-space cells used = #{st.ap}, live after collection = #{live_cells}")

Enum.zip(terms, vecs)
|> Enum.with_index()
|> Enum.each(fn {{t, f}, i} ->
  IO.puts("  root #{i}: #{String.pad_trailing(inspect(t), 20)} #{length(f)} flits")
end)

IO.puts("__GC_VECTORS_DONE__")
