defmodule PicoBEAM.Link do
  @moduledoc """
  The incremental linker: code loaded into a RUNNING machine.

  `Encoding.image/2` links one flat program once, before boot. This links
  more code into the same address space afterwards, against what is
  already there, and says which code-memory bundles and literal-pool
  words to write. Nothing here talks to hardware: the caller writes
  `writes` in order through the hot-load port (`Xc7M5Top`, CTRL2 op 0
  with bit 29) and both engines take every write.

  ## Export trampolines

  Calls and spawns carry absolute bundle addresses, patched at link time.
  A module loaded here gets one `jmp` bundle per export, its trampoline,
  and a call from anywhere else (`remote: true` code, `PicoBEAM.Erl`)
  targets the trampoline rather than the function. Loading a new version
  places the new code at fresh addresses and then rewrites the
  trampolines, last, one bundle each: a process that next makes a
  fully qualified call reaches the new version, a local call stays in the
  version it is running, and nothing is ever patched in place. That is
  Erlang's rule, and the whole module base table it was going to take
  (notes, 11-02) turns out to be one `jmp` per export.

  Old versions are not purged: code memory is a bump allocator. 512
  bundles is small, so shell lines do not bump; see `link_line/3`.

  ## State

  The atom table and the literal pool are machine-global, and so is this
  state: start it from the boot image with `from_image/2` and thread it
  through every link.
  """

  import Bitwise

  alias PicoBEAM.{Encoding, Erl, Term}

  defmodule Error do
    defexception [:message]
  end

  @code_depth 512
  @pool_depth 256

  defstruct code_next: 0,
            scratch: {416, 512},
            pool: %{},
            pool_next: 0,
            atoms: [],
            exports: %{},
            modules: %{},
            version: 0

  @doc """
  Link state for a machine booted from `img` (`Encoding.image/2`):
  everything the image occupies is taken. `scratch:` is the region shell
  lines are linked into, `{first, limit}`, default the top 96 bundles.
  """
  def from_image(img, opts \\ []) do
    {first, limit} = Keyword.get(opts, :scratch, {416, @code_depth})
    used = length(img.image)

    if used > first do
      raise Error, message: "boot image is #{used} bundles; scratch starts at #{first}"
    end

    %__MODULE__{
      code_next: used,
      scratch: {first, limit},
      pool: img.pool |> Enum.with_index() |> Map.new(),
      pool_next: length(img.pool),
      atoms: img.atoms
    }
  end

  @doc "Free bundles below the scratch region."
  def free(%__MODULE__{code_next: n, scratch: {first, _}}), do: first - n

  @doc """
  Link a module (`%{module:, program:, exports:}` from
  `PicoBEAM.Ex.compile_modules/2`). Returns `{state, writes, info}`;
  `writes` is `[{:pool, idx, word36} | {:code, addr, bundle72}]` in the
  order they must land, trampolines last.
  """
  def link_module(%__MODULE__{} = st, %{module: mod, program: prog, exports: exports}) do
    # functions first, then any NEW trampolines after them; an export
    # that already has one keeps it, which is what makes this an upgrade
    names = prog |> Map.keys() |> Enum.sort()
    {bases, after_code} = place(prog, names, st.code_next)

    {tramps, code_end} =
      Enum.reduce(exports, {[], after_code}, fn {f, a}, {acc, next} ->
        ext = Erl.remote_name(mod, f, a)

        case Map.fetch(st.exports, ext) do
          {:ok, addr} -> {[{ext, addr, Erl.fname(f, a)} | acc], next}
          :error -> {[{ext, next, Erl.fname(f, a)} | acc], next + 1}
        end
      end)

    {first, _} = st.scratch

    if code_end > first do
      raise Error,
        message:
          "#{inspect(mod)} needs #{code_end - st.code_next} bundles; " <>
            "#{first - st.code_next} free below the scratch region"
    end

    for {_ext, _addr, local} <- tramps, not Map.has_key?(bases, local) do
      raise Error, message: "#{inspect(mod)} exports #{local} but does not define it"
    end

    # the module's own trampolines resolve its own remote calls too
    exports_now =
      Enum.reduce(tramps, st.exports, fn {ext, addr, _}, m -> Map.put(m, ext, addr) end)

    st = %{st | exports: exports_now}
    {st, pool_w, code_w} = emit(st, prog, names, bases)

    tramp_w =
      for {_ext, addr, local} <- Enum.reverse(tramps),
          do: {:code, addr, jmp(Map.fetch!(bases, local))}

    version = st.version + 1
    start = st.code_next

    st = %{
      st
      | code_next: code_end,
        version: version,
        modules: Map.put(st.modules, mod, %{version: version, bases: bases, exports: exports})
    }

    info = %{module: mod, version: version, span: {start, code_end}, bases: bases}
    {st, pool_w ++ code_w ++ tramp_w, info}
  end

  @doc """
  Link a shell line: a module whose `entry` (default `:"run/1"`) the
  resident evaluator reaches through its line trampoline at `tramp`.

  A line with no closures is linked into the scratch region and the next
  line overwrites it: once the evaluator has its answer nothing can still
  be running that code or hold a pointer into it (a spawn goes through a
  trampoline, and a line has none). A line that makes a fun (`mkfun`)
  can leave a pointer into itself in a binding, so it is bump-allocated
  like a module and never reused. `scratch: false` forces that, and so
  does a line too big for the scratch region.

  Returns `{state, writes, entry_addr}`, the trampoline write last.
  """
  def link_line(%__MODULE__{} = st, %{program: prog}, tramp, opts \\ []) do
    entry = Keyword.get(opts, :entry, :"run/1")
    names = [entry | prog |> Map.keys() |> Enum.reject(&(&1 == entry)) |> Enum.sort()]
    closures? = Enum.any?(slots(prog), &match?({:mkfun, _, _, _}, &1))
    {first, limit} = st.scratch
    size = prog |> Map.values() |> Enum.map(&tuple_size(&1.code)) |> Enum.sum()

    scratch? =
      Keyword.get(opts, :scratch, true) and not closures? and size <= limit - first

    start = if scratch?, do: first, else: st.code_next
    {bases, code_end} = place(prog, names, start)

    if not scratch? and code_end > first do
      raise Error, message: "line needs #{size} bundles; #{first - start} free"
    end

    {st, pool_w, code_w} = emit(st, prog, names, bases)
    st = if scratch?, do: st, else: %{st | code_next: code_end}
    addr = Map.fetch!(bases, entry)
    {st, pool_w ++ code_w ++ [{:code, tramp, jmp(addr)}], addr}
  end

  @doc "The trampoline bundle: `jmp addr` alone."
  def jmp(addr), do: Encoding.encode_bundle({{:jmp, addr}, {:nop}, {:nop}})

  @doc "Index of `atom` in the machine's table (raises if it was never linked)."
  def atom_index(%__MODULE__{atoms: atoms}, atom), do: Encoding.atom_index(atom, atoms)

  @doc "The atom an index names."
  def atom_name(%__MODULE__{atoms: atoms}, idx) do
    reserved = Term.reserved_atoms()
    n = length(reserved)
    if idx < n, do: Enum.at(reserved, idx), else: Enum.at(atoms, idx - n)
  end

  @doc "Intern atoms (a term about to be sent may name new ones)."
  def intern(%__MODULE__{} = st, names) do
    reserved = Term.reserved_atoms()
    new = names |> Enum.reject(&(&1 in reserved or &1 in st.atoms)) |> Enum.uniq()
    %{st | atoms: st.atoms ++ new}
  end

  # ---------------------------------------------------------------------------

  defp place(prog, names, start) do
    Enum.reduce(names, {%{}, start}, fn f, {bases, addr} ->
      {Map.put(bases, f, addr), addr + tuple_size(Map.fetch!(prog, f).code)}
    end)
  end

  defp slots(prog) do
    prog
    |> Map.values()
    |> Enum.flat_map(fn %{code: code} ->
      code |> Tuple.to_list() |> Enum.flat_map(&Tuple.to_list/1)
    end)
  end

  # atoms, then pool, then every bundle patched and encoded
  defp emit(st, prog, names, bases) do
    all = slots(prog)

    st =
      intern(st, for(s <- all, a = slot_atom(s), do: a))

    resolve = fn f ->
      case Map.fetch(bases, f) do
        {:ok, addr} ->
          addr

        :error ->
          case Map.fetch(st.exports, f) do
            {:ok, addr} -> addr
            :error -> raise Error, message: "undefined function #{f} (not loaded)"
          end
      end
    end

    values =
      all
      |> Enum.flat_map(fn
        {:ldc, _rd, v} -> [pool_word(v)]
        {:mkfun, _rd, f, nfree} when is_atom(f) -> [funinfo(prog, bases, f, nfree)]
        _ -> []
      end)
      |> Enum.uniq()

    {st, pool_w} =
      Enum.reduce(values, {st, []}, fn w, {st, acc} ->
        case Map.fetch(st.pool, w) do
          {:ok, _} ->
            {st, acc}

          :error ->
            if st.pool_next >= @pool_depth do
              raise Error, message: "literal pool full (#{@pool_depth})"
            end

            {%{st | pool: Map.put(st.pool, w, st.pool_next), pool_next: st.pool_next + 1},
             [{:pool, st.pool_next, w} | acc]}
        end
      end)

    code_w =
      Enum.flat_map(names, fn f ->
        base = Map.fetch!(bases, f)

        prog
        |> Map.fetch!(f)
        |> Map.fetch!(:code)
        |> Tuple.to_list()
        |> Enum.with_index()
        |> Enum.map(fn {{a, b, c}, i} ->
          p = &patch(&1, base, resolve, st, prog, bases)
          {:code, base + i, Encoding.encode_bundle({p.(a), p.(b), p.(c)})}
        end)
      end)

    {st, Enum.reverse(pool_w), code_w}
  end

  defp slot_atom({:lda, _rd, name}) when is_atom(name), do: name
  defp slot_atom({:fail, reason}) when is_atom(reason), do: reason
  defp slot_atom(_), do: nil

  # the same rewrites as `Encoding.image/2`, against this state
  defp patch(slot, base, resolve, st, prog, bases) do
    case slot do
      {:ldc, rd, v} -> {:ldc, rd, Map.fetch!(st.pool, pool_word(v))}
      {:lda, rd, name} when is_atom(name) -> {:lda, rd, atom_index(st, name)}
      {:fail, reason} when is_atom(reason) -> {:fail, atom_index(st, reason)}
      {:mkfun, rd, f, nfree} when is_atom(f) ->
        {:mkfun, rd, Map.fetch!(st.pool, funinfo(prog, bases, f, nfree)), nfree}

      {:jmp, t} when is_integer(t) -> {:jmp, t + base}
      {:bift, rs, t} -> {:bift, rs, t + base}
      {:biff, rs, t} -> {:biff, rs, t + base}
      {:recv_peek, rd, t} -> {:recv_peek, rd, t + base}
      {:try_begin, rd, t} when is_integer(t) -> {:try_begin, rd, t + base}
      {:recv_waitt, rt, t} -> {:recv_waitt, rt, t + base}
      {:call, rd, f, a} when is_atom(f) -> {:call, rd, resolve.(f), a}
      {:tailcall, f, a} when is_atom(f) -> {:tailcall, resolve.(f), a}
      {:spawn, rd, f, a} when is_atom(f) -> {:spawn, rd, resolve.(f), a}
      other -> other
    end
  end

  defp pool_word(v) when is_integer(v) and v >= 0 and v < 1 <<< 36, do: v
  defp pool_word(v) when is_integer(v), do: Term.int(v)
  defp pool_word({:atom, i}), do: Term.atom(i)
  defp pool_word({:raw, w}) when is_integer(w) and w >= 0 and w < 1 <<< 36, do: w

  # a closure's target is always a function of the same unit (a lifted
  # fun), never a remote one
  defp funinfo(prog, bases, f, nfree) do
    case Map.fetch(prog, f) do
      {:ok, %{arity: total}} when total >= 1 ->
        Term.funinfo(Map.fetch!(bases, f), total - 1, nfree)

      _ ->
        raise Error, message: "mkfun target #{inspect(f)} is not in this unit"
    end
  end
end
