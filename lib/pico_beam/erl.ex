defmodule PicoBEAM.Erl do
  @moduledoc """
  The Core Erlang front end: Erlang source in, contract-checked picoBEAM
  bundles out. This is what turns the machine from hand-assembled into an
  Erlang one.

  The front end leans on the real toolchain: `:compile.file/2` with
  `[:to_core, :binary]` hands us the cerl AST erlc itself produces, so
  parsing, macro expansion and core simplification are inherited, and this
  module is ONLY a cerl -> bundle translator. Output goes through
  `PicoBEAM.Asm.assemble/1`, so every emitted bundle passes the same
  contract checks hand-written code does.

  ## The v1 subset (unsupported constructs raise CompileError, loudly)

  * modules, functions, tail and non-tail local calls (f/N mangled to
    `:"f/N"`; multi-head functions arrive from erlc as a case over values
    and are supported)
  * `let`, `seq`, `case` (literal/var/alias/cons/tuple patterns, `true`
    guards plus simple value guards), `receive` with selective matching
    and integer timeouts
  * integers, atoms, nil, cons, tuples; fixnum arithmetic and comparisons
  * `spawn(Mod, F, [SyntacticArgs])`, `!`, `self/0`, `link/1`, `unlink/1`,
    `monitor(process, Pid)`, `exit/2`, `process_flag(trap_exit, Bool)`,
    `hd/1`, `tl/1`, `element(LitN, T)`, `is_integer/atom/tuple/pid`,
    `erlang:mulsr(A, B, LitK)` — fixed-point multiply-then-shift,
    `erlang:yield/0`, `erlang:display/1` (-> the model's `out` port),
    `erlang:halt/0`
  * NOT in v1: funs as values, letrec (list comprehensions), try/catch,
    floats, bignums, maps, binaries, strings-as-anything-but-int-lists —
    per the charter's out-list.

  ## Codegen shape (deliberately naive)

  One op per bundle, linear single-assignment register allocation, no slot
  packing — the 3-slot scheduler is M2b's measured experiment, and a naive
  baseline is exactly what it should be measured against. Register windows
  make the 16-register budget per-FUNCTION, which small Erlang functions
  fit; blowing it raises CompileError (v1 limitation, not a design).
  """

  alias PicoBEAM.Asm

  defmodule CompileError do
    defexception [:message]
  end

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  @doc "Compile Erlang source text (must contain -module(...)) to an assembled program."
  def compile(source) when is_binary(source) do
    [_, mod] =
      Regex.run(~r/-module\(([a-z][A-Za-z0-9_]*)\)/, source) ||
        raise CompileError, message: "source has no -module(...) attribute"

    dir = Path.join(System.tmp_dir!(), "pico_beam_erl_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{mod}.erl")
    File.write!(path, source)

    try do
      compile_file(path)
    after
      File.rm_rf(dir)
    end
  end

  @doc "Compile a .erl file to an assembled program."
  def compile_file(path) do
    base = path |> Path.rootname() |> String.to_charlist()

    case :compile.file(base, [:to_core, :binary, :return_errors, :nowarn_unused_vars]) do
      {:ok, mod, core} -> translate(core, mod)
      {:ok, mod, core, _warnings} -> translate(core, mod)
      {:error, errors, _warnings} -> raise CompileError, message: "erlc: #{inspect(errors)}"
    end
  end

  @doc "The name-mangling convention: f/A -> :\"f/A\"."
  def fname(f, a), do: :"#{f}/#{a}"

  # A prelude, written in Erlang, because in a real BEAM `lists.erl` IS
  # Erlang — there is nothing primitive about `reverse/1`. Compiling it
  # alongside the user's module and lifting only the functions actually
  # called keeps images small and keeps the semantics honest: these are
  # the real definitions, not a hardware approximation of them.
  #
  # `tailcall` is what makes them usable: every one below is tail
  # recursive or ends in one, so they run in constant stack.
  #
  # Higher-order functions are HERE now: `notes/42` gave the machine fun
  # values, and `map/2`, `filter/2` and `foldl/3` were the debt that
  # bought. They are the ordinary definitions; what changed underneath
  # is that `F(X)` compiles to a `callfun` rather than to an error.
  #
  # The map functions are here rather than in gates for the same reason
  # the list ones are. `mkmap`, `tset` and `mapat` are the primitives; a
  # linear probe over at most thirty-two pairs is a loop, and a loop is
  # something this machine can already run. A one-probe-per-cycle scan
  # FSM would be about thirty times faster and is not the version to
  # write first.
  #
  # `erlang:mapat/2` is spelled as an erlang: call because there is no
  # operator for it — the same surface `mulsr` uses.
  @erlang_prelude %{
    {:map_size, 1} => :map_size,
    {:map_get, 2} => :map_get,
    {:is_map_key, 2} => :map_is_key,
    {:binary_to_list, 1} => :bin_to_list,
    {:list_to_binary, 1} => :list_to_bin,
    {:iolist_to_binary, 1} => :list_to_bin
  }

  # `binary:` and the string operators. `<>` reaches Core as
  # `erlang:bit_size`-guarded binary construction in general, but the
  # two-operand concatenation Elixir emits for `a <> b` on plain binaries
  # is `binary:copy`-shaped and resolves here (`notes/43`).
  @binary_prelude %{
    {:concat, 2} => :bin_concat,
    {:at, 2} => :bin_at,
    {:size, 1} => :bin_size
  }

  @maps_prelude %{
    {:size, 1} => :map_size,
    {:get, 2} => :map_get,
    {:find, 2} => :map_find,
    {:is_key, 2} => :map_is_key,
    {:put, 3} => :map_put,
    {:keys, 1} => :map_keys,
    {:values, 1} => :map_values,
    {:from_list, 1} => :map_from_list,
    {:update, 3} => :map_update,
    {:new, 0} => :map_new
  }

  @prelude """
  -module(pb_prelude).
  -export([reverse/1, reverse/2, append/2, length/1, member/2, nth/2,
           sum/1, seq/2, seq/3, last/1,
           map/2, filter/2, foldl/3, foreach/2, all/2, any/2,
           map_size/1, map_get/2, map_find/2, map_is_key/2,
           map_put/3, map_update/3, map_new/0, map_keys/1, map_values/1,
           map_from_list/1,
           bin_at/2, bin_size/1, bin_concat/2, bin_to_list/1, list_to_bin/1,
           bin_eq/2, bin_copy/4, bin_from/2]).

  reverse(L) -> reverse(L, []).
  reverse([], A) -> A;
  reverse([H|T], A) -> reverse(T, [H|A]).

  append([], L) -> L;
  append([H|T], L) -> [H|append(T, L)].

  length(L) -> len(L, 0).
  len([], N) -> N;
  len([_|T], N) -> len(T, N + 1).

  member(_, []) -> false;
  member(X, [X|_]) -> true;
  member(X, [_|T]) -> member(X, T).

  nth(1, [H|_]) -> H;
  nth(N, [_|T]) -> nth(N - 1, T).

  sum(L) -> sum(L, 0).
  sum([], A) -> A;
  sum([H|T], A) -> sum(T, A + H).

  seq(F, T) -> seq(F, T, 1).
  seq(F, T, _) when F > T -> [];
  seq(F, T, S) -> [F | seq(F + S, T, S)].

  last([X]) -> X;
  last([_|T]) -> last(T).

  map(_, []) -> [];
  map(F, [H|T]) -> [F(H) | map(F, T)].

  filter(_, []) -> [];
  filter(F, [H|T]) ->
      case F(H) of
          true -> [H | filter(F, T)];
          _    -> filter(F, T)
      end.

  foldl(_, A, []) -> A;
  foldl(F, A, [H|T]) -> foldl(F, F(H, A), T).

  foreach(_, []) -> ok;
  foreach(F, [H|T]) -> F(H), foreach(F, T).

  all(_, []) -> true;
  all(F, [H|T]) ->
      case F(H) of
          true -> all(F, T);
          _    -> false
      end.

  any(_, []) -> false;
  any(F, [H|T]) ->
      case F(H) of
          true -> true;
          _    -> any(F, T)
      end.

  %% ---- maps. Pair j is at indices 1 + 2j (key) and 2 + 2j (value);
  %% index 0 is the pair count. A probe is a linear walk, which is what
  %% a flatmap IS.
  %%
  %% Every one of these hands back an INDEX rather than a `{ok, V}`
  %% tuple, and the tuple is built once at the top if anyone wants it.
  %% Two reasons: a probe should not allocate, and a sixteen-register
  %% window does not have room for a loop that does.
  map_new() -> erlang:mkmap(0).

  map_size(M) -> erlang:mapat(M, 0).

  %% pair index of K, or -1
  mfind(K, M) -> mfind(K, M, erlang:mapat(M, 0), 0).
  mfind(_, _, N, N) -> -1;
  mfind(K, M, N, I) ->
      case erlang:mapat(M, 1 + 2 * I) of
          K -> I;
          _ -> mfind(K, M, N, I + 1)
      end.

  map_get(K, M) ->
      case mfind(K, M) of
          -1 -> erlang:error(badkey);
          I  -> erlang:mapat(M, 2 + 2 * I)
      end.

  map_find(K, M) ->
      case mfind(K, M) of
          -1 -> error;
          I  -> {ok, erlang:mapat(M, 2 + 2 * I)}
      end.

  map_is_key(K, M) ->
      case mfind(K, M) of
          -1 -> false;
          _  -> true
      end.

  %% Functional update: a fresh map every time, which is what BEAM does
  %% for a flatmap and the reason the collector had to come first.
  map_put(K, V, M) ->
      N = erlang:mapat(M, 0),
      case mfind(K, M, N, 0) of
          -1 -> mgrow(K, V, M, N, erlang:mkmap(N + 1), 0);
          J  -> mrepl(V, M, N, erlang:mkmap(N), J, 0)
      end.

  %% `%{M | K => V}` — the key must already be there, and BEAM says
  %% `badkey` when it is not. `map_put` would have added it.
  map_update(K, V, M) ->
      N = erlang:mapat(M, 0),
      case mfind(K, M, N, 0) of
          -1 -> erlang:error(badkey);
          J  -> mrepl(V, M, N, erlang:mkmap(N), J, 0)
      end.

  %% copy every pair, swapping the value at index J
  mrepl(_, _, N, R, _, N) -> R;
  mrepl(V, M, N, R, J, I) ->
      mcp(M, R, I),
      mval(V, M, R, J, I),
      mrepl(V, M, N, R, J, I + 1).


  mcp(M, R, I) -> erlang:mset(R, 1 + 2 * I, erlang:mapat(M, 1 + 2 * I)).

  mval(V, _M, R, I, I) -> erlang:mset(R, 2 + 2 * I, V);
  mval(_V, M, R, _J, I) -> mcv(M, R, I).

  %% append: the new pair goes last, so insertion order is the order
  mgrow(K, V, M, N, R, I) ->
      mcopyall(M, R, N, 0),
      erlang:mset(R, 1 + 2 * N, K),
      erlang:mset(R, 2 + 2 * N, V),
      R.

  mcopyall(_, R, N, N) -> R;
  mcopyall(M, R, N, I) ->
      mcp(M, R, I),
      mcv(M, R, I),
      mcopyall(M, R, N, I + 1).

  mcv(M, R, I) -> erlang:mset(R, 2 + 2 * I, erlang:mapat(M, 2 + 2 * I)).

  map_keys(M) -> mk(M, erlang:mapat(M, 0) - 1, []).
  mk(_, I, A) when I < 0 -> A;
  mk(M, I, A) -> mk(M, I - 1, [erlang:mapat(M, 1 + 2 * I) | A]).

  map_values(M) -> mv(M, erlang:mapat(M, 0) - 1, []).
  mv(_, I, A) when I < 0 -> A;
  mv(M, I, A) -> mv(M, I - 1, [erlang:mapat(M, 2 + 2 * I) | A]).

  map_from_list(L) -> mfl(L, erlang:mkmap(0)).
  mfl([], M) -> M;
  mfl([{K, V}|T], M) -> mfl(T, map_put(K, V, M)).

  %% ---- binaries. Byte i is at index 1 + i; index 0 is the byte count.
  %% Every one of these is byte-indexed, so none of them knows or cares
  %% how many bytes the store puts in a word.
  bin_size(B) -> erlang:binat(B, 0).

  bin_at(B, I) -> erlang:binat(B, 1 + I).

  %% copy N bytes of S starting at SI into D starting at DI
  bin_copy(_S, _D, _DI, 0) -> ok;
  bin_copy(S, D, DI, N) -> bcp(S, D, DI, N, 0).

  bcp(_S, _D, _DI, N, N) -> ok;
  bcp(S, D, DI, N, I) ->
      erlang:mset(D, 1 + DI + I, erlang:binat(S, 1 + I)),
      bcp(S, D, DI, N, I + 1).

  bin_concat(A, B) ->
      NA = erlang:binat(A, 0),
      NB = erlang:binat(B, 0),
      R = erlang:mkbin(NA + NB),
      bcp(A, R, 0, NA, 0),
      bcp(B, R, NA, NB, 0),
      R.

  %% the tail of B from byte I on. A COPY: this machine has no
  %% sub-binaries, so a match that binds `rest` allocates one.
  bin_from(B, I) ->
      N = erlang:binat(B, 0) - I,
      R = erlang:mkbin(N),
      bfr(B, R, I, N, 0),
      R.
  bfr(_, _, _, N, N) -> ok;
  bfr(B, R, I, N, J) ->
      erlang:mset(R, 1 + J, erlang:binat(B, 1 + I + J)),
      bfr(B, R, I, N, J + 1).

  bin_to_list(B) -> btl(B, erlang:binat(B, 0) - 1, []).
  btl(_, I, A) when I < 0 -> A;
  btl(B, I, A) -> btl(B, I - 1, [erlang:binat(B, 1 + I) | A]).

  %% `len/2` and not `length/1`: erl_lint refuses a local call to a name
  %% that is an auto-imported BIF, and the prelude's `length/1` is one.
  list_to_bin(L) ->
      R = erlang:mkbin(len(L, 0)),
      ltb(L, R, 0).
  ltb([], R, _) -> R;
  ltb([H|T], R, I) ->
      erlang:mset(R, 1 + I, H),
      ltb(T, R, I + 1).

  bin_eq(A, B) ->
      NA = erlang:binat(A, 0),
      case erlang:binat(B, 0) of
          NA -> beq(A, B, NA, 0);
          _  -> false
      end.
  beq(_, _, N, N) -> true;
  beq(A, B, N, I) ->
      case erlang:binat(A, 1 + I) of
          X -> case erlang:binat(B, 1 + I) of
                   X -> beq(A, B, N, I + 1);
                   _ -> false
               end
      end.
  """

  # The prelude's Core Erlang, compiled once per VM and cached: it is the
  # same source every time and `erlc` is not cheap.
  defp prelude_defs do
    case :persistent_term.get({__MODULE__, :prelude}, nil) do
      nil ->
        dir = Path.join(System.tmp_dir!(), "pb_prelude_#{:erlang.phash2(@prelude)}")
        File.mkdir_p!(dir)
        path = Path.join(dir, "pb_prelude.erl")
        File.write!(path, @prelude)

        {:ok, _mod, core} =
          :compile.file(String.to_charlist(Path.rootname(path)),
            [:to_core, :binary, :return_errors, :nowarn_unused_vars])

        {:c_module, _, _, _, _, defs} = core

        map =
          for {{:c_var, _, {f, a}}, {:c_fun, _, vars, body}} <- defs,
              f != :module_info,
              into: %{} do
            {{f, a}, {vars, body}}
          end

        :persistent_term.put({__MODULE__, :prelude}, map)
        map

      map ->
        map
    end
  end

  # ---------------------------------------------------------------------------
  # Module translation
  # ---------------------------------------------------------------------------

  @doc """
  Compile a Core Erlang module — however it was produced.

  `compile_file/1` gets its Core from `erlc`; `PicoBEAM.Ex` gets it from
  the Elixir compiler by way of `:elixir_erl.debug_info/4`. Both arrive
  here, because Core Erlang is the language this front end actually
  compiles and neither Erlang nor Elixir is.

  `skip` names functions to leave out — Elixir's `__info__/1` is
  reflection over maps and keyword lists, and this machine has neither.
  """
  def translate_core(core, mod, skip \\ [], opts \\ []) do
    # `remote: true` is the hot-loading link model (`PicoBEAM.Link`): a
    # call to ANOTHER module, and a fully qualified call to this one, is
    # emitted against the external name `:"Mod:f/A"` instead of being
    # refused or folded into a local call. The linker resolves it to that
    # function's export trampoline, so it always reaches the current
    # version (Erlang's rule: local calls stay, remote calls go current).
    # Without it, nothing changes: one module, one flat image.
    #
    # A process flag rather than a field threaded through every
    # `compile_fun` and `lift_and_compile` call: the flag is read once
    # per function, when its state is made, and cleared on the way out.
    previous = Process.put(:pico_beam_erl_remote, Keyword.get(opts, :remote, false))

    try do
      translate(core, mod, skip)
    after
      Process.put(:pico_beam_erl_remote, previous)
    end
  end

  @doc "The external name of `Mod:f/A`, as `remote: true` code calls it."
  def remote_name(mod, f, a), do: :"#{mod}:#{f}/#{a}"

  defp translate({:c_module, _, _name, _exports, _attrs, defs}, mod, skip \\ []) do
    funs =
      for {{:c_var, _, {f, a}}, {:c_fun, _, vars, body}} <- defs,
          f != :module_info,
          not ({f, a} in skip) do
        {f, a, vars, body}
      end

    # A worklist, not a map comprehension: compiling a function can
    # DISCOVER functions. A list comprehension is a `letrec` whose fun
    # this compiler lifts to top level, and that fun may contain another
    # comprehension. Compile until nothing new appears.
    prog = lift_and_compile(funs, mod, %{}, %{})

    Asm.assemble(prog)
  end

  defp compile_fun(f, a, vars, body, mod, lifted \\ %{}, frees \\ []) do
    vars_map =
      vars
      |> Enum.with_index()
      |> Map.new(fn {{:c_var, _, name}, i} -> {name, i} end)

    st = %{
      vars: vars_map,
      next: a,
      # Liveness-based register recycling (`notes/50`, entry 22).
      # `uses` is the per-variable occurrence count from one prepass over
      # the body; a variable's register is released when its count hits
      # zero. `free` is the pool; `rc` counts live bindings per register
      # (aliases: `let x = y`); `pend` holds released registers whose
      # last consuming instruction may not be emitted yet — they move to
      # `free` only at a statement boundary (`reap`). `hold` suppresses
      # reaping inside loops, where instruction order and execution
      # order disagree. Pattern tests allocate bump-only (see
      # `compile_clauses`), which is what protects the scrutinee — a
      # register later clauses read without a variable occurrence.
      uses: count_uses(body),
      free: [],
      rc: %{},
      pend: [],
      hold: 0,
      out: [],
      lbl: 0,
      mod: mod,
      remote: Process.get(:pico_beam_erl_remote, false) == true,
      fun: {f, a},
      letrecs: %{},
      peek_reg: nil,
      # letrec funs LIFTED to top level, and the ones this function
      # discovered on the way. See the general `c_letrec` clause.
      lifted: lifted,
      extra: []
    }

    # A LIFTED CLOSURE takes the closure object as its last parameter and
    # unpacks what it captured before anything else runs (`notes/42`).
    # `fget rj, rclos, 1 + j` is the exact mirror of the `tset rd, 1 + j`
    # the capture site emitted, and once the prologue has run the free
    # variables are ordinary registers — so nothing downstream of here
    # knows it is compiling a closure.
    clos_reg = length(vars) - 1

    st =
      frees
      |> Enum.with_index()
      |> Enum.reduce(st, fn {name, j}, st ->
        {r, st} = new_reg(st)
        st = emit(st, {:fget, r, clos_reg, 1 + j})
        %{st | vars: Map.put(st.vars, name, r)}
      end)

    {_r, st} = expr(body, st, :tail)
    {Enum.reverse(st.out), st.extra, st.lifted}
  end

  # Every variable a Core Erlang tree MENTIONS. `erlc` alpha-renames, so
  # every binder in the module has a unique name and a mention is either
  # of something bound inside this subtree or of something in the
  # enclosing scope — never both. That makes "free variables" simply
  # "mentioned here and in scope out there", with no binder analysis at
  # all, and it is exact for compiler output rather than an
  # approximation of a general rule.
  # A variable's NAME in erlc's Core is an integer, not an atom — the
  # alpha-renamer numbers them. `{f, a}` in the same position is a
  # function reference and is not a variable at all.
  defp plain_var?(name), do: is_atom(name) or is_integer(name)

  defp mentioned_vars({:c_var, _, name}), do: if(plain_var?(name), do: [name], else: [])
  defp mentioned_vars(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.flat_map(&mentioned_vars/1)
  defp mentioned_vars(l) when is_list(l), do: Enum.flat_map(l, &mentioned_vars/1)
  defp mentioned_vars(_), do: []

  defp free_vars(body, st) do
    body
    |> mentioned_vars()
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(st.vars, &1))
    |> Enum.sort()
  end

  # a call into the prelude: register the function (and, transitively,
  # whatever it calls) as work to be compiled, then call it
  # ...and the same call with the arguments already in registers, which
  # is what a `c_map` fold has: it evaluated the key and the value
  # itself and is carrying the accumulator between iterations.
  defp prelude_call_regs(f, regs, st) do
    a = length(regs)
    target = fname(:"pb_prelude:#{f}", a)
    st = want_prelude(f, a, st)
    st = stage(st, regs)
    {rd, st} = new_reg(st)
    {rd, emit(st, {:call, rd, target, a})}
  end

  defp want_prelude(f, a, st) do
    if Map.has_key?(st.lifted, {:"pb_prelude:#{f}", a}) do
      st
    else
      {vars, body} = Map.fetch!(prelude_defs(), {f, a})

      %{
        st
        | lifted: Map.put(st.lifted, {:"pb_prelude:#{f}", a}, fname(:"pb_prelude:#{f}", a)),
          extra: st.extra ++ [{:"pb_prelude:#{f}", a, vars, body}]
      }
    end
  end

  defp prelude_call(f, args, st, mode) do
    a = length(args)
    target = fname(:"pb_prelude:#{f}", a)

    st = want_prelude(f, a, st)

    held(st, fn st ->
      {regs, st} =
        Enum.reduce(args, {[], st}, fn arg, {acc, st} ->
          {r, st} = expr(arg, st, :value)
          {[r | acc], st}
        end)

      st = stage(st, Enum.reverse(regs))

      case mode do
        :tail ->
          {:noreturn, emit(st, {:tailcall, target, a})}

        :value ->
          {rd, st} = new_reg(st)
          {rd, emit(st, {:call, rd, target, a})}
      end
    end)
  end

  defp in_prelude?(st) do
    st.fun |> elem(0) |> to_string() |> String.starts_with?("pb_prelude:")
  end

  defp lift_and_compile([], _mod, acc, _lifted), do: acc

  defp lift_and_compile([entry | rest], mod, acc, lifted) do
    # a lifted CLOSURE carries the free variables it must unpack; an
    # ordinary function carries none, and the four-tuple is what
    # everything before `notes/42` produced
    {f, a, vars, body, frees} =
      case entry do
        {f, a, vars, body} -> {f, a, vars, body, []}
        {f, a, vars, body, frees} -> {f, a, vars, body, frees}
      end

    key = fname(f, a)

    if Map.has_key?(acc, key) do
      lift_and_compile(rest, mod, acc, lifted)
    else
      {bundles, extra, lifted2} = compile_fun(f, a, vars, body, mod, lifted, frees)
      acc = Map.put(acc, key, {a, bundles})
      lift_and_compile(rest ++ extra, mod, acc, lifted2)
    end
  end

  # ---------------------------------------------------------------------------
  # Compile-state helpers
  # ---------------------------------------------------------------------------

  defp e(st, item), do: %{st | out: [item | st.out]}
  defp emit(st, op), do: e(st, [op])

  defp new_reg(%{free: [r | rest]} = st), do: {r, %{st | free: rest}}

  defp new_reg(st) do
    r = st.next

    if r > 15 do
      {f, a} = st.fun

      raise CompileError,
        message:
          "#{f}/#{a}: more than 16 LIVE values at one point (the window " <>
            "is 16 registers and recycling found nothing dead to reuse)" <>
            if(System.get_env("PB_REGDBG"),
              do:
                " [next=#{st.next} free=#{inspect(st.free)} pend=#{inspect(st.pend)} " <>
                  "hold=#{st.hold} " <>
                  "rc=#{inspect(st.rc)} vars=#{inspect(st.vars, limit: 30)} " <>
                  "uses_left=#{inspect(st.uses, limit: 30)}]",
              else: ""
            )
    end

    {r, %{st | next: r + 1}}
  end

  defp new_label(st), do: {:"__L#{st.lbl}", %{st | lbl: st.lbl + 1}}

  defp bind(st, name, reg) do
    # rescue: the register may be pending (its old binding just died) or
    # even already free (a reap ran between) — binding it makes it live
    st = %{st | free: List.delete(st.free, reg), pend: List.delete(st.pend, reg)}
    %{st | vars: Map.put(st.vars, name, reg), rc: Map.update(st.rc, reg, 1, &(&1 + 1))}
  end

  # One textual occurrence of `name` has been compiled. When the count
  # hits zero the binding dies; when a register's last binding dies it
  # goes to `pend`. Unknown names are treated as immortal — the safe
  # direction is the leak, never the early free.
  defp consume(st, name) do
    case Map.fetch(st.uses, name) do
      {:ok, n} when n > 1 -> %{st | uses: Map.put(st.uses, name, n - 1)}
      {:ok, _} -> kill_binding(%{st | uses: Map.delete(st.uses, name)}, name)
      :error -> st
    end
  end

  defp kill_binding(st, name) do
    case Map.fetch(st.vars, name) do
      :error ->
        st

      {:ok, reg} ->
        case Map.get(st.rc, reg, 1) do
          n when n <= 1 ->
            st = %{st | rc: Map.delete(st.rc, reg)}
            if reg in st.pend, do: st, else: %{st | pend: [reg | st.pend]}

          n ->
            %{st | rc: Map.put(st.rc, reg, n - 1)}
        end
    end
  end

  # Statement boundary: pending registers become allocatable — their
  # consuming instructions are all emitted by now. No-op under `hold`
  # (loops, clause groups) and never releases a pinned register.
  defp reap(%{hold: h} = st) when h > 0, do: st
  defp reap(st), do: %{st | pend: [], free: st.pend ++ st.free}

  # Compile a subtree with reaping suspended: used for every clause that
  # evaluates SEVERAL expressions and consumes their registers in one
  # instruction at the end, and for loop bodies, where a register that
  # looks dead in the instruction stream is read again on the back edge.
  defp held(st, fun) do
    case fun.(%{st | hold: st.hold + 1}) do
      {:noreturn, st} -> {:noreturn, %{st | hold: st.hold - 1}}
      {r, st} -> {r, %{st | hold: st.hold - 1}}
    end
  end

  # The bulk rewind (`next` back to a low-water mark), free-list aware:
  # anything at or above the mark is reclaimed by the rewind itself, so
  # it must not ALSO sit in free/pend/rc.
  defp reset_next(st, n) do
    %{
      st
      | next: n,
        free: Enum.filter(st.free, &(&1 < n)),
        pend: Enum.filter(st.pend, &(&1 < n)),
        rc: st.rc |> Enum.reject(fn {r, _} -> r >= n end) |> Map.new()
    }
  end

  # ---------------------------------------------------------------------------
  # Use counting — one prepass per function (`notes/50`)
  #
  # Counts c_var occurrences the code generator will CONSUME. Binder
  # positions do not count (let vars, fun params, pattern binders); a
  # map-pattern KEY does, because `map_probe` reads it as a value.
  # Fun-reference vars ({f, a} names) are not registers. The fallback
  # for an unrecognised pattern node counts everything inside it — the
  # overcount direction, which leaks instead of freeing early.
  # ---------------------------------------------------------------------------

  defp count_uses(ast), do: cu(ast, %{})

  defp cu({:c_var, _, name}, acc) when is_atom(name) or is_integer(name),
    do: Map.update(acc, name, 1, &(&1 + 1))

  defp cu({:c_var, _, _fa}, acc), do: acc
  defp cu({:c_let, _, _vars, arg, body}, acc), do: cu(body, cu(arg, acc))
  defp cu({:c_fun, _, _vars, body}, acc), do: cu(body, acc)

  defp cu({:c_clause, _, pats, guard, body}, acc) do
    acc = Enum.reduce(pats, acc, &cup/2)
    cu(body, cu(guard, acc))
  end

  defp cu({:c_letrec, _, defs, body}, acc) do
    acc = Enum.reduce(defs, acc, fn {_v, f}, a -> cu(f, a) end)
    cu(body, acc)
  end

  defp cu(t, acc) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.reduce(acc, &cu/2)
  defp cu(l, acc) when is_list(l), do: Enum.reduce(l, acc, &cu/2)
  defp cu(_, acc), do: acc

  defp cup({:c_var, _, _}, acc), do: acc
  defp cup({:c_alias, _, _var, pat}, acc), do: cup(pat, acc)

  defp cup({:c_map, _, _arg, pairs, _}, acc),
    do: Enum.reduce(pairs, acc, fn {:c_map_pair, _, _op, k, v}, a -> cup(v, cu(k, a)) end)

  defp cup({:c_cons, _, h, t}, acc), do: cup(t, cup(h, acc))
  defp cup({:c_tuple, _, es}, acc), do: Enum.reduce(es, acc, &cup/2)
  defp cup({:c_binary, _, segs}, acc), do: Enum.reduce(segs, acc, &cup/2)
  defp cup({:c_bitstr, _, val, size, _u, _t, _f}, acc), do: cup(val, cu(size, acc))
  defp cup({:c_literal, _, _}, acc), do: acc
  defp cup(other, acc), do: cu(other, acc)

  defp unsupported(st, what) do
    {f, a} = st.fun
    raise CompileError, message: "#{f}/#{a}: unsupported Core Erlang construct: #{what}"
  end

  # Wrap a computed value for the requested mode.
  defp finish({r, st}, :value), do: {r, st}
  defp finish({r, st}, :tail), do: {:noreturn, emit(st, {:ret, r})}

  # ---------------------------------------------------------------------------
  # Expressions
  # ---------------------------------------------------------------------------

  defp expr({:c_literal, _, v}, st, mode), do: finish(load_literal(v, st), mode)

  defp expr({:c_var, _, {f, a}}, st, _mode), do: unsupported(st, "fun value #{f}/#{a}")

  defp expr({:c_var, _, name}, st, mode) do
    case Map.fetch(st.vars, name) do
      {:ok, r} -> finish({r, consume(st, name)}, mode)
      :error -> unsupported(st, "unbound variable #{inspect(name)}")
    end
  end

  defp expr({:c_seq, _, arg, body}, st, mode) do
    # the arg's value is discarded, so every register it allocated is dead:
    # full recycle (erlc's unique var names make stale vars-map entries inert)
    saved_next = st.next

    case expr(arg, st, :value) do
      {:noreturn, st} -> {:noreturn, st}
      {_r, st} -> expr(body, reap(reset_next(st, saved_next)), mode)
    end
  end

  # OTP >= 23 lowers `receive` to a letrec_goto over four primops. This
  # clause handles the two-value binder:
  #   let <PeekOk, Msg> = primop recv_peek_message()
  # which maps onto the hardware recv_peek: candidate found -> Msg + true,
  # none under the cursor -> false (Msg intentionally left unwritten — the
  # false arm never reads it, and the uninit fault would catch a compiler
  # that did).
  defp expr(
         {:c_let, _, [{:c_var, _, vok}, {:c_var, _, vmsg}],
          {:c_primop, _, {:c_literal, _, :recv_peek_message}, []}, body},
         st,
         mode
       ) do
    {rok, st} = new_reg(st)
    {rmsg, st} = new_reg(st)
    {none_lbl, st} = new_label(st)
    {done_lbl, st} = new_label(st)

    st =
      st
      |> emit({:recv_peek, rmsg, none_lbl})
      |> emit({:lda, rok, true})
      |> emit({:jmp, done_lbl})
      |> e(none_lbl)
      |> emit({:lda, rok, false})
      |> e(done_lbl)

    # `remove_message` has to write the REBUILT term back over this same
    # register: on the gates a peek only ever yields the head word, and
    # it is the take that runs the deserialiser. Remember which register
    # the peek bound so the take can target it.
    st = %{st | peek_reg: rmsg}

    expr(body, st |> bind(vok, rok) |> bind(vmsg, rmsg), mode)
  end

  defp expr({:c_let, _, [{:c_var, _, name}], arg, body}, st, mode) do
    # only the bound register survives the arg; deeper temporaries recycle
    saved_next = st.next

    case expr(arg, st, :value) do
      {:noreturn, st} ->
        {:noreturn, st}

      {r, st} ->
        st = reset_next(st, max(saved_next, r + 1))
        # a statement boundary: everything that died in the arg (and
        # before it) has had its last consumer emitted — release it
        expr(body, reap(bind(st, name, r)), mode)
    end
  end

  defp expr({:c_let, _, vars, _, _}, st, _mode),
    do: unsupported(st, "multi-value let (#{length(vars)} vars)")

  defp expr({:c_cons, _, h, t}, st, mode) do
    {rd, st} =
      held(st, fn st ->
        {rh, st} = expr(h, st, :value)
        {rt, st} = expr(t, st, :value)
        {rd, st} = new_reg(st)
        {rd, emit(st, {:cons, rd, rh, rt})}
      end)

    finish({rd, st}, mode)
  end

  # `<<a::binary, b::binary>>` — which is what `a <> b` is, and what
  # every Elixir string interpolation ends as. Each segment becomes a
  # binary and they are folded together with the prelude's concatenation
  # (`notes/43`).
  #
  # Two segment types, and they are the two Elixir actually emits for
  # plain strings: a whole binary, and a single byte. A size that is not
  # eight bits, a unit that is not one, a float or a bitstring that does
  # not end on a byte are refused rather than approximated — this machine
  # has binaries, not bitstrings.
  defp expr({:c_binary, _, segs}, st, mode) do
    {r, st} =
      held(st, fn st ->
        {regs, st} = Enum.map_reduce(segs, st, &segment_bin/2)

        case regs do
          [] ->
            {rz, st} = load_int(0, st)
            {rd, st} = new_reg(st)
            {rd, emit(st, {:mkbin, rd, rz})}

          [only] ->
            {only, st}

          [first | rest] ->
            Enum.reduce(rest, {first, st}, fn r, {acc, st} ->
              prelude_call_regs(:bin_concat, [acc, r], st)
            end)
        end
      end)

    finish({r, st}, mode)
  end

  defp segment_bin({:c_bitstr, _, val, _size, _unit, {:c_literal, _, :binary}, _}, st),
    do: expr(val, st, :value)

  defp segment_bin(
         {:c_bitstr, _, val, {:c_literal, _, 8}, {:c_literal, _, 1},
          {:c_literal, _, :integer}, _},
         st
       ) do
    {rv, st} = expr(val, st, :value)
    {rone, st} = load_int(1, st)
    {rd, st} = new_reg(st)
    st = emit(st, {:mkbin, rd, rone})
    {rd, emit(st, {:tset, rd, 1, rv})}
  end

  defp segment_bin(seg, st),
    do: unsupported(st, "binary segment #{inspect(seg, limit: 4)}")

  # `%{m | k => v}` and `maps:put/3`'s expansion both reach here as a
  # `c_map` over a BASE. `:exact` is the update form — the key must
  # already be there — and `:assoc` is put. Both are the prelude's, and
  # both are folded left so `%{m | a => 1, b => 2}` is two updates.
  defp expr({:c_map, _, arg, pairs, _is_pat}, st, mode) do
    {r, st} = held(st, fn st -> c_map_build(arg, pairs, st) end)
    finish({r, st}, mode)
  end

  defp c_map_build(arg, pairs, st) do
    {rbase, st} =
      case arg do
        {:c_literal, _, v} when is_map(v) and map_size(v) == 0 ->
          {rn, st} = load_int(0, st)
          {rd, st} = new_reg(st)
          {rd, emit(st, {:mkmap, rd, rn})}

        other ->
          expr(other, st, :value)
      end

    {racc, st} =
      Enum.reduce(pairs, {rbase, st}, fn {:c_map_pair, _, op, k, v}, {racc, st} ->
        f =
          case op do
            {:c_literal, _, :exact} -> :map_update
            _ -> :map_put
          end

        # the key and the value are dead the moment they are STAGED, so
        # the window is rewound before the result register is taken. A
        # chain of updates would otherwise spend two registers a link
        # and a sixteen-register window does not have many to spare.
        saved = st.next
        {rk, st} = expr(k, st, :value)
        {rv, st} = expr(v, st, :value)
        st = stage(st, [rk, rv, racc])
        st = want_prelude(f, 3, reset_next(st, saved))
        {rd, st} = new_reg(st)
        {rd, emit(st, {:call, rd, fname(:"pb_prelude:#{f}", 3), 3})}
      end)

    {racc, st}
  end

  defp expr({:c_tuple, _, es}, st, mode) do
    {rd, st} =
      held(st, fn st ->
        {regs, st} =
          Enum.reduce(es, {[], st}, fn el, {acc, st} ->
            {r, st} = expr(el, st, :value)
            {[r | acc], st}
          end)

        {rd, st} = new_reg(st)
        st = emit(st, {:mktup, rd, length(es)})

        st =
          regs
          |> Enum.reverse()
          |> Enum.with_index()
          |> Enum.reduce(st, fn {r, i}, st -> emit(st, {:tset, rd, i, r}) end)

        {rd, st}
      end)

    finish({rd, st}, mode)
  end

  # apply of a letrec_goto label: a jmp, in any mode
  # ---------------------------------------------------------------------------
  # Closures (`notes/42`)
  #
  # `fn x -> x + n end` reaches here as a bare `c_fun` in a value
  # position. It is lifted to a top-level function of arity
  # `length(vars) + 1` — the visible parameters, then the closure itself
  # — and what stands in its place is a heap object carrying the entry
  # and the captured variables.
  #
  # The captured variables are the ones the body mentions that are in
  # scope HERE. `erlc` alpha-renames, so that test is exact.
  # ---------------------------------------------------------------------------
  defp expr({:c_fun, _, vars, fbody}, st, mode) do
    frees = free_vars(fbody, st)
    {f, a} = st.fun
    lifted_name = :"#{f}/#{a}$fn#{length(st.extra)}"
    arity = length(vars) + 1

    # the closure rides as the LAST parameter, under a name no Core
    # Erlang tree can collide with
    clos_var = {:c_var, [], :"$clos"}

    st = %{st | extra: st.extra ++ [{lifted_name, arity, vars ++ [clos_var], fbody, frees}]}

    {rd, st} = new_reg(st)
    st = emit(st, {:mkfun, rd, fname(lifted_name, arity), length(frees)})

    st =
      frees
      |> Enum.with_index()
      |> Enum.reduce(st, fn {name, j}, st ->
        r = Map.fetch!(st.vars, name)
        # the capture is this variable's read on THIS path; the value
        # lives in the closure object from here on
        emit(consume(st, name), {:tset, rd, 1 + j, r})
      end)

    finish({rd, st}, mode)
  end

  # `f.(x)` — an apply whose operator is a plain variable holding a fun.
  # The closure itself is staged as the last argument and the callee
  # unpacks it; `callfun` checks the arity and the tag.
  defp expr({:c_apply, _, {:c_var, _, name} = op, args}, st, mode)
       when is_atom(name) or is_integer(name) do
    held(st, fn st -> apply_fun_var(op, args, st, mode) end)
  end

  defp apply_fun_var(op, args, st, mode) do
    {rf, st} = expr(op, st, :value)

    {regs, st} =
      Enum.reduce(args, {[], st}, fn arg, {acc, st} ->
        {r, st} = expr(arg, st, :value)
        {[r | acc], st}
      end)

    n = length(args)
    st = stage(st, Enum.reverse(regs))
    st = emit(st, {:arg, n, rf})

    {rd, st} = new_reg(st)
    st = emit(st, {:callfun, rd, rf, n})

    case mode do
      # `callfun` is a call and a call has no tail form here: the result
      # comes back through the ordinary return path and is returned on.
      :tail -> {:noreturn, emit(st, {:ret, rd})}
      _ -> finish({rd, st}, mode)
    end
  end

  defp expr({:c_apply, _, {:c_var, _, {f, 0}}, []}, %{letrecs: lr} = st, _mode)
       when is_map_key(lr, f) do
    {:noreturn, emit(st, {:jmp, Map.fetch!(lr, f)})}
  end

  # an apply of a LIFTED letrec fun is an ordinary call to the function
  # it was lifted into
  defp expr({:c_apply, _, {:c_var, _, {f, a}}, args}, %{lifted: lf} = st, mode)
       when is_map_key(lf, {f, a}) do
    target = Map.fetch!(lf, {f, a})
    saved = st.next
    st = %{st | hold: st.hold + 1}

    {regs, st} =
      Enum.reduce(args, {[], st}, fn arg, {acc, st} ->
        {r, st} = expr(arg, st, :value)
        {[r | acc], st}
      end)

    st = reset_next(stage(st, Enum.reverse(regs)), saved)
    st = %{st | hold: st.hold - 1}

    case mode do
      :tail ->
        {:noreturn, emit(st, {:tailcall, target, a})}

      :value ->
        {rd, st} = new_reg(st)
        {rd, emit(st, {:call, rd, target, a})}
    end
  end

  # a LOCAL apply inside a prelude function is a prelude call: while
  # compiling `pb_prelude:reverse/1`, `reverse/2` means the prelude's,
  # not one the user happens to have written
  defp expr({:c_apply, _, {:c_var, _, {f, a}}, args}, st, mode)
       when is_atom(f) do
    if in_prelude?(st) and is_map_key(prelude_defs(), {f, a}) do
      prelude_call(f, args, st, mode)
    else
      apply_local(f, a, args, st, mode)
    end
  end

  defp apply_local(f, a, args, st, mode) do
    held(st, fn st ->
      {regs, st} =
        Enum.reduce(args, {[], st}, fn arg, {acc, st} ->
          {r, st} = expr(arg, st, :value)
          {[r | acc], st}
        end)

      st = stage(st, Enum.reverse(regs))

      case mode do
        :tail ->
          {:noreturn, emit(st, {:tailcall, fname(f, a), a})}

        :value ->
          {rd, st} = new_reg(st)
          {rd, emit(st, {:call, rd, fname(f, a), a})}
      end
    end)
  end

  defp remote_call(mod, f, args, st, mode) do
    a = length(args)
    target = remote_name(mod, f, a)

    held(st, fn st ->
      {regs, st} =
        Enum.reduce(args, {[], st}, fn arg, {acc, st} ->
          {r, st} = expr(arg, st, :value)
          {[r | acc], st}
        end)

      st = stage(st, Enum.reverse(regs))

      case mode do
        :tail ->
          {:noreturn, emit(st, {:tailcall, target, a})}

        :value ->
          {rd, st} = new_reg(st)
          {rd, emit(st, {:call, rd, target, a})}
      end
    end)
  end

  defp expr({:c_apply, _, _op, _args}, st, _mode), do: unsupported(st, "apply of non-name")

  defp expr({:c_call, _, {:c_literal, _, mod}, {:c_literal, _, f}, args} = node, st, mode) do
    cond do
      mod == :erlang -> held(st, fn st -> builtin(f, args, st, mode, node) end)
      # Process.register/2 and friends are thin wrappers over the
      # erlang BIFs; Elixir does not inline them, so the front end does
      mod == Process and f in [:register, :whereis, :unregister] ->
        held(st, fn st -> builtin(f, args, st, mode, node) end)
      # hot-loading link model: a fully qualified call to this module
      # goes through its trampoline too (below), which is what lets a
      # running `loop/1` pick up a new version at its next
      # `Mod.loop(state)`. Inside the prelude it stays local.
      mod == st.mod and (not st.remote or in_prelude?(st)) ->
        expr({:c_apply, [], {:c_var, [], {f, length(args)}}, args}, st, mode)
      # `lists:` resolves against the prelude, and the function is lifted
      # into this image under a mangled name the same way a comprehension
      # is. Only what is CALLED gets compiled.
      mod == :lists and is_map_key(prelude_defs(), {f, length(args)}) ->
        prelude_call(f, args, st, mode)

      # `maps:` resolves against the prelude under a prefixed name, so
      # `maps:size/1` and a hypothetical `lists:size/1` cannot collide in
      # a table keyed by {name, arity}
      mod == :maps and is_map_key(@maps_prelude, {f, length(args)}) ->
        prelude_call(Map.fetch!(@maps_prelude, {f, length(args)}), args, st, mode)

      mod == :binary and is_map_key(@binary_prelude, {f, length(args)}) ->
        prelude_call(Map.fetch!(@binary_prelude, {f, length(args)}), args, st, mode)

      st.remote and not in_prelude?(st) -> remote_call(mod, f, args, st, mode)

      true -> unsupported(st, "remote call #{mod}:#{f}/#{length(args)}")
    end
  end

  defp expr({:c_case, _, arg, clauses}, st, mode) do
    {sregs, st} =
      case arg do
        {:c_values, _, es} ->
          held(st, fn st ->
            Enum.reduce(es, {[], st}, fn el, {acc, st} ->
              {r, st} = expr(el, st, :value)
              {acc ++ [r], st}
            end)
          end)

        single ->
          {r, st} = expr(single, st, :value)
          {[r], st}
      end

    compile_clauses(clauses, sregs, st, mode, :case_clause)
  end

  defp expr({:c_receive, _, clauses, timeout, action}, st, mode) do
    # the scan label below is a backward-jump target: hold, as the
    # letrec-goto form does
    st = %{st | hold: st.hold + 1}

    {rt, st} =
      case timeout do
        {:c_literal, _, :infinity} -> {nil, st}
        texpr -> expr(texpr, st, :value)
      end

    {scan_lbl, st} = new_label(st)
    {wait_lbl, st} = new_label(st)
    {done_info, st} = value_sink(st, mode)

    st = emit(st, {:recv_start})
    st = e(st, scan_lbl)
    {rc, st} = new_reg(st)
    st = emit(st, {:recv_peek, rc, wait_lbl})

    {st, _} =
      Enum.reduce(clauses, {st, 1}, fn {:c_clause, _, [pat], guard, body}, {st, n} ->
        {next_lbl, st} = new_label(st)
        # registers allocated inside a clause die with it: exactly one
        # clause executes per pass, so the next clause may reuse them
        saved_vars = st.vars
        saved_next = st.next
        saved_free = st.free
        st = pat_test(pat, rc, next_lbl, st)
        st = guard_test(guard, next_lbl, st)
        {rtaken, st} = new_reg(st)
        st = emit(st, {:recv_take, rtaken})
        st = exit_bound_body(body, st, mode, done_info)
        st = reset_next(%{st | vars: saved_vars}, saved_next)

        st = %{
          st
          | free:
              Enum.uniq(st.free ++ saved_free)
              |> Enum.reject(&Map.has_key?(st.rc, &1))
        }

        {e(st, next_lbl), n + 1}
      end)

    st = emit(st, {:recv_skip})
    st = emit(st, {:jmp, scan_lbl})
    st = e(st, wait_lbl)

    st =
      case rt do
        nil ->
          st |> emit({:recv_wait}) |> emit({:jmp, scan_lbl})

        rt ->
          {tmo_lbl, st} = new_label(st)
          st = st |> emit({:recv_waitt, rt, tmo_lbl}) |> emit({:jmp, scan_lbl})
          st = e(st, tmo_lbl)
          clause_body(action, st, mode, done_info)
      end

    st = %{st | hold: st.hold - 1}
    close_sink(st, mode, done_info)
  end

  # remove_message: take the peeked candidate off the mailbox (resets the
  # scan cursor, exactly BEAM's semantics); the value is unused.
  defp expr({:c_primop, _, {:c_literal, _, :remove_message}, []}, st, mode) do
    # The take's destination is the peek's register, not a scratch: the
    # peek left only the head word there, and the take is what rebuilds
    # the compound term. Writing anywhere else leaves the clause body
    # reading a bare flit. Falls back to a scratch if no peek preceded
    # (the older `c_receive` path, which fuses peek and take).
    case st.peek_reg do
      nil ->
        {junk, st} = new_reg(st)
        finish({junk, emit(st, {:recv_take, junk})}, mode)

      r ->
        finish({r, emit(st, {:recv_take, r})}, mode)
    end
  end

  # recv_next: candidate rejected, advance the cursor.
  defp expr({:c_primop, _, {:c_literal, _, :recv_next}, []}, st, mode) do
    st = emit(st, {:recv_skip})
    finish(load_literal(:ok, st), mode)
  end

  # recv_wait_timeout(T): block for an unseen message or the deadline.
  # Returns true if it TIMED OUT, false if a message arrived (BEAM's
  # convention). infinity never times out.
  defp expr({:c_primop, _, {:c_literal, _, :recv_wait_timeout}, [targ]}, st, mode) do
    {res, st} = new_reg(st)

    st =
      case targ do
        {:c_literal, _, :infinity} ->
          st |> emit({:recv_wait}) |> emit({:lda, res, false})

        {:c_literal, _, 0} ->
          unsupported(st, "receive after 0 (v1: timeout must be positive)")

        texpr ->
          {rt, st} = expr(texpr, st, :value)
          {tmo_lbl, st} = new_label(st)
          {done_lbl, st} = new_label(st)

          st
          |> emit({:recv_waitt, rt, tmo_lbl})
          |> emit({:lda, res, false})
          |> emit({:jmp, done_lbl})
          |> e(tmo_lbl)
          |> emit({:lda, res, true})
          |> e(done_lbl)
      end

    finish({res, st}, mode)
  end

  defp expr({:c_primop, _, {:c_literal, _, name}, args}, st, mode)
       when name in [:match_fail, :raise] do
    reason = extract_fail_reason(args)
    st = emit(st, {:fail, reason})
    # unreachable continuation value
    finish(load_literal(:ok, st), mode)
  end

  # letrec_goto with a single zero-arity fun: erlc's own annotation says
  # what it is — a label. The fun body is emitted once under a label; every
  # apply of it is a jmp; captured variables are just registers in the same
  # window. This is how `receive` arrives from OTP >= 23.
  defp expr({:c_letrec, _, [{{:c_var, _, {name, 0}}, {:c_fun, _, [], fbody}}], lbody}, st, mode) do
    {lbl, st} = new_label(st)
    st = %{st | letrecs: Map.put(st.letrecs, name, lbl)}
    {done_info, st} = value_sink(st, mode)

    # If this label IS a receive loop, the cursor has to be reset before
    # entering it. OTP >= 23 lowers `receive` to a letrec_goto over
    # primops and there is no primop for "start receiving" — the cursor
    # reset is implicit in BEAM and explicit here, so nothing in the
    # incoming tree asks for it and the loop peeked from wherever the
    # previous receive left off.
    #
    # The older `c_receive` clause below emits `recv_start` correctly and
    # is simply never reached on a modern erlc, which is why this went
    # unnoticed: the compiler had the right code on the dead path.
    st = if receive_loop?(fbody), do: emit(st, {:recv_start}), else: st

    st =
      case expr(lbody, st, mode_for_sink(mode)) do
        {:noreturn, st} -> st
        {r, st} -> sink_value(st, done_info, r)
      end

    st = e(st, lbl)

    # the label is a backward-jump target: on the next pass an
    # instruction emitted EARLIER in this body reads its registers
    # again, so nothing that dies inside it may be released until the
    # loop region is closed
    st = %{st | hold: st.hold + 1}

    st =
      case expr(fbody, st, mode_for_sink(mode)) do
        {:noreturn, st} -> st
        {r, st} -> sink_value(st, done_info, r)
      end

    st = %{st | hold: st.hold - 1}
    close_sink(st, mode, done_info)
  end

  # Does this letrec body contain the peek primop? That is what makes it
  # a receive rather than any other erlc-generated label.
  defp receive_loop?({:c_primop, _, {:c_literal, _, :recv_peek_message}, _}), do: true
  defp receive_loop?(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.any?(&receive_loop?/1)
  defp receive_loop?(l) when is_list(l), do: Enum.any?(l, &receive_loop?/1)
  defp receive_loop?(_), do: false

  # The general `letrec`: lift every fun in it to a top-level function.
  #
  # This is what a list comprehension is. `erlc` turns `[X + 1 || X <- L]`
  # into a `letrec` holding a self-recursive `lc$^0/1` that walks the
  # list, and applies it to `L`. That fun takes the list as its only
  # parameter and closes over nothing, so lifting it is exact rather
  # than an approximation — and `tailcall` already makes its recursion
  # run in constant stack.
  #
  # A letrec fun that DOES close over an enclosing variable is not
  # lifted correctly by this, and it does not pretend to be: the free
  # variable simply is not in scope in the lifted function and the
  # existing "unbound variable" error fires, naming it.
  defp expr({:c_letrec, _, defs, lbody}, st, mode) do
    {st, mapping} =
      Enum.reduce(defs, {st, %{}}, fn {{:c_var, _, {name, ar}}, {:c_fun, _, vars, fbody}},
                                      {st, map} ->
        {f, a} = st.fun
        lifted_name = :"#{f}/#{a}$#{name}"
        {st, Map.put(map, {name, ar}, {lifted_name, vars, fbody, ar})}
      end)

    # every fun in the letrec can see every other, and itself
    lifted =
      Enum.reduce(mapping, st.lifted, fn {{name, ar}, {ln, _, _, _}}, acc ->
        # the target is the MANGLED name with its arity, which is the key
        # `lift_and_compile/4` will file it under
        Map.put(acc, {name, ar}, fname(ln, ar))
      end)

    extra =
      Enum.map(mapping, fn {_, {ln, vars, fbody, ar}} -> {ln, ar, vars, fbody} end)

    st = %{st | lifted: lifted, extra: st.extra ++ extra}
    expr(lbody, st, mode)
  end

  # try Arg of <V> -> Body catch <Class, Reason, Stack> -> Handler
  #
  # `erlc` emits exactly this shape, and the protected expression is
  # usually a CALL — which is why the machine unwinds rather than just
  # redirecting a pc.
  #
  # The class/reason pair lands in two ADJACENT registers, because
  # `try_begin` names one and the machine writes rd and rd+1. Allocating
  # them together here is what makes that contract hold; the stacktrace
  # is bound to nil, which is honest — the machine does not keep one —
  # rather than left unbound, which would fault on a handler that
  # mentions it.
  defp expr({:c_try, _, arg, [{:c_var, _, vok}], body, evars, handler}, st, mode) do
    {rcls, st} = new_reg(st)
    {rrsn, st} = new_reg(st)
    {hand_lbl, st} = new_label(st)
    {done_lbl, st} = new_label(st)

    st = emit(st, {:try_begin, rcls, hand_lbl})

    # the protected expression, then the frame comes back off
    case expr(arg, st, :value) do
      {:noreturn, st} ->
        st = st |> e(hand_lbl) |> bind_evars(evars, rcls, rrsn)
        expr(handler, st, mode)

      {rv, st} ->
        st = emit(st, {:try_end})
        {rres, st} = new_reg(st)
        st = emit(st, {:mov, rres, rv})
        st = bind(st, vok, rv)

        {st, rbody} =
          case expr(body, st, :value) do
            {:noreturn, st2} -> {st2, rres}
            {rb, st2} -> {emit(st2, {:mov, rres, rb}), rres}
          end

        st =
          st
          |> emit({:jmp, done_lbl})
          |> e(hand_lbl)
          |> bind_evars(evars, rcls, rrsn)

        st =
          case expr(handler, st, :value) do
            {:noreturn, st2} -> st2
            {rh, st2} -> emit(st2, {:mov, rbody, rh})
          end

        st = e(st, done_lbl)
        finish({rres, st}, mode)
    end
  end

  defp expr({:c_try, _, _, _, _, _, _}, st, _mode),
    do: unsupported(st, "try/catch with a multi-value protected expression")

  # bind Core Erlang's <Class, Reason, Stack> to where the machine put
  # them. The stacktrace has nowhere to come from, so it is nil.
  defp bind_evars(st, evars, rcls, rrsn) do
    case evars do
      [{:c_var, _, c}, {:c_var, _, r}, {:c_var, _, s}] ->
        {rnil, st} = new_reg(st)
        st = emit(st, {:ldn, rnil})
        st |> bind(c, rcls) |> bind(r, rrsn) |> bind(s, rnil)

      [{:c_var, _, c}, {:c_var, _, r}] ->
        st |> bind(c, rcls) |> bind(r, rrsn)

      _ ->
        st
    end
  end

  defp expr(node, st, _mode), do: unsupported(st, inspect(node, limit: 4))

  # ---------------------------------------------------------------------------
  # case/receive clause plumbing
  # ---------------------------------------------------------------------------

  # In :value mode, all clause bodies converge into one result register and
  # one end label; in :tail mode each body terminates itself.
  defp value_sink(st, :tail), do: {nil, st}

  defp value_sink(st, :value) do
    {res, st} = new_reg(st)
    {endl, st} = new_label(st)
    {{res, endl}, st}
  end

  defp clause_body(body, st, :tail, nil) do
    {_r, st} = expr(body, st, :tail)
    st
  end

  defp clause_body(body, st, :value, {res, endl}) do
    case expr(body, st, :value) do
      # a letrec-goto body never falls through
      {:noreturn, st} -> st
      {r, st} -> st |> emit({:mov, res, r}) |> emit({:jmp, endl})
    end
  end

  # A receive's TAKEN body executes once, on the FINAL pass of the scan
  # loop, and then control leaves the loop — it is exit-bound. So the
  # loop hold is lifted inside it (recycling works), with one fence:
  # registers it frees must not reach LOOP-REGION allocations compiled
  # after it (a later clause's pattern temp is written on every pass,
  # and the pass after a body ran does not exist — but the pass after a
  # body was merely COMPILED does). Freed-inside registers therefore go
  # back to pending at exit, to flush only when the loop closes.
  defp exit_bound_body(body, st, mode, done_info) do
    saved_hold = st.hold
    saved_free = st.free
    st = clause_body(body, %{st | hold: 0}, mode, done_info)
    body_freed = Enum.reject(st.free, &(&1 in saved_free))
    kept = Enum.filter(st.free, &(&1 in saved_free))
    %{st | hold: saved_hold, free: kept, pend: Enum.uniq(st.pend ++ body_freed)}
  end

  defp takes_message?({:c_primop, _, {:c_literal, _, :remove_message}, _}), do: true

  defp takes_message?(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.any?(&takes_message?/1)

  defp takes_message?(l) when is_list(l), do: Enum.any?(l, &takes_message?/1)
  defp takes_message?(_), do: false

  defp close_sink(st, :tail, nil), do: {:noreturn, st}
  defp close_sink(st, :value, {res, endl}), do: {res, e(st, endl)}

  defp mode_for_sink(:tail), do: :tail
  defp mode_for_sink(:value), do: :value

  defp sink_value(st, nil, _r), do: st
  defp sink_value(st, {res, endl}, r), do: st |> emit({:mov, res, r}) |> emit({:jmp, endl})

  defp compile_clauses(clauses, sregs, st, mode, fail_reason) do
    {done_info, st} = value_sink(st, mode)

    # The scrutinee registers are read by every LATER clause's TESTS
    # with no variable occurrence to count. The invariant that protects
    # them: tests and guards allocate BUMP-ONLY (empty pool, reaping
    # suspended), so a register freed in an earlier clause's body can
    # never surface as a later clause's test temporary — the only
    # allocation that executes on the fall-through path. Bodies allocate
    # from the pool as usual: a body's instructions never execute on any
    # path where a later test still reads the scrutinee.
    st =
      Enum.reduce(clauses, st, fn {:c_clause, _, pats, guard, body}, st ->
        if length(pats) != length(sregs),
          do: unsupported(st, "clause arity mismatch")

        {next_lbl, st} = new_label(st)
        saved_vars = st.vars
        saved_next = st.next
        saved_free = st.free

        # tests + guard: bump-only, no reaping
        st = %{st | free: [], hold: st.hold + 1}

        st =
          Enum.zip(pats, sregs)
          |> Enum.reduce(st, fn {pat, sreg}, st -> pat_test(pat, sreg, next_lbl, st) end)

        st = guard_test(guard, next_lbl, st)
        # the restored pool must not resurrect a register the pattern
        # just BOUND (bind's rescue ran against the swapped-out empty
        # pool): anything with a live binding stays out
        st = %{
          st
          | free: Enum.reject(saved_free, &Map.has_key?(st.rc, &1)),
            hold: st.hold - 1
        }
        # a case IS the statement boundary when the program is written
        # as matches (`true = f()` nests a clause, not a let): scrutinee
        # and guard deaths drain here, before the body
        st = reap(st)

        st =
          if st.hold > 0 and takes_message?(body),
            do: exit_bound_body(body, st, mode, done_info),
            else: clause_body(body, st, mode, done_info)

        # clause temps are clause-local (the vars rewind guarantees it),
        # so the pool is RESTORED by union at exit: entry pool plus
        # whatever died inside. Forcing it empty instead would discard
        # it at every nesting level — and every `=` match nests a clause.
        st = reset_next(%{st | vars: saved_vars}, saved_next)

        st = %{
          st
          | free:
              Enum.uniq(st.free ++ saved_free)
              |> Enum.reject(&Map.has_key?(st.rc, &1))
        }

        e(st, next_lbl)
      end)

    # no clause matched (erlc usually supplies its own match_fail catch-all;
    # this is the backstop)
    st = emit(st, {:fail, fail_reason})
    close_sink(st, mode, done_info)
  end

  defp guard_test({:c_literal, _, true}, _fail, st), do: st

  # A protected guard: erlc wraps guard expressions as
  #   try Expr of <V> -> V catch <..> -> 'false'
  # The model approximation compiles Expr directly (a guard that would trap
  # kills the process instead of failing the clause — v1 caveat).
  defp guard_test({:c_try, _, arg, [{:c_var, _, v}], {:c_var, _, v}, _, _}, fail, st),
    do: guard_test(arg, fail, st)

  defp guard_test(guard, fail, st) do
    # guard scratch dies at the branch; same spine argument as lit_test
    saved = st.next
    {r, st} = expr(guard, st, :value)
    st = emit(st, {:biff, r, fail})
    reset_next(st, saved)
  end

  # ---------------------------------------------------------------------------
  # Patterns
  # ---------------------------------------------------------------------------

  defp pat_test({:c_var, _, name}, sreg, _fail, st), do: bind(st, name, sreg)

  defp pat_test({:c_alias, _, {:c_var, _, name}, pat}, sreg, fail, st),
    do: pat_test(pat, sreg, fail, bind(st, name, sreg))

  defp pat_test({:c_literal, _, v}, sreg, fail, st), do: lit_test(v, sreg, fail, st)

  defp pat_test({:c_cons, _, hp, tp}, sreg, fail, st) do
    st = tag_check(sreg, :cons, fail, st)
    {hr, st} = new_reg(st)
    st = emit(st, {:hd, hr, sreg})
    st = pat_test(hp, hr, fail, st)
    {tr, st} = new_reg(st)
    st = emit(st, {:tl, tr, sreg})
    pat_test(tp, tr, fail, st)
  end

  defp pat_test({:c_tuple, _, pats}, sreg, fail, st) do
    st = tuple_shape_check(sreg, length(pats), fail, st)

    pats
    |> Enum.with_index()
    |> Enum.reduce(st, fn {pat, i}, st ->
      {er, st} = new_reg(st)
      st = emit(st, {:tget, er, sreg, i})
      pat_test(pat, er, fail, st)
    end)
  end

  # `%{k => v}` in a pattern. Every pair is a PROBE: walk the map looking
  # for the key, fail the clause if it is not there, bind the value if it
  # is. A flatmap is a linear scan by construction, and inlining it here
  # rather than calling the prelude keeps a pattern match allocation-free
  # — `maps:find/2` would return `{ok, V}`, and a tuple per matched key
  # is not a price a pattern should pay.
  # A binary in a PATTERN. Elixir's string matching is this and almost
  # nothing else: some fixed bytes, then optionally a `rest::binary`.
  #
  # The bytes are compared or bound in place, which costs no allocation.
  # The rest is a COPY, because this machine has no sub-binaries — a
  # sub-binary is a base, an offset and a length, and every operation on
  # a binary would have to know about it. That is a real feature, not a
  # missing line, and `notes/43` says what it would take.
  defp pat_test({:c_binary, _, segs}, sreg, fail, st) do
    st = tag_check(sreg, :bin, fail, st)

    {fixed, rest} =
      case List.last(segs) do
        {:c_bitstr, _, v, _, _, {:c_literal, _, :binary}, _} ->
          {Enum.drop(segs, -1), v}

        _ ->
          {segs, nil}
      end

    bytes = Enum.flat_map(fixed, &expand_bytes(&1, st))
    n = length(bytes)

    {rz, st} = load_int(0, st)
    {rsize, st} = new_reg(st)
    st = emit(st, {:binat, rsize, sreg, rz})
    {rn, st} = load_int(n, st)
    {rc, st} = new_reg(st)

    st =
      if rest == nil do
        # no tail: the lengths have to be equal
        st = emit(st, {:cmpeq, rc, rsize, rn})
        emit(st, {:biff, rc, fail})
      else
        # a tail absorbs whatever is left, but there has to be enough
        st = emit(st, {:cmplt, rc, rsize, rn})
        emit(st, {:bift, rc, fail})
      end

    st =
      bytes
      |> Enum.with_index()
      |> Enum.reduce(st, fn {spec, i}, st ->
        {ri, st} = load_int(1 + i, st)
        {rb, st} = new_reg(st)
        st = emit(st, {:binat, rb, sreg, ri})

        case spec do
          {:lit, b} -> lit_test(b, rb, fail, st)
          {:var, name} -> bind(st, name, rb)
        end
      end)

    case rest do
      nil ->
        st

      {:c_var, _, name} ->
        {rf, st} = load_int(n, st)
        {rr, st} = prelude_call_regs(:bin_from, [sreg, rf], st)
        bind(st, name, rr)

      other ->
        unsupported(st, "binary tail pattern #{inspect(other, limit: 3)}")
    end
  end

  # One segment, as a list of BYTES.
  #
  # `erlc` packs adjacent literal bytes into one wide integer segment —
  # `"hi"` in a pattern is `26729:16`, not two eight-bit fields — so a
  # matcher that only understands eight-bit segments understands almost
  # no Elixir strings. Unpacking here is big-endian, which is what the
  # `[unsigned, big]` flags on every one of them say.
  defp expand_bytes(
         {:c_bitstr, _, {:c_literal, _, v}, {:c_literal, _, bits}, {:c_literal, _, 1},
          {:c_literal, _, :integer}, _},
         _st
       )
       when is_integer(v) and is_integer(bits) and rem(bits, 8) == 0 do
    n = div(bits, 8)
    for i <- (n - 1)..0//-1, do: {:lit, Bitwise.band(Bitwise.bsr(v, 8 * i), 0xFF)}
  end

  defp expand_bytes(
         {:c_bitstr, _, {:c_var, _, name}, {:c_literal, _, 8}, {:c_literal, _, 1},
          {:c_literal, _, :integer}, _},
         _st
       ),
       do: [{:var, name}]

  defp expand_bytes(seg, st),
    do: unsupported(st, "binary segment pattern #{inspect(seg, limit: 4)}")

  defp pat_test({:c_map, _, _arg, pairs, _is_pat}, sreg, fail, st) do
    st = tag_check(sreg, :map, fail, st)
    Enum.reduce(pairs, st, fn {:c_map_pair, _, _op, kpat, vpat}, st ->
      map_probe(sreg, kpat, vpat, fail, st)
    end)
  end

  defp pat_test(pat, _sreg, _fail, st), do: unsupported(st, "pattern #{inspect(pat, limit: 3)}")

  defp map_probe(sreg, kpat, vpat, fail, st) do
    {rkey, st} =
      case kpat do
        {:c_literal, _, k} -> load_literal(k, st)
        {:c_var, _, name} -> {Map.fetch!(st.vars, name), consume(st, name)}
        other -> unsupported(st, "map key pattern #{inspect(other, limit: 3)}")
      end

    {top, st} = new_label(st)
    {hit, st} = new_label(st)

    {rn, st} = new_reg(st)
    {rzero, st} = load_int(0, st)
    st = emit(st, {:mapat, rn, sreg, rzero})

    {ri, st} = new_reg(st)
    st = emit(st, {:ldi, ri, 0})
    {rone, st} = load_int(1, st)
    {rt, st} = new_reg(st)
    {rc, st} = new_reg(st)
    {rk, st} = new_reg(st)

    st = e(st, top)
    # ran off the end: this clause does not match
    st = emit(st, {:cmpeq, rc, ri, rn})
    st = emit(st, {:bift, rc, fail})
    # key j is at index 1 + 2j
    st = emit(st, {:add, rt, ri, ri})
    st = emit(st, {:add, rt, rt, rone})
    st = emit(st, {:mapat, rk, sreg, rt})
    st = emit(st, {:cmpeq, rc, rk, rkey})
    st = emit(st, {:bift, rc, hit})
    st = emit(st, {:add, ri, ri, rone})
    st = emit(st, {:jmp, top})

    st = e(st, hit)
    # ...and its value at 2 + 2j, which is one past where we just looked
    {rv, st} = new_reg(st)
    st = emit(st, {:add, rt, rt, rone})
    st = emit(st, {:mapat, rv, sreg, rt})
    pat_test(vpat, rv, fail, st)
  end

  # `bne ra, rb, label` needs 28 bits and the slot has 24, so
  # `Encoding` refuses it and `notes/15` says the EMITTER must lower it
  # — "which the front end can always do (it owns a scratch register;
  # the assembler does not)". It never did, so every function with a
  # literal pattern compiled to something no image could contain, and
  # the gap only showed when a real Erlang module was pushed through to
  # bundles for the first time.
  #
  # Two bundles instead of one: compare into a scratch, branch on the
  # boolean. `cmpne` produces `true` when they differ, and `bift` takes
  # the branch when it sees `true` — which is exactly "not equal, go
  # fail", the same sense `bne` had.
  defp emit_bne(st, ra, rb, fail) do
    # The scratch is dead the moment the branch reads it, so it is
    # RETURNED rather than consumed. A fresh register per comparison
    # exhausts the sixteen-register window on any function with a few
    # literal patterns — which is the same reason `notes/14` records
    # the front end recycling aggressively everywhere else.
    saved = st.next
    {t, st} = new_reg(st)
    st = emit(st, {:cmpne, t, ra, rb})
    st = emit(st, {:bift, t, fail})
    reset_next(st, saved)
  end

  # Every literal test allocates PURE SCRATCH — nothing a literal
  # comparison emits survives the branch — so the whole family reclaims
  # its registers on the way out. On a spine of `=` matches the clause
  # rewind never runs (the body IS the rest of the function), so a test
  # that did not clean up after itself would cost a register per match,
  # forever — which is `notes/26` entry 22 wearing a different hat.
  defp lit_test(v, sreg, fail, st) do
    saved = st.next
    st = lit_test_(v, sreg, fail, st)
    reset_next(st, saved)
  end

  defp lit_test_(v, sreg, fail, st) when is_integer(v) do
    {t, st} = load_int(v, st)
    emit_bne(st, sreg, t, fail)
  end

  defp lit_test_(v, sreg, fail, st) when is_atom(v) do
    {t, st} = new_reg(st)
    st = emit(st, {:lda, t, v})
    emit_bne(st, sreg, t, fail)
  end

  defp lit_test_([], sreg, fail, st) do
    {t, st} = new_reg(st)
    st = emit(st, {:ldn, t})
    emit_bne(st, sreg, t, fail)
  end

  defp lit_test_([h | t], sreg, fail, st) do
    st = tag_check(sreg, :cons, fail, st)
    {hr, st} = new_reg(st)
    st = emit(st, {:hd, hr, sreg})
    st = lit_test(h, hr, fail, st)
    {tr, st} = new_reg(st)
    st = emit(st, {:tl, tr, sreg})
    lit_test(t, tr, fail, st)
  end

  # A string in a PATTERN. Word equality is pointer equality, and two
  # equal binaries at different addresses are different pointers, so the
  # literal is built and compared byte by byte. It costs the literal's
  # construction on every match, which is the price of having no constant
  # area (`notes/43`).
  defp lit_test_(v, sreg, fail, st) when is_binary(v) do
    st = tag_check(sreg, :bin, fail, st)
    {rlit, st} = load_literal(v, st)
    {rok, st} = prelude_call_regs(:bin_eq, [sreg, rlit], st)
    emit(st, {:biff, rok, fail})
  end

  defp lit_test_(v, sreg, fail, st) when is_tuple(v) do
    st = tuple_shape_check(sreg, tuple_size(v), fail, st)

    v
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce(st, fn {el, i}, st ->
      {er, st} = new_reg(st)
      st = emit(st, {:tget, er, sreg, i})
      lit_test(el, er, fail, st)
    end)
  end

  defp lit_test_(v, _sreg, _fail, st), do: unsupported(st, "literal pattern #{inspect(v)}")

  defp tag_check(sreg, tag, fail, st) do
    saved = st.next
    {t, st} = new_reg(st)
    st = emit(st, {:istag, t, sreg, tag})
    st = emit(st, {:biff, t, fail})
    reset_next(st, saved)
  end

  defp tuple_shape_check(sreg, arity, fail, st) do
    saved = st.next
    st = tag_check(sreg, :tuple, fail, st)
    {ar, st} = new_reg(st)
    st = emit(st, {:tarity, ar, sreg})
    {an, st} = load_int(arity, st)
    st = emit_bne(st, ar, an, fail)
    reset_next(st, saved)
  end

  # ---------------------------------------------------------------------------
  # Literals
  # ---------------------------------------------------------------------------

  defp load_int(v, st) do
    {r, st} = new_reg(st)

    if v >= -2048 and v <= 2047 do
      {r, emit(st, {:ldi, r, v})}
    else
      {r, emit(st, {:ldc, r, v})}
    end
  end

  defp load_literal(v, st) when is_integer(v), do: load_int(v, st)

  defp load_literal(v, st) when is_atom(v) do
    {r, st} = new_reg(st)
    {r, emit(st, {:lda, r, v})}
  end

  defp load_literal([], st) do
    {r, st} = new_reg(st)
    {r, emit(st, {:ldn, r})}
  end

  defp load_literal([h | t], st) do
    {rh, st} = load_literal(h, st)
    {rt, st} = load_literal(t, st)
    {r, st} = new_reg(st)
    {r, emit(st, {:cons, r, rh, rt})}
  end

  # The destination is allocated FIRST and everything above it is scratch,
  # so a literal costs exactly one register however big it is. Allocating
  # the elements first and the tuple last — which is the order they are
  # USED in — leaks one register per element for the rest of the
  # enclosing expression, and a function with three tuple literals in it
  # runs a sixteen-register window dry (`notes/43`).
  defp load_literal(v, st) when is_tuple(v) do
    {rd, st} = new_reg(st)
    # literal internals allocate from `next` only: a temp popped from the
    # free list would be dropped by the scratch rewind and leak
    sfree = st.free
    st = %{st | free: []}
    scratch = st.next
    st = emit(st, {:mktup, rd, tuple_size(v)})

    st =
      v
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.reduce(st, fn {el, i}, st ->
        {r, st} = load_literal(el, st)
        emit(%{st | next: scratch}, {:tset, rd, i, r})
      end)

    {rd, %{st | next: scratch, free: sfree}}
  end

  # A binary LITERAL — which is what every Elixir string is. There is no
  # constant area on this machine: `Encoding`'s pool holds 36-bit WORDS,
  # and a binary is a heap object, so a string is CONSTRUCTED, byte by
  # byte, the same way a tuple literal is (`notes/43`).
  #
  # `tset` while the index fits four bits, then `mseti`/`mset`: two
  # bundles a byte for the first fourteen and four after that. A long
  # string is therefore expensive in CODE as well as in heap, and that is
  # the honest cost of having no constant pool rather than something to
  # hide.
  defp load_literal(v, st) when is_binary(v) do
    {rd, st} = new_reg(st)
    sfree = st.free
    st = %{st | free: []}
    scratch = st.next
    {rn, st} = load_int(byte_size(v), st)
    st = emit(%{st | next: scratch}, {:mkbin, rd, rn})

    st =
      v
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.reduce(st, fn {b, i}, st ->
        {rb, st} = load_int(b, st)

        st =
          if 1 + i <= 15 do
            emit(st, {:tset, rd, 1 + i, rb})
          else
            {ri, st} = load_int(1 + i, st)
            st = emit(st, {:mseti, ri})
            emit(st, {:mset, rd, rb})
          end

        %{st | next: scratch}
      end)

    {rd, %{st | free: sfree}}
  end

  # A map LITERAL — which is what `%{a: 1}` and every struct literal
  # reaches here as, because erlc folds the construction away. The size
  # is known, so the pairs go in at literal indices and no probe is
  # needed; the temporaries are recycled per pair, or a seven-key struct
  # would run a sixteen-register window dry (`notes/42`).
  defp load_literal(v, st) when is_map(v) do
    {rd, st} = new_reg(st)
    sfree = st.free
    st = %{st | free: []}
    scratch = st.next
    {rn, st} = load_int(map_size(v), st)
    st = emit(%{st | next: scratch}, {:mkmap, rd, rn})

    st =
      v
      |> Map.to_list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index()
      |> Enum.reduce(st, fn {{k, val}, j}, st ->
        {rk, st} = load_literal(k, st)
        st = emit(%{st | next: scratch}, {:tset, rd, 1 + 2 * j, rk})
        {rv, st} = load_literal(val, st)
        emit(%{st | next: scratch}, {:tset, rd, 2 + 2 * j, rv})
      end)

    {rd, %{st | next: scratch, free: sfree}}
  end

  defp load_literal(v, st), do: unsupported(st, "literal #{inspect(v)}")

  defp extract_fail_reason([{:c_literal, _, v} | _]) when is_atom(v), do: safe_reason(v)
  defp extract_fail_reason([{:c_literal, _, v} | _]) when is_tuple(v) and tuple_size(v) > 0,
    do: safe_reason(elem(v, 0))
  defp extract_fail_reason([{:c_tuple, _, [{:c_literal, _, v} | _]} | _]) when is_atom(v),
    do: safe_reason(v)
  defp extract_fail_reason(_), do: :badmatch

  defp safe_reason(v) when is_atom(v), do: v
  defp safe_reason(_), do: :badmatch

  # ---------------------------------------------------------------------------
  # erlang: builtins
  # ---------------------------------------------------------------------------

  @arith %{:+ => :add, :- => :sub, :* => :mul, :band => :band, :bor => :bor, :bxor => :bxor}
  @cmp %{
    :< => {:cmplt, false},
    :> => {:cmplt, true},
    :== => {:cmpeq, false},
    :"=:=" => {:cmpeq, false},
    :"=<" => {:cmple, false},
    :>= => {:cmple, true},
    :"/=" => {:cmpne, false},
    :"=/=" => {:cmpne, false}
  }
  # `maps:` functions and the prelude names they resolve to. Prefixed
  # because `prelude_defs/0` is one table keyed by {name, arity} and
  # `size/1` is a name two modules both want.
  @istag %{
    is_integer: :int,
    is_atom: :atom,
    is_tuple: :tuple,
    is_pid: :pid,
    is_function: :fun,
    is_binary: :bin,
    is_bitstring: :bin,
    is_map: :map,
    is_list: :cons
  }

  defp builtin(f, [a, b], st, mode, _node) when is_map_key(@arith, f) do
    {ra, st} = expr(a, st, :value)
    {rb, st} = expr(b, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {Map.fetch!(@arith, f), rd, ra, rb})}, mode)
  end

  # `mulsr(A, B, K)` — the fixed-point primitive. Spelled as an erlang:
  # call because there is no operator for it and v1 has no funs, so
  # `:erlang.mulsr(a, b, 12)` in Elixir (or `erlang:mulsr(A, B, 12)` in
  # Erlang) is the whole surface. K must be a literal 1..16: it is an
  # instruction field, not a value, and a variable shift would need a
  # barrel shifter the ISA deliberately does not have.
  defp builtin(:mulsr, [a, b, {:c_literal, _, k}], st, mode, _node)
       when is_integer(k) and k >= 1 and k <= 16 do
    {ra, st} = expr(a, st, :value)
    {rb, st} = expr(b, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:mulsr, rd, ra, rb, k})}, mode)
  end

  defp builtin(:mulsr, [_a, _b, _k], st, _mode, _node),
    do: unsupported(st, "mulsr shift must be a literal integer in 1..16")

  defp builtin(f, [a, b], st, mode, _node) when is_map_key(@cmp, f) do
    {op, swap} = Map.fetch!(@cmp, f)
    {ra, st} = expr(a, st, :value)
    {rb, st} = expr(b, st, :value)
    {rd, st} = new_reg(st)
    {x, y} = if swap, do: {rb, ra}, else: {ra, rb}
    finish({rd, emit(st, {op, rd, x, y})}, mode)
  end

  defp builtin(f, [a], st, mode, _node) when is_map_key(@istag, f) do
    {ra, st} = expr(a, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:istag, rd, ra, Map.fetch!(@istag, f)})}, mode)
  end

  # `Pid ! Msg` in Erlang and `send(pid, msg)` in Elixir are the same
  # call by the time Core Erlang has them — `erlang:'!'/2` and
  # `erlang:send/2` — and BEAM treats them as synonyms too.
  defp builtin(:send, [p, msg], st, mode, node), do: builtin(:!, [p, msg], st, mode, node)

  defp builtin(:!, [p, msg], st, mode, _node) do
    {rp, st} = expr(p, st, :value)
    {rm, st} = expr(msg, st, :value)
    finish({rm, emit(st, {:send, rp, rm})}, mode)
  end

  # `erlang:error/1`, `throw/1` and `exit/1` all raise. BEAM distinguishes
  # them by CLASS — error, throw, exit — and `try` can match on it. The
  # machine carries a reason and not a class, so all three lower to
  # `fail` and a handler sees class `error`. That is a known
  # approximation and it is written down rather than hidden: a
  # `catch throw:X` will still catch, but so will `catch error:X`.
  #
  # The reason itself is an ATOM index, so a tuple reason like
  # `{bad_generator, L}` — which is what erlc generates for a
  # comprehension over a non-list — keeps its TAG and loses its payload.
  # The tag is the part a supervisor logs.
  defp builtin(f, [reason], st, mode, _node) when f in [:error, :throw, :exit] do
    st = emit(st, {:fail, extract_fail_reason([reason])})
    finish(load_literal(:ok, st), mode)
  end

  defp builtin(:self, [], st, mode, _node) do
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:self, rd})}, mode)
  end

  defp builtin(:spawn, [mod, {:c_literal, _, f}, args_list], st, mode, _node) do
    args = syntactic_list(args_list, st)

    # remote: the spawn goes through the target's trampoline, like a call
    target =
      case mod do
        {:c_literal, _, m} when is_atom(m) and m != :pb_prelude ->
          if st.remote, do: remote_name(m, f, length(args)), else: fname(f, length(args))

        _ ->
          fname(f, length(args))
      end

    {regs, st} =
      Enum.reduce(args, {[], st}, fn arg, {acc, st} ->
        {r, st} = expr(arg, st, :value)
        {acc ++ [r], st}
      end)

    st = stage(st, regs)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:spawn, rd, target, length(args)})}, mode)
  end

  # `spawn_link/3` is the OTP idiom for starting a child, and it is
  # exactly what its name says: spawn, then link to what came back.
  #
  # BEAM makes the pair ATOMIC — a child that dies between the two
  # cannot be missed, because there is no gap for it to die in. Here
  # there is a gap of one bundle, and it is not closeable without a
  # fused opcode. The window is small and the failure mode is benign:
  # `link` to a dead pid takes the dead-letter path, so a child that
  # dies in the gap leaves the parent unlinked rather than wedged.
  # Recorded rather than papered over — a fused `spawn_link` is the
  # honest fix and it is one code point.
  defp builtin(:spawn_link, [mod, f, args_list], st, mode, _node) do
    {rd, st} = builtin(:spawn, [mod, f, args_list], st, :value, nil)
    finish({rd, emit(st, {:link, rd})}, mode)
  end

  defp builtin(:link, [p], st, mode, _node), do: unary_true(p, :link, st, mode)
  defp builtin(:unlink, [p], st, mode, _node), do: unary_true(p, :unlink, st, mode)

  defp builtin(:monitor, [{:c_literal, _, :process}, p], st, mode, _node) do
    {rp, st} = expr(p, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:monitor, rd, rp})}, mode)
  end

  defp builtin(:exit, [p, reason], st, mode, _node) do
    {rp, st} = expr(p, st, :value)
    {rr, st} = expr(reason, st, :value)
    st = emit(st, {:exit2, rp, rr})
    finish(load_literal(true, st), mode)
  end

  defp builtin(:process_flag, [{:c_literal, _, :trap_exit}, {:c_literal, _, flag}], st, mode, _node)
       when is_boolean(flag) do
    st = emit(st, {:trapexit, if(flag, do: 1, else: 0)})
    finish(load_literal(true, st), mode)
  end

  # ---- the map primitives (`notes/42`). Spelled as erlang: calls for the
  # same reason `mulsr` is: there is no operator for them and the prelude
  # is ordinary Erlang, compiled by erlc, which has to be able to say
  # them somehow.
  defp builtin(:mkbin, [n], st, mode, _node) do
    {rn, st} = expr(n, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:mkbin, rd, rn})}, mode)
  end

  defp builtin(:binat, [b, i], st, mode, _node) do
    {rb, st} = expr(b, st, :value)
    {ri, st} = expr(i, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:binat, rd, rb, ri})}, mode)
  end

  defp builtin(:byte_size, [b], st, mode, _node) do
    {rb, st} = expr(b, st, :value)
    {rd, st} = new_reg(st)
    scratch = st.next
    {rz, st} = load_int(0, st)
    st = emit(st, {:binat, rd, rb, rz})
    finish({rd, reset_next(st, scratch)}, mode)
  end

  defp builtin(:mkmap, [n], st, mode, _node) do
    {rn, st} = expr(n, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:mkmap, rd, rn})}, mode)
  end

  defp builtin(:mapat, [mp, i], st, mode, _node) do
    {rm, st} = expr(mp, st, :value)
    {ri, st} = expr(i, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:mapat, rd, rm, ri})}, mode)
  end

  # `mset` returns nothing useful; the prelude sequences it with `,` and
  # the value of a sequence is its last expression, so `ok` is what it
  # hands back.
  defp builtin(:mset, [mp, i, v], st, mode, _node) do
    # everything is evaluated BEFORE the index is latched: evaluating the
    # value could itself contain an `mset`, and the latch is one deep
    {rm, st} = expr(mp, st, :value)
    {rv, st} = expr(v, st, :value)
    {ri, st} = expr(i, st, :value)
    st = emit(st, {:mseti, ri})
    st = emit(st, {:mset, rm, rv})
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:lda, rd, :ok})}, mode)
  end

  defp builtin(:hd, [x], st, mode, _node), do: heap_unary(x, :hd, st, mode)
  defp builtin(:tl, [x], st, mode, _node), do: heap_unary(x, :tl, st, mode)

  defp builtin(:element, [{:c_literal, _, i}, t], st, mode, _node) when is_integer(i) do
    {rt, st} = expr(t, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:tget, rd, rt, i - 1})}, mode)
  end

  # ---- registered names (notes/50) -----------------------------------
  # register/2 and unregister/1 return true in BEAM; the ops fault
  # with badarg themselves, so the result is a literal.
  defp builtin(:register, [n, pd], st, mode, _node) do
    {rn, st} = expr(n, st, :value)
    {rp, st} = expr(pd, st, :value)
    st = emit(st, {:reg_name, rn, rp})
    finish(load_literal(true, st), mode)
  end

  defp builtin(:whereis, [n], st, mode, _node) do
    {rn, st} = expr(n, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {:whereis, rd, rn})}, mode)
  end

  defp builtin(:unregister, [n], st, mode, _node) do
    {rn, st} = expr(n, st, :value)
    st = emit(st, {:unreg, rn})
    finish(load_literal(true, st), mode)
  end

  defp builtin(:yield, [], st, mode, _node) do
    st = emit(st, {:yield})
    finish(load_literal(true, st), mode)
  end

  defp builtin(:display, [x], st, mode, _node) do
    {rx, st} = expr(x, st, :value)
    finish({rx, emit(st, {:out, rx})}, mode)
  end

  # `erlang:host/0` — the pid of the host on ring node 15 (`RingHost`):
  # engine 15, slot 0, serial 0. A send to it leaves through the
  # remote-send path like any other engine's pid, and the board-side
  # driver answers as that pid.
  defp builtin(:host, [], st, mode, _node) do
    {r, st} = new_reg(st)
    st = emit(st, {:ldc, r, {:raw, PicoBEAM.Term.pid(15, 0, 0)}})
    finish({r, st}, mode)
  end

  defp builtin(:halt, [], st, mode, _node) do
    st = emit(st, {:halt})
    finish(load_literal(:ok, st), mode)
  end

  defp builtin(:error, [{:c_literal, _, reason}], st, mode, _node) when is_atom(reason) do
    st = emit(st, {:fail, reason})
    finish(load_literal(:ok, st), mode)
  end

  # erlc rewrites some `maps:` calls into `erlang:` BIFs on the way to
  # Core — `maps:size/1` becomes `erlang:map_size/1`, `maps:get/2`
  # becomes `erlang:map_get/2` — so the same prelude functions have to be
  # reachable from both names.
  defp builtin(f, args, st, mode, _node)
       when is_map_key(@erlang_prelude, {f, length(args)}) do
    prelude_call(Map.fetch!(@erlang_prelude, {f, length(args)}), args, st, mode)
  end

  defp builtin(f, args, st, _mode, _node),
    do: unsupported(st, "erlang:#{f}/#{length(args)}")

  defp unary_true(p, op, st, mode) do
    {rp, st} = expr(p, st, :value)
    st = emit(st, {op, rp})
    finish(load_literal(true, st), mode)
  end

  defp heap_unary(x, op, st, mode) do
    {rx, st} = expr(x, st, :value)
    {rd, st} = new_reg(st)
    finish({rd, emit(st, {op, rd, rx})}, mode)
  end

  defp stage(st, regs) do
    regs
    |> Enum.with_index()
    |> Enum.reduce(st, fn {r, i}, st -> emit(st, {:arg, i, r}) end)
  end

  # spawn's third argument must be a syntactic list so arity is known at
  # compile time (the hardware stages arguments; there is no apply/3)
  defp syntactic_list({:c_literal, _, l}, st) when is_list(l) do
    Enum.map(l, fn v -> {:c_literal, [], v} end) |> check_proper(st)
  end

  defp syntactic_list({:c_cons, _, h, t}, st), do: [h | syntactic_list(t, st)]
  defp syntactic_list({:c_literal, _, []}, _st), do: []
  defp syntactic_list(_, st), do: unsupported(st, "spawn args must be a syntactic list")

  defp check_proper(l, _st), do: l
end
