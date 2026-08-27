defmodule PicoBEAM.Serial do
  @moduledoc """
  The message wire format: a term, flattened into 36-bit flits.

  `notes/03` draws send as `serialiser (term walk → flits) → ring →
  mailbox writer`, and `notes/17` decision 5 says compound messages are
  **copied**. This module is the flattening, in Elixir, so that the RTL
  serialiser has an oracle to agree with — the same discipline the
  opcode table and the shape hash get, and for the same reason: a wire
  format specified twice drifts.

  ## Why copy at all, when v1 has one engine

  Two processes on one engine share that engine's heap, so a send could
  pass a pointer and cost nothing. Two reasons it does not:

  * **The ring is M6.** A cross-engine send has no choice — Bet 1 says
    no shared heap between engines — and a format that only works
    in-engine would have to be replaced the moment the ring lands.
  * **`tset` mutates.** The ISA lets a tuple element be overwritten.
    The front end only emits `tset` while a tuple is being built, so
    sharing would be safe *by compiler discipline* — and a machine
    whose message-passing semantics rest on compiler discipline is one
    hand-written bundle away from a shared-mutable-state bug that
    Erlang programmers have every right to assume is impossible.

  ## The format: postfix

  Flits are emitted in **postfix** (reverse Polish) order:

      42                  ->  [42]
      {1, 2, 3}           ->  [1, 2, 3, HDR|3]
      [1 | 2]             ->  [1, 2, WCONS]
      {1, [2 | 3]}        ->  [1, 2, 3, WCONS, HDR|2]

  Postfix rather than prefix because of who pays. In prefix order a
  reconstructor meets `HDR|3` before it has any of the three elements,
  so it must allocate the tuple and then patch it as the elements
  arrive — which needs a stack of *unfinished cells*. In postfix every
  marker arrives with its children already built and sitting on a value
  stack, so reconstruction is:

      immediate  ->  push it
      HDR|n      ->  pop n, mktup, tset them, push the pointer
      WCONS      ->  pop tail, pop head, cons, push the pointer

  One heap op per marker, no patching, no resume state, and the stack
  holds finished terms rather than half-built ones. Exactly one value
  is left at the end, and that is the message.

  ## Bounds

  Depth is capped at #{8} nested compounds and a message at #{63}
  flits; either overrun is `:system_limit`, the reserved atom the
  machine already uses for "the shape of this program exceeded a
  hardware resource". They are checked HERE as well as in gates so the
  model and the netlist refuse the same programs.

  The flit cap is 63 because the mailbox stores a message's length in
  six bits alongside its shape hash, which is what lets the match unit
  step over a whole non-matching message in one cycle instead of one
  flit at a time.
  """

  import Bitwise

  alias PicoBEAM.Term

  @max_depth 8
  @max_flits 63

  def max_depth, do: @max_depth
  def max_flits, do: @max_flits

  @wcons Term.make(:wcons, 0)

  def wcons_word, do: @wcons

  @doc """
  Flatten a heap term into its flit list.

  `heap` is a `fn pointer_word -> {:tuple, arity, [elems]} | {:cons, h, t}`
  resolver, so this works against `Machine`'s word-addressed heap and
  against a plain Elixir term alike.

  Returns `{:ok, flits}` or `{:error, :system_limit}`.
  """
  def flits(term, resolve) do
    try do
      out = walk(term, resolve, 0, [])

      cond do
        length(out) > @max_flits -> {:error, :system_limit}
        true -> {:ok, Enum.reverse(out)}
      end
    catch
      :too_deep -> {:error, :system_limit}
    end
  end

  # `acc` is built in reverse, so a postfix walk appends children first
  # and the marker last — which is the same thing as prepending the
  # marker before the children onto a reversed list.
  defp walk(_term, _resolve, depth, _acc) when depth > @max_depth, do: throw(:too_deep)

  defp walk(term, resolve, depth, acc) do
    case resolve.(term) do
      :immediate ->
        [term | acc]

      {:tuple, arity, elems} ->
        acc = Enum.reduce(elems, acc, &walk(&1, resolve, depth + 1, &2))
        [Term.make(:hdr, arity) | acc]

      {:cons, h, t} ->
        acc = walk(h, resolve, depth + 1, acc)
        acc = walk(t, resolve, depth + 1, acc)
        [@wcons | acc]
    end
  end

  @doc """
  Rebuild a flit list, exactly as the receive side's FSM does: a value
  stack, one construction per marker, one value left at the end.

  `build` is `fn {:tuple, elems} | {:cons, h, t} -> pointer_word`.
  Returns `{:ok, term}` or `{:error, reason}` — and the errors are the
  ones the hardware can actually hit: a marker with nothing under it,
  or flits left over.
  """
  def rebuild(flits, build) do
    Enum.reduce_while(flits, {:ok, []}, fn flit, {:ok, stack} ->
      cond do
        flit == @wcons ->
          case stack do
            [t, h | rest] -> {:cont, {:ok, [build.({:cons, h, t}) | rest]}}
            _ -> {:halt, {:error, :underflow}}
          end

        # `is_integer` because the flit may be a plain Elixir term here:
        # `rebuild/2` is used both against real 36-bit words and, in
        # tests, against Elixir values through `elixir_resolver/1`, where
        # `[]` is a perfectly good immediate that is not a number.
        is_integer(flit) and Term.is?(flit, :hdr) ->
          n = Term.payload(flit)

          if length(stack) < n do
            {:halt, {:error, :underflow}}
          else
            {taken, rest} = Enum.split(stack, n)
            {:cont, {:ok, [build.({:tuple, Enum.reverse(taken)}) | rest]}}
          end

        true ->
          {:cont, {:ok, [flit | stack]}}
      end
    end)
    |> case do
      {:ok, [one]} -> {:ok, one}
      {:ok, _many} -> {:error, :leftover}
      {:error, r} -> {:error, r}
    end
  end

  @doc """
  The resolver for plain Elixir terms — used by tests and by
  `Encoding`-side tools that have no heap.
  """
  def elixir_resolver(t) do
    cond do
      is_tuple(t) -> {:tuple, tuple_size(t), Tuple.to_list(t)}
      is_list(t) and t != [] -> {:cons, hd(t), tl(t)}
      true -> :immediate
    end
  end

  @doc "Flit count without building the list — the length field's oracle."
  def flit_count(term, resolve) do
    case flits(term, resolve) do
      {:ok, f} -> {:ok, length(f)}
      e -> e
    end
  end

  @doc false
  def hdr_word(arity), do: Term.make(:hdr, arity)

  @doc false
  def marker?(word),
    do: word == @wcons or (is_integer(word) and (word >>> 32) == Term.tag_value(:hdr))
end
