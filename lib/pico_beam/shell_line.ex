defmodule PicoBEAM.ShellLine do
  @moduledoc """
  One shell input, as Elixir source the picoBEAM front end compiles.

  An expression becomes a module with one function,

      defmodule PbShell.L7 do
        def run({:pb_b, a, b}) do
          value = (EXPR)
          {value, {:pb_b, a, b, c}}
        end
      end

  whose argument is the evaluator's binding tuple (`priv/demo/pb_shell.ex`)
  and whose result is the value and the new tuple. The names are the
  bindings before the line, then any the line's top-level matches add,
  in order; the host keeps the names, the machine keeps the values.

  A `defmodule` input is passed through unchanged: it is loaded, not run.
  """

  @doc """
  Classify and wrap `input`. Returns `{:module, source}` or
  `{:expr, source, module, new_names}`; raises `SyntaxError` and friends
  on input that does not parse.
  """
  def build(input, names, n) do
    ast = Code.string_to_quoted!(input)

    if defmodule?(ast) do
      {:module, input}
    else
      bound = bound_vars(ast)
      new_names = names ++ Enum.reject(bound, &(&1 in names))
      mod = Module.concat([PbShell, "L#{n}"])

      source = """
      defmodule #{inspect(mod)} do
        def run(#{tuple(names)}) do
          pb_value = (
      #{input}
          )
          {pb_value, #{tuple(new_names)}}
        end
      end
      """

      {:expr, source, mod, new_names}
    end
  end

  # tagged, so it is never `{}`: the machine's tuples have arity 1..255
  defp tuple(names), do: "{" <> Enum.map_join([":pb_b" | names], ", ", &to_string/1) <> "}"

  defp defmodule?({:defmodule, _, _}), do: true
  defp defmodule?({:__block__, _, [_ | _] = forms}), do: Enum.all?(forms, &defmodule?/1)
  defp defmodule?(_), do: false

  # Variables the TOP LEVEL of the input binds: the left sides of its
  # matches, in a block's statements and in a chain `a = b = 1`. A match
  # inside `case` or `fn` does not leak in Elixir, so it does not here.
  defp bound_vars({:__block__, _, forms}), do: forms |> Enum.flat_map(&bound_vars/1) |> Enum.uniq()
  defp bound_vars({:=, _, [lhs, rhs]}), do: Enum.uniq(pattern_vars(lhs) ++ bound_vars(rhs))
  defp bound_vars(_), do: []

  defp pattern_vars({:^, _, _}), do: []

  defp pattern_vars({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    s = Atom.to_string(name)
    if String.starts_with?(s, "_"), do: [], else: [name]
  end

  defp pattern_vars({_, _, args}) when is_list(args), do: Enum.flat_map(args, &pattern_vars/1)
  defp pattern_vars({a, b}), do: pattern_vars(a) ++ pattern_vars(b)
  defp pattern_vars(l) when is_list(l), do: Enum.flat_map(l, &pattern_vars/1)
  defp pattern_vars(_), do: []
end
