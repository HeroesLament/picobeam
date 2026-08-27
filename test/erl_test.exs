defmodule PicoBEAM.ErlTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Erl, Machine}

  defp run(source, entry, args \\ [], opts \\ []) do
    m =
      source
      |> Erl.compile()
      |> Machine.new(Keyword.merge([engines: 4, contexts: 4], opts))
      |> Machine.boot(entry, args)

    Machine.run(m, 500_000)
  end

  test "factorial: recursion, case, arithmetic — Erlang source to result" do
    src = """
    -module(t1).
    -export([main/1]).
    main(N) -> erlang:display(fact(N)), erlang:halt().
    fact(N) ->
        case N < 2 of
            true -> 1;
            false -> N * fact(N - 1)
        end.
    """

    {:halted, m} = run(src, :"main/1", [12])
    assert m.out == [479_001_600]
  end

  test "factorial overflow traps :overflow from compiled code too" do
    src = """
    -module(t1b).
    -export([main/1]).
    main(N) -> erlang:display(fact(N)), erlang:halt().
    fact(N) ->
        case N < 2 of
            true -> 1;
            false -> N * fact(N - 1)
        end.
    """

    {:quiescent, m} = run(src, :"main/1", [13])
    assert m.out == []
    assert [{_pid, :overflow}] = Machine.deaths(m)
  end

  test "multi-head functions (case over values) and tail recursion" do
    src = """
    -module(t2).
    -export([main/0, count/2]).
    main() -> erlang:display(count(100, 0)), erlang:halt().
    count(0, Acc) -> Acc;
    count(N, Acc) -> count(N - 1, Acc + N).
    """

    {:halted, m} = run(src, :"main/0")
    assert m.out == [5050]
  end

  test "spawn, send, receive: ping-pong from Erlang source" do
    src = """
    -module(t3).
    -export([main/0, echo/1]).
    main() ->
        S = self(),
        Pid = spawn(t3, echo, [S]),
        Pid ! 42,
        receive X -> erlang:display(X) end,
        erlang:halt().
    echo(P) ->
        receive M -> P ! M end,
        echo(P).
    """

    {:halted, m} = run(src, :"main/0")
    assert m.out == [42]
  end

  test "selective receive in Erlang: {b,_} taken past earlier {a,_}s" do
    src = """
    -module(t4).
    -export([main/0, child/1, show/1]).
    main() ->
        S = self(),
        C = spawn(t4, child, [S]),
        C ! {a, 1},
        C ! {b, 2},
        C ! {a, 3},
        show(3),
        erlang:halt().
    show(0) -> ok;
    show(N) ->
        receive X -> erlang:display(X) end,
        show(N - 1).
    child(P) ->
        receive {b, V} -> P ! {first, V} end,
        drain(P).
    drain(P) ->
        receive M -> P ! M end,
        drain(P).
    """

    {:halted, m} = run(src, :"main/0")
    assert m.out == [{:first, 2}, {:a, 1}, {:a, 3}]
  end

  test "trap_exit + link: a crashing child arrives as {'EXIT', _, badarith}" do
    src = """
    -module(t5).
    -export([main/0, crasher/0]).
    main() ->
        process_flag(trap_exit, true),
        Pid = spawn(t5, crasher, []),
        link(Pid),
        Pid ! go,
        receive {'EXIT', _P, Reason} -> erlang:display(Reason) end,
        erlang:halt().
    crasher() ->
        receive go -> erlang:display(1 + x) end.
    """

    {:halted, m} = run(src, :"main/0")
    assert m.out == [:badarith]
  end

  test "monitor of a dead pid answers DOWN noproc over the ring" do
    src = """
    -module(t6).
    -export([main/0, quick/0]).
    main() ->
        Pid = spawn(t6, quick, []),
        wait(200),
        _Ref = monitor(process, Pid),
        receive {'DOWN', _R, _P, Reason} -> erlang:display(Reason) end,
        erlang:halt().
    quick() -> done.
    wait(0) -> ok;
    wait(N) -> wait(N - 1).
    """

    {:halted, m} = run(src, :"main/0")
    assert m.out == [:noproc]
  end

  test "receive timeout: after N -> action" do
    src = """
    -module(t7).
    -export([main/0]).
    main() ->
        receive
            X -> erlang:display(X)
        after 80 ->
            erlang:display(timeout)
        end,
        erlang:halt().
    """

    {:halted, m} = run(src, :"main/0")
    assert m.out == [:timeout]
    assert m.cycle >= 80
  end

  test "THE M1 DEMO: 9-worker token ring, from Erlang source, deterministic" do
    src = """
    -module(ring).
    -export([main/0, worker/1]).
    main() ->
        S = self(),
        F = spawn(ring, worker, [S]),
        Head = mk(8, S, F),
        F ! Head,
        Head ! 27,
        receive done -> erlang:display(ring_done) end,
        erlang:halt().
    mk(N, S, Next) ->
        case N of
            0 -> Next;
            _ ->
                P = spawn(ring, worker, [S]),
                P ! Next,
                mk(N - 1, S, P)
        end.
    worker(S) ->
        receive Next -> wloop(S, Next) end.
    wloop(S, Next) ->
        receive
            0 -> S ! done, wloop(S, Next);
            N -> Next ! N - 1, wloop(S, Next)
        end.
    """

    run_ring = fn ->
      m =
        src
        |> Erl.compile()
        |> Machine.new(engines: 9, contexts: 4)
        |> Machine.boot(:"main/0", [])

      Machine.run(m, 500_000)
    end

    {:halted, m1} = run_ring.()
    {:halted, m2} = run_ring.()

    assert m1.out == [:ring_done]
    refute Enum.any?(Machine.deaths(m1), fn {_, r} -> r != :normal end)
    assert m1.cycle == m2.cycle, "Erlang-sourced execution must stay deterministic"

    # one worker per engine beyond engine 0 (round-robin placement)
    occupied = for eid <- 0..8, do: map_size(elem(m1.engines, eid).procs)
    assert occupied == [2, 1, 1, 1, 1, 1, 1, 1, 1]
  end

  test "a list comprehension compiles, by lifting its letrec fun" do
    # This test used to assert the OPPOSITE — that a comprehension was
    # refused — because `letrec` was unsupported. `erlc` turns a
    # comprehension into a self-recursive fun in a letrec, and the front
    # end now lifts that fun to a top-level function, which is exact for
    # this shape: it closes over nothing but its own parameter.
    src = """
    -module(t8).
    -export([main/0]).
    main() -> L = [X * 2 || X <- [1, 2, 3]], erlang:display(L), erlang:halt().
    """

    prog = Erl.compile(src)
    assert Map.has_key?(prog, :"main/0$lc$^0/1")

    m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
    {_status, m} = Machine.run(m, 200_000)
    assert m.out == [[2, 4, 6]]
  end

  test "unsupported constructs still fail loudly at compile time" do
    # The front end refuses what it cannot do, by name, rather than
    # emitting something plausible. (`register/2` was the example here
    # until `notes/50` built it — ports are still honestly absent.)
    src = """
    -module(t9).
    -export([main/0]).
    main() -> erlang:port_command(foo, <<1>>), erlang:halt().
    """

    assert_raise Erl.CompileError, ~r/unsupported/, fn -> Erl.compile(src) end
  end
end
