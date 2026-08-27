defmodule PicoBEAM.SchedTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Machine}

  defp root_window(m) do
    e = elem(m.engines, 0)
    hd(Map.fetch!(e.procs, 0).windows)
  end

  defp root_reg(m, r), do: Machine.decode(m, 0, Map.fetch!(root_window(m), r))

  # A worker that spins `n` increments and reports its index to the parent.
  defp worker_body do
    [
      # r0 = parent, r1 = my index, r2 = n
      [{:ldi, 3, 0}],
      [{:ldi, 4, 1}],
      :spin,
      [{:add, 3, 3, 4}],
      [{:blt, 3, 2, :spin}],
      [{:send, 0, 1}],
      [{:ldn, 5}],
      [{:ret, 5}]
    ]
  end

  test "oversubscription: 6 CPU-bound workers share 2 seats and all finish" do
    spawns =
      Enum.flat_map(0..5, fn i ->
        [
          [{:ldi, 2, i}],
          [{:ldi, 3, 120}],
          [{:arg, 0, 0}],
          [{:arg, 1, 2}, {:arg, 2, 3}],
          [{:spawn, 4, :worker, 3}]
        ]
      end)

    recvs = Enum.map(0..5, fn i -> [{:recv, 5 + i}] end)

    prog =
      Asm.assemble(%{
        main: {0, [[{:self, 0}]] ++ spawns ++ recvs ++ [[{:halt}]]},
        worker: {3, worker_body()}
      })

    run = fn ->
      m =
        prog
        |> Machine.new(engines: 1, contexts: 2, budget: 32, swap_cost: 8)
        |> Machine.boot(:main, [])

      Machine.run(m, 500_000)
    end

    {:halted, m1} = run.()
    {:halted, m2} = run.()

    # all six reported (any order); the set of indices is complete
    got = Enum.map(5..10, &root_reg(m1, &1)) |> Enum.sort()
    assert got == [0, 1, 2, 3, 4, 5]

    refute Enum.any?(Machine.deaths(m1), fn {_, r} -> r != :normal end)
    assert m1.stats.swaps > 6, "expected real descheduling, saw #{m1.stats.swaps} swaps"
    assert m1.stats.swap_stall > 0
    assert m1.cycle == m2.cycle, "scheduling must be deterministic"
  end

  test "a lone resident is never descheduled: budget resets, seat kept (Q9)" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:ldi, 1, 0}],
           [{:ldi, 2, 500}],
           [{:ldi, 3, 1}],
           :spin,
           [{:add, 1, 1, 3}],
           [{:blt, 1, 2, :spin}],
           [{:halt}]
         ]}
      })

    m = prog |> Machine.new(budget: 16) |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m, 100_000)

    # direct seating at spawn/boot is not a swap; budget exhausted many
    # times with an empty queue and never cost the seat
    assert m.stats.swaps == 0
    assert root_reg(m, 1) == 500
  end

  test "blocked residents are evicted for runnable work, and re-queue on wake" do
    # T=1: parent blocks on recv -> evicted for the worker; worker reports
    # and exits; parent wakes from the queue and completes.
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:self, 0}],
           [{:ldi, 2, 99}],
           [{:ldi, 3, 60}],
           [{:arg, 0, 0}],
           [{:arg, 1, 2}, {:arg, 2, 3}],
           [{:spawn, 4, :worker, 3}],
           [{:recv, 5}],
           [{:halt}]
         ]},
        worker: {3, worker_body()}
      })

    m =
      prog
      |> Machine.new(engines: 1, contexts: 1, budget: 32, swap_cost: 4)
      |> Machine.boot(:main, [])

    {:halted, m} = Machine.run(m, 200_000)

    assert root_reg(m, 5) == 99
    # eviction of the blocked parent + the parent's wake re-seat
    assert m.stats.swaps >= 2
  end

  test "yield rotates to waiting work immediately" do
    # two pingers on one seat, each yielding every iteration; both must
    # interleave to completion well before any budget expiry (budget huge)
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:self, 0}],
           [{:ldi, 2, 0}],
           [{:ldi, 3, 40}],
           [{:arg, 0, 0}],
           [{:arg, 1, 2}, {:arg, 2, 3}],
           [{:spawn, 4, :yielder, 3}],
           [{:ldi, 2, 1}],
           [{:arg, 0, 0}],
           [{:arg, 1, 2}, {:arg, 2, 3}],
           [{:spawn, 5, :yielder, 3}],
           [{:recv, 6}],
           [{:recv, 7}],
           [{:halt}]
         ]},
        yielder: {3,
         [
           [{:ldi, 3, 0}],
           [{:ldi, 4, 1}],
           :spin,
           [{:add, 3, 3, 4}],
           [{:yield}],
           [{:blt, 3, 2, :spin}],
           [{:send, 0, 1}],
           [{:ldn, 5}],
           [{:ret, 5}]
         ]}
      })

    m =
      prog
      |> Machine.new(engines: 1, contexts: 1, budget: 10_000, swap_cost: 2)
      |> Machine.boot(:main, [])

    {:halted, m} = Machine.run(m, 200_000)

    assert Enum.sort([root_reg(m, 6), root_reg(m, 7)]) == [0, 1]
    # each yield with waiters costs a swap; 2 x 40 iterations floor
    assert m.stats.swaps > 40
  end

  test "the 64-slot proc table is :system_limit on the spawner" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:ldi, 1, 0}],
           [{:ldi, 2, 70}],
           [{:ldi, 3, 1}],
           :loop,
           [{:spawn, 4, :sleeper, 0}],
           [{:add, 1, 1, 3}],
           [{:blt, 1, 2, :loop}],
           [{:halt}]
         ]},
        sleeper: {0,
         [
           [{:recv, 0}],
           [{:ldn, 1}],
           [{:ret, 1}]
         ]}
      })

    m = prog |> Machine.new(engines: 1, contexts: 4) |> Machine.boot(:main, [])
    {:quiescent, m} = Machine.run(m, 500_000)

    assert {_pid, :system_limit} = List.keyfind(Machine.deaths(m), :system_limit, 1)
  end
end
