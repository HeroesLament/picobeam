defmodule PicoBEAM.Ex do
  @moduledoc """
  Elixir, on the gates.

  `PicoBEAM.Erl` compiles Core Erlang, and has since `notes/25`. The
  thing worth saying plainly is that **Core Erlang is not an Erlang
  thing**: it is the BEAM's common intermediate language, and Elixir
  compiles to it exactly as Erlang does. So this module is not a second
  front end. It is a different way of getting to the same door.

  ## The route

      .ex source
        └─ Code.compile_file/1 with debug_info    →  .beam binary
             └─ :beam_lib.chunks(bin, [:debug_info])
                  └─ :elixir_erl.debug_info(:erlang_v1, ...)  →  Erlang AF
                       └─ :compile.forms(forms, [:to_core])   →  Core Erlang
                            └─ PicoBEAM.Erl.translate_core/3

  Every step is the real compiler. Nothing here re-implements Elixir,
  parses it, or approximates it: the module that runs on the fabric is
  the one `elixirc` produced, taken from its own debug-info chunk and
  lowered one stage further than it usually is.

  `:elixir_erl.debug_info/4` is the same entry point decompilers use to
  recover Erlang from a .beam — it is how the Erlang Abstract Format
  survives Elixir compilation at all.

  ## What of Elixir actually works

  What the MACHINE has, which is less than what Elixir has. Integers,
  atoms, tuples, cons cells, pids and refs; function calls, guards,
  pattern matching, `case`, `receive`, `send`, `spawn`, `try`. So:

      def fib(n) when n < 2, do: n
      def fib(n), do: fib(n - 1) + fib(n - 2)

  compiles, because `n - 1` is `:erlang.-/2` in Core Erlang whatever
  wrote it. Maps, binaries, floats, strings, protocols, structs and
  anonymous functions do not, because the machine has none of them —
  `notes/26`-shaped debt, not a translation problem.

  `__info__/1` is skipped by name. Elixir generates it on every module;
  it is reflection over maps and keyword lists, nothing calls it here,
  and compiling it would fail loudly for a function nobody wanted.

  ## Names

  Elixir's `Hello.main/0` is `main/0` in Core Erlang — the module
  qualification lives on the module, not the function — so the entry
  point is `:"main/0"`, spelled the same as it is for an `.erl` file.
  """

  alias PicoBEAM.Erl

  defmodule CompileError do
    defexception [:message]
  end

  # Elixir writes this on every module and nothing on this machine can
  # run it: it answers with keyword lists and maps.
  @skip [{:__info__, 1}]

  @doc """
  Compile a `.ex` file to an assembled program.

  Returns the program for the FIRST module defined in the file. A file
  with several modules compiles all of them (Elixir insists) and only
  the first comes back; pass `module:` to choose another.
  """
  def compile_file(path, opts \\ []) do
    path
    |> compile_to_beams()
    |> pick(opts[:module])
    |> to_program()
  end

  @doc "Compile Elixir source held in a string."
  def compile_string(source, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "pico_beam_ex_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pb_source.ex")
    File.write!(path, source)

    try do
      compile_file(path, opts)
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  Compile every module in `source` for the hot-loading link model
  (`PicoBEAM.Link`): `[%{module:, program:, exports:}]`, one per module,
  in the order Elixir defined them.

  `remote: true` is passed through to `Erl.translate_core/4`, so calls
  to other modules (and fully qualified calls to the same one) come out
  against `:"Mod:f/A"` names for the linker to resolve. `exports` are
  the `{f, a}` pairs the module exports, `__info__/1` and
  `module_info/0,1` left out.

  The BEAM modules Elixir compiles along the way are purged again: the
  host only wanted their debug info, and a shell that redefines a module
  would otherwise warn about it on every redefinition.
  """
  def compile_modules(source, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "pico_beam_ex_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pb_source.ex")
    File.write!(path, source)
    opts = Keyword.put_new(opts, :remote, true)

    # Elixir really defines these modules on the host while it compiles
    # them, and they are purged afterwards. A name already loaded here is
    # a host module (`Enum`, a controller module), and compiling over it
    # would replace it and then delete it: refuse.
    for mod <- defined_modules(source), :code.is_loaded(mod) != false do
      raise CompileError,
        message: "#{inspect(mod)} is a module on the host; pick another name"
    end

    try do
      mods = compile_to_beams(path)

      try do
        Enum.map(mods, fn {mod, bin} ->
          {program, exports} = to_program_and_exports({mod, bin}, opts)
          %{module: mod, program: program, exports: exports}
        end)
      after
        for {mod, _} <- mods do
          :code.purge(mod)
          :code.delete(mod)
        end
      end
    after
      File.rm_rf(dir)
    end
  end

  defp defined_modules(source) do
    {_ast, acc} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [Module.concat(parts) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # ---------------------------------------------------------------------------

  defp compile_to_beams(path) do
    with_debug_info(fn -> Code.compile_file(path) end)
  end

  # debug_info is what carries the Erlang Abstract Format through the
  # Elixir compiler. Without it there is no route back down: the .beam
  # holds bytecode, and bytecode is a stage too far to lower from.
  #
  # `Code.compiler_options/1` is NODE-GLOBAL, so save-set-restore around
  # a compile is a data race the moment two of them overlap: the second
  # caller saves the FIRST one's `true`, and the first one's `after`
  # clause sets `debug_info: false` back while the second is still
  # compiling. Its module comes out stripped and `to_program/1` raises
  # `debug_info: :unknown_format` — the same message a genuinely
  # unsupported backend gives, which is why this looked for a while like
  # a coverage-tool problem (`notes/26` entry 24).
  #
  # ExUnit runs `async: true` cases concurrently, so the whole suite is
  # the second caller. One lock around the global.
  defp with_debug_info(fun) do
    :global.trans({__MODULE__, self()}, fn ->
      previous = Code.compiler_options()
      Code.compiler_options(docs: false, debug_info: true)

      try do
        fun.()
      after
        Code.compiler_options(previous)
      end
    end)
  end

  defp pick([], _), do: raise(CompileError, message: "no modules in that file")
  defp pick([{_mod, _bin} = first | _], nil), do: first

  defp pick(mods, want) do
    Enum.find(mods, fn {m, _} -> m == want end) ||
      raise(CompileError,
        message: "#{inspect(want)} not in that file — found #{inspect(Enum.map(mods, &elem(&1, 0)))}"
      )
  end

  defp to_program({mod, bin}), do: {mod, bin} |> to_program_and_exports([]) |> elem(0)

  defp to_program_and_exports({mod, bin}, opts) do
    {:ok, {^mod, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bin, [:debug_info])

    forms =
      case backend.debug_info(:erlang_v1, mod, data, []) do
        {:ok, forms} -> forms
        {:error, reason} -> raise CompileError, message: "debug_info: #{inspect(reason)}"
      end

    core =
      case :compile.forms(forms, [:to_core, :binary, :return_errors, :nowarn_unused_vars]) do
        {:ok, _m, core} -> core
        {:ok, _m, core, _warnings} -> core
        {:error, errors, _warnings} -> raise CompileError, message: "to_core: #{inspect(errors)}"
      end

    {:c_module, _, _name, exports, _attrs, _defs} = core

    exports =
      for {:c_var, _, {f, a}} <- exports,
          f != :module_info,
          {f, a} not in @skip,
          do: {f, a}

    {Erl.translate_core(core, mod, @skip, opts), exports}
  end
end
