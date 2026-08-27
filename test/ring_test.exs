defmodule PicoBEAM.RingTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Machine}

  # The M1 demo (notes/07): a token ring across all nine engines of the
  # :balanced fit. The parent spawns nine workers (round-robin placement
  # lands one per engine), wires each worker to its successor by sending it
  # a pid, then injects an integer token that decrements at every hop.
  # Whoever holds zero reports :done to the parent.
  defp ring_program(_workers) do
    spawns =
      Enum.flat_map(0..8, fn i ->
        [
          [{:arg, 0, 0}],
          [{:spawn, 1 + i, :worker, 1}]
        ]
      end)

    wires =
      Enum.map(0..8, fn i ->
        [{:send, 1 + i, 1 + rem(i + 1, 9)}]
      end)

    main_body =
      [[{:self, 0}]] ++
        spawns ++
        wires ++
        [
          [{:ldi, 10, 26}],
          [{:send, 1, 10}],
          [{:recv, 11}],
          [{:halt}]
        ]

    Asm.assemble(%{
      main: {0, main_body},
      worker: {1,
       [
         [{:recv, 1}],
         :loop,
         [{:recv, 2}],
         [{:ldi, 3, 0}],
         [{:beq, 2, 3, :zero}],
         [{:ldi, 4, 1}],
         [{:sub, 5, 2, 4}],
         [{:send, 1, 5}],
         [{:jmp, :loop}],
         :zero,
         [{:lda, 6, :done}],
         [{:send, 0, 6}],
         [{:jmp, :loop}]
       ]}
    })
  end

  test "27-hop token ring across 9 engines completes, bounded and deterministic" do
    run = fn ->
      m =
        ring_program(9)
        |> Machine.new(engines: 9, contexts: 4)
        |> Machine.boot(:main, [])

      Machine.run(m, 100_000)
    end

    {:halted, m1} = run.()
    {:halted, m2} = run.()

    # the parent saw :done
    e = elem(m1.engines, 0)
    parent = Map.fetch!(e.procs, 0)
    assert Machine.decode(m1, 0, Map.fetch!(hd(parent.windows), 11)) == :done

    # nobody died getting there
    assert Machine.deaths(m1) |> Enum.reject(&match?({_, :normal}, &1)) == []

    # determinism: identical cycle count, run to run
    assert m1.cycle == m2.cycle

    # every wire latency is bounded by base + max hops + flits(1) for
    # single-word payloads — the send bound, checked on the model
    max_ok = 2 + 8 + 2
    assert Enum.all?(m1.stats.wire_latencies, &(&1 <= max_ok))
  end

  test "placement is round-robin across engines (Q6 default policy)" do
    m =
      ring_program(9)
      |> Machine.new(engines: 9, contexts: 4)
      |> Machine.boot(:main, [])

    {:halted, m} = Machine.run(m, 100_000)

    occupied =
      for eid <- 0..8 do
        elem(m.engines, eid).procs |> map_size()
      end

    # engine 0 hosts parent + worker0; engines 1..8 host one worker each
    assert occupied == [2, 1, 1, 1, 1, 1, 1, 1, 1]
  end
end
