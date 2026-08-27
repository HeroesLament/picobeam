defmodule PicoBEAM.Asm do
  @moduledoc """
  The M1 assembler: hand-written programs until the Core Erlang front end
  exists. Bundles in, contract-checked and label-resolved code out.

  A program is `%{fun_name => {arity, body}}` where body is a list of
  labels (bare atoms) and bundles (lists of 1..3 slot tuples):

      %{
        fact: {1,
         [
           [{:ldi, 1, 1}],
           [{:blt, 1, 0, :recurse}],       # 1 < n ?
           [{:ret, 1}],
           :recurse,
           [{:sub, 2, 0, 1}],
           [{:arg, 0, 2}],
           [{:call, 3, :fact, 1}],
           [{:mul, 4, 0, 3}],
           [{:ret, 4}]
         ]}
      }

  The assembler REJECTS bundle-contract violations (see PicoBEAM.ISA):
  same-bundle RAW/WAW, >1 heap op, >1 system op, system op not last, and
  any field outside its encoding budget. These errors are the compiler's
  future obligations surfacing early, on purpose.
  """

  alias PicoBEAM.ISA

  defmodule Error do
    defexception [:message]
  end

  @max_fun_bundles 2048
  @ldi_min -2048
  @ldi_max 2047

  def assemble(program) when is_map(program) do
    Map.new(program, fn {name, {arity, body}} ->
      {name, assemble_fun(name, arity, body)}
    end)
  end

  defp assemble_fun(name, arity, body) do
    {labels, bundles} = collect(body)

    if length(bundles) >= @max_fun_bundles do
      raise Error, message: "#{name}: #{length(bundles)} bundles exceeds encoding budget (#{@max_fun_bundles})"
    end

    bundles =
      bundles
      |> Enum.with_index()
      |> Enum.map(fn {slots, idx} ->
        validate!(name, idx, slots)
        slots |> Enum.map(&resolve_label(&1, labels, name)) |> normalize()
      end)

    %{name: name, arity: arity, code: List.to_tuple(bundles)}
  end

  defp collect(body) do
    {labels, bundles, _} =
      Enum.reduce(body, {%{}, [], 0}, fn
        label, {labels, acc, idx} when is_atom(label) ->
          {Map.put(labels, label, idx), acc, idx}

        bundle, {labels, acc, idx} when is_list(bundle) ->
          {labels, [bundle | acc], idx + 1}
      end)

    {labels, Enum.reverse(bundles)}
  end

  defp normalize(slots) do
    case slots do
      [a] -> {a, {:nop}, {:nop}}
      [a, b] -> {a, b, {:nop}}
      [a, b, c] -> {a, b, c}
    end
  end

  # ---------------------------------------------------------------------------
  # Contract validation
  # ---------------------------------------------------------------------------

  defp validate!(fun, idx, slots) do
    err = fn msg -> raise Error, message: "#{fun}[#{idx}]: #{msg}" end

    if slots == [] or length(slots) > 3, do: err.("bundle must have 1..3 slots")

    Enum.each(slots, fn slot ->
      op = elem(slot, 0)
      unless ISA.known?(op), do: err.("unknown op #{inspect(op)}")
      check_fields!(slot, err)
    end)

    classes = Enum.map(slots, &ISA.class(elem(&1, 0)))

    if Enum.count(classes, &(&1 == :heap)) > 1,
      do: err.("more than one heap op per bundle (rule 2)")

    sys_count = Enum.count(classes, &(&1 == :system))
    if sys_count > 1, do: err.("more than one system op per bundle (rule 3)")

    if sys_count == 1 and List.last(classes) != :system,
      do: err.("system op must be the last occupied slot (rule 3)")

    # Rule 5: one LATE write-back per bundle. The sequencer allocates a
    # single wb2 turn, so a second `ldc` or heap op in the same bundle
    # would have nowhere to land its result — the restriction is in the
    # datapath, and this is where it gets said out loud.
    if Enum.count(slots, &ISA.wb2?/1) > 1,
      do: err.("more than one late-write-back op per bundle (rule 5): ldc and heap ops share one wb2 turn")

    rw = Enum.map(slots, &ISA.regs/1)
    all_writes = Enum.flat_map(rw, &elem(&1, 1))

    if length(all_writes) != length(Enum.uniq(all_writes)),
      do: err.("two slots write the same register (rule 1)")

    # A slot reading its OWN written register is fine (read-old, write-new —
    # regfile read in decode, write at WB). The forbidden hazard is
    # CROSS-slot: reading what a different slot writes, which would need the
    # bypass network the barrel exists to delete.
    for {{reads, _}, i} <- Enum.with_index(rw),
        {{_, writes}, j} <- Enum.with_index(rw),
        i != j do
      case Enum.filter(reads, &(&1 in writes)) do
        [] ->
          :ok

        clash ->
          err.(
            "slot reads register(s) #{inspect(Enum.uniq(clash))} written by another slot in the same bundle — no bypass network exists (rule 1)"
          )
      end
    end

    :ok
  end

  defp check_fields!(slot, err) do
    regs_ok = fn slot ->
      {r, w} = ISA.regs(slot)
      Enum.each(r ++ w, fn reg ->
        unless is_integer(reg) and reg in 0..15,
          do: err.("register #{inspect(reg)} outside r0..r15 in #{inspect(slot)}")
      end)
    end

    regs_ok.(slot)

    case slot do
      {:ldi, _, imm} ->
        unless imm in @ldi_min..@ldi_max,
          do: err.("ldi immediate #{imm} outside signed 12 bits (use ldc)")

      {:arg, i, _} ->
        unless i in 0..15, do: err.("arg index #{i} outside 0..15")

      {:tset, _, i, _} ->
        unless i in 0..255, do: err.("tset index #{i} outside 0..255")

      {:tget, _, _, i} ->
        unless i in 0..255, do: err.("tget index #{i} outside 0..255")

      {:fget, _, _, i} ->
        unless i in 0..15, do: err.("fget index #{i} outside 0..15")

      {:mktup, _, arity} ->
        unless arity in 1..255, do: err.("tuple arity #{arity} outside 1..255")

      # a fun's captured variables ride the object's words after
      # `funinfo`, and `tset`'s index ceiling in gates is 15, so a
      # closure captures at most 14 (`notes/42`)
      {:mkfun, _, f, nfree} ->
        unless is_atom(f) or is_integer(f),
          do: err.("mkfun target must be a function name or a pool index")

        unless nfree in 0..14, do: err.("mkfun nfree #{nfree} outside 0..14")

      {:callfun, _, _, arity} ->
        unless arity in 0..15, do: err.("callfun arity #{arity} outside 0..15")

      {:istag, _, _, tag} ->
        unless is_atom(tag), do: err.("istag tag must be a tag name atom")

      _ ->
        :ok
    end
  end

  defp resolve_label(slot, labels, fun) do
    fix = fn label ->
      case Map.fetch(labels, label) do
        {:ok, idx} -> idx
        :error -> raise Error, message: "#{fun}: undefined label #{inspect(label)}"
      end
    end

    case slot do
      {:jmp, l} when is_atom(l) -> {:jmp, fix.(l)}
      {op, a, b, l} when op in [:beq, :bne, :blt, :bge] and is_atom(l) -> {op, a, b, fix.(l)}
      {op, s, l} when op in [:bift, :biff] and is_atom(l) -> {op, s, fix.(l)}
      {:recv_peek, rd, l} when is_atom(l) -> {:recv_peek, rd, fix.(l)}
      {:try_begin, rd, l} when is_atom(l) -> {:try_begin, rd, fix.(l)}
      {:recv_waitt, rt, l} when is_atom(l) -> {:recv_waitt, rt, fix.(l)}
      other -> other
    end
  end
end
