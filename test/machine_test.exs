defmodule PicoBEAM.MachineTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Machine}

  # Recursive factorial — exercises clean-on-call windows, arg staging,
  # the return-destination convention, and overflow trapping.
  defp fact_program do
    Asm.assemble(%{
      main: {1,
       [
         [{:arg, 0, 0}],
         [{:call, 1, :fact, 1}],
         [{:halt}]
       ]},
      fact: {1,
       [
         [{:ldi, 1, 1}],
         [{:blt, 1, 0, :recurse}],
         [{:ret, 1}],
         :recurse,
         [{:sub, 2, 0, 1}],
         [{:arg, 0, 2}],
         [{:call, 3, :fact, 1}],
         [{:mul, 4, 0, 3}],
         [{:ret, 4}]
       ]}
    })
  end

  defp root_window(m) do
    e = elem(m.engines, 0)
    hd(Map.fetch!(e.procs, 0).windows)
  end

  test "fact(12) computes through register windows" do
    m = fact_program() |> Machine.new() |> Machine.boot(:main, [12])
    {:halted, m} = Machine.run(m)
    assert Machine.decode(m, 0, Map.fetch!(root_window(m), 1)) == 479_001_600
  end

  test "fact(13) traps :overflow — fixnums never wrap" do
    m = fact_program() |> Machine.new() |> Machine.boot(:main, [13])
    {:quiescent, m} = Machine.run(m)
    assert [{_pid, :overflow}] = Machine.deaths(m)
  end

  test "reading a register the window never wrote is a fault (:uninit)" do
    prog = Asm.assemble(%{main: {0, [[{:mov, 1, 5}], [{:halt}]]}})
    m = prog |> Machine.new() |> Machine.boot(:main, [])
    {:quiescent, m} = Machine.run(m)
    assert [{_pid, :uninit}] = Machine.deaths(m)
  end

  test "the assembler rejects intra-bundle hazards (no bypass network)" do
    assert_raise Asm.Error, ~r/no bypass network/, fn ->
      Asm.assemble(%{main: {0, [[{:ldi, 1, 5}, {:mov, 2, 1}], [{:halt}]]}})
    end
  end

  test "the assembler rejects a system op that is not last" do
    assert_raise Asm.Error, ~r/last occupied slot/, fn ->
      Asm.assemble(%{main: {0, [[{:jmp, :x}, {:ldi, 1, 5}], :x, [{:halt}]]}})
    end
  end

  test "ping-pong: spawn, send, blocking recv, reply — deterministic cycles" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:self, 0}],
           [{:arg, 0, 0}, {:spawn, 1, :echo, 1}],
           [{:ldi, 2, 42}],
           [{:send, 1, 2}],
           [{:recv, 3}],
           [{:halt}]
         ]},
        echo: {1,
         [
           :loop,
           [{:recv, 1}],
           [{:send, 0, 1}],
           [{:jmp, :loop}]
         ]}
      })

    run = fn ->
      m = prog |> Machine.new(engines: 1, contexts: 4) |> Machine.boot(:main, [])
      Machine.run(m)
    end

    {:halted, m1} = run.()
    {:halted, m2} = run.()

    assert Machine.decode(m1, 0, Map.fetch!(root_window(m1), 3)) == 42
    assert m1.cycle == m2.cycle, "the model must be deterministic"
  end

  test "link + trap_exit: a crashing child arrives as {'EXIT', pid, badarith}" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:trapexit, 1}],
           [{:spawn, 1, :crasher, 0}],
           [{:link, 1}],
           [{:recv, 2}],
           [{:halt}]
         ]},
        crasher: {0,
         [
           # give the parent time to link before dying
           [{:ldi, 0, 0}],
           [{:ldi, 1, 40}],
           :spin,
           [{:ldi, 2, 1}],
           [{:add, 0, 0, 2}],
           [{:blt, 0, 1, :spin}],
           [{:lda, 3, :boom}],
           [{:add, 4, 3, 2}]
         ]}
      })

    m = prog |> Machine.new(engines: 1, contexts: 4) |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m)

    assert {:EXIT, {:pid, 0, _, _}, :badarith} =
             Machine.decode(m, 0, Map.fetch!(root_window(m), 2))

    assert {_pid, :badarith} = List.keyfind(Machine.deaths(m), :badarith, 1)
  end

  test "monitor: DOWN arrives with the ref and reason" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:spawn, 1, :quick, 0}],
           [{:monitor, 2, 1}],
           [{:recv, 3}],
           [{:halt}]
         ]},
        quick: {0,
         [
           [{:ldi, 0, 0}],
           [{:ldi, 1, 30}],
           :spin,
           [{:ldi, 2, 1}],
           [{:add, 0, 0, 2}],
           [{:blt, 0, 1, :spin}],
           [{:ldi, 4, 7}],
           [{:ret, 4}]
         ]}
      })

    m = prog |> Machine.new(engines: 1, contexts: 4) |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m)

    assert {:DOWN, {:ref, _}, {:pid, 0, _, _}, :normal} =
             Machine.decode(m, 0, Map.fetch!(root_window(m), 3))
  end
end
