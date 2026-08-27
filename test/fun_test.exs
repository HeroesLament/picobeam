defmodule PicoBEAM.FunTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Encoding, Machine, Term}

  # `notes/42`. A closure over one captured variable, called with one
  # argument: the callee is an ordinary function of arity 2, because the
  # free variable arrives as its LAST argument. That is BEAM's
  # `call_fun` convention and it is the reason there is no `fget`.
  defp adder_program do
    Asm.assemble(%{
      main:
        {0,
         [
           # capture 100
           [{:ldi, 1, 100}],
           [{:mkfun, 2, :adder, 1}],
           [{:tset, 2, 1, 1}],
           # call it with 5 -> 105
           [{:ldi, 3, 5}],
           [{:arg, 0, 3}, {:arg, 1, 2}],
           [{:callfun, 4, 2, 1}],
           [{:out, 4}],
           # and again with 1 -> 101, proving the closure is reusable
           [{:ldi, 5, 1}],
           [{:arg, 0, 5}, {:arg, 1, 2}],
           [{:callfun, 6, 2, 1}],
           [{:out, 6}],
           [{:halt}]
         ]},
      # arity 2: the visible argument, then the CLOSURE. The captured
      # variable is unpacked out of it with `fget`.
      adder: {2, [[{:fget, 2, 1, 1}], [{:add, 3, 0, 2}], [{:ret, 3}]]}
    })
  end

  defp run(prog, entry \\ :main) do
    prog |> Machine.new() |> Machine.boot(entry, []) |> Machine.run(20_000)
  end

  test "a closure captures a variable and adds it to its argument" do
    {status, m} = run(adder_program())
    assert status == :halted
    assert m.out == [105, 101]
  end

  test "the closure is a fun, not a tuple, and element/2 refuses it" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:mkfun, 1, :zero, 0}],
             [{:istag, 2, 1, :fun}],
             [{:out, 2}],
             [{:istag, 3, 1, :tuple}],
             [{:out, 3}],
             # `element/2` on a fun raises — the tag is the whole point
             [{:tget, 4, 1, 0}],
             [{:out, 4}],
             [{:halt}]
           ]},
        zero: {1, [[{:ldi, 1, 0}], [{:ret, 1}]]}
      })

    {_status, m} = run(prog)
    assert Enum.take(m.out_raw, 2) == [Term.atom(14), Term.atom(15)]
    assert [{_pid, :bad_tag}] = m.stats.deaths
  end

  test "calling a fun with the wrong arity is badarity, not badarg" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:mkfun, 1, :adder, 1}],
             [{:ldi, 2, 7}],
             [{:tset, 1, 1, 2}],
             [{:arg, 0, 2}, {:arg, 1, 2}],
             [{:arg, 2, 1}],
             [{:callfun, 3, 1, 2}],
             [{:out, 3}],
             [{:halt}]
           ]},
        adder: {2, [[{:fget, 2, 1, 1}], [{:add, 3, 0, 2}], [{:ret, 3}]]}
      })

    {_status, m} = run(prog)
    assert [{_pid, :badarity}] = m.stats.deaths
  end

  test "calling something that is not a fun is badfun" do
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 1, 3}],
             [{:callfun, 2, 1, 0}],
             [{:out, 2}],
             [{:halt}]
           ]}
      })

    {_status, m} = run(prog)
    assert [{_pid, :badfun}] = m.stats.deaths
  end

  test "a closure survives a collection with its captured variable" do
    # one live closure, a tuple of garbage per turn, a heap far too small
    prog =
      Asm.assemble(%{
        main:
          {0,
           [
             [{:ldi, 1, 41}],
             [{:mkfun, 2, :adder, 1}],
             [{:tset, 2, 1, 1}],
             [{:ldi, 3, 60}],
             [{:ldi, 4, 1}],
             :loop,
             # garbage: a fresh 2-tuple nobody keeps
             [{:mktup, 5, 2}],
             [{:tset, 5, 0, 3}],
             [{:tset, 5, 1, 3}],
             [{:sub, 3, 3, 4}],
             [{:ldi, 6, 0}],
             [{:cmpeq, 7, 3, 6}],
             [{:biff, 7, :loop}],
             # the closure still works, and still knows 41
             [{:arg, 0, 4}, {:arg, 1, 2}],
             [{:callfun, 8, 2, 1}],
             [{:out, 8}],
             [{:halt}]
           ]},
        adder: {2, [[{:fget, 2, 1, 1}], [{:add, 3, 0, 2}], [{:ret, 3}]]}
      })

    {status, m} = Machine.new(prog, heap_words: 64) |> Machine.boot(:main, []) |> Machine.run(50_000)
    assert status == :halted
    assert m.out == [42]
    assert length(Map.get(m.stats, :gc, [])) > 1
  end

  test "the image resolves a fun's entry to a bundle address in the pool" do
    prog = adder_program()
    img = Encoding.image(prog, :main)

    # `main` is placed first, so `adder` starts after it
    entry = img.bases[:adder]
    want = Term.funinfo(entry, 1, 1)
    assert want in img.pool

    # ...and the slot now names the pool index, not the function
    assert Enum.any?(img.image, &is_integer/1)
  end

end

