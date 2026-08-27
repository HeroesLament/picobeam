defmodule PicoBEAM.SerialTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Serial, Term}

  @r &Serial.elixir_resolver/1

  defp build({:tuple, elems}), do: List.to_tuple(elems)
  defp build({:cons, h, t}), do: [h | t]

  defp roundtrip(t) do
    {:ok, f} = Serial.flits(t, @r)
    {:ok, back} = Serial.rebuild(f, &build/1)
    back
  end

  test "immediates are one flit and are themselves" do
    for t <- [0, 42, -7, Term.atom(14), Term.nil_term()] do
      assert {:ok, [^t]} = Serial.flits(t, @r)
      assert roundtrip(t) == t
    end
  end

  test "postfix: children precede the marker that consumes them" do
    assert {:ok, [1, 2, 3, hdr]} = Serial.flits({1, 2, 3}, @r)
    assert hdr == Serial.hdr_word(3)

    assert {:ok, [1, 2, wc]} = Serial.flits([1 | 2], @r)
    assert wc == Serial.wcons_word()

    # the nested case is the one that pins the ORDER rather than just
    # the contents: the inner list finishes before the outer header
    assert {:ok, [1, 2, 3, wc2, hdr2]} = Serial.flits({1, [2 | 3]}, @r)
    assert wc2 == Serial.wcons_word()
    assert hdr2 == Serial.hdr_word(2)
  end

  test "every shape round-trips" do
    for t <- [
          42,
          {},
          {1},
          {1, 2, 3},
          [1 | 2],
          [1, 2, 3],
          {1, [2 | 3]},
          {{1, 2}, {3, 4}},
          {1, {2, {3, {4, 5}}}},
          [[1 | 2] | [3 | 4]]
        ] do
      assert roundtrip(t) == t, "round trip failed for #{inspect(t)}"
    end
  end

  test "flit count is the sum of the parts plus one marker each" do
    assert {:ok, 1} = Serial.flit_count(42, @r)
    assert {:ok, 4} = Serial.flit_count({1, 2, 3}, @r)
    assert {:ok, 3} = Serial.flit_count([1 | 2], @r)
    # a proper 3-list is three cons cells: 3 heads + NIL + 3 markers
    assert {:ok, 7} = Serial.flit_count([1, 2, 3], @r)
  end

  test "the two bounds are :system_limit, not a wrong answer" do
    wide = List.to_tuple(Enum.to_list(1..70))
    assert {:error, :system_limit} = Serial.flits(wide, @r)

    deep = Enum.reduce(1..12, 0, fn _, acc -> {acc} end)
    assert {:error, :system_limit} = Serial.flits(deep, @r)
  end

  test "a truncated stream is refused rather than half-rebuilt" do
    {:ok, f} = Serial.flits({1, 2, 3}, @r)
    assert {:error, :underflow} = Serial.rebuild(tl(f), &build/1)
  end

  test "a stream with more than one value left is refused" do
    {:ok, f} = Serial.flits({1, 2}, @r)
    assert {:error, :leftover} = Serial.rebuild([99 | f], &build/1)
  end

  test "randomised: any term the bounds admit survives the round trip" do
    :rand.seed(:exsss, {17, 23, 42})

    for _ <- 1..500 do
      t = gen(0)

      case Serial.flits(t, @r) do
        {:ok, _} -> assert roundtrip(t) == t, "round trip failed for #{inspect(t)}"
        {:error, :system_limit} -> :ok
      end
    end
  end

  defp gen(d) when d >= 3, do: :rand.uniform(1000) - 500

  defp gen(d) do
    case :rand.uniform(6) do
      1 -> :rand.uniform(1000) - 500
      2 -> Term.atom(:rand.uniform(16) - 1)
      3 -> Term.nil_term()
      4 -> List.to_tuple(for _ <- 1..:rand.uniform(4), do: gen(d + 1))
      5 -> [gen(d + 1) | gen(d + 1)]
      6 -> for _ <- 1..:rand.uniform(3), do: gen(d + 1)
    end
  end
end
