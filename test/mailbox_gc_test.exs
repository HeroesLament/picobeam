defmodule PicoBEAM.MailboxGCTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Asm, Machine}

  defp root_window(m) do
    e = elem(m.engines, 0)
    hd(Map.fetch!(e.procs, 0).windows)
  end

  defp root_reg(m, r), do: Machine.decode(m, 0, Map.fetch!(root_window(m), r))

  # ---------------------------------------------------------------------------
  # Selective receive
  # ---------------------------------------------------------------------------

  test "selective receive takes a later {:b, _} past earlier {:a, _}s, order preserved after" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:self, 0}],
           [{:arg, 0, 0}, {:spawn, 1, :child, 1}],
           # {:a, 1}
           [{:mktup, 2, 2}],
           [{:lda, 3, :a}],
           [{:tset, 2, 0, 3}],
           [{:ldi, 4, 1}],
           [{:tset, 2, 1, 4}],
           [{:send, 1, 2}],
           # {:b, 2}
           [{:mktup, 5, 2}],
           [{:lda, 6, :b}],
           [{:tset, 5, 0, 6}],
           [{:ldi, 7, 2}],
           [{:tset, 5, 1, 7}],
           [{:send, 1, 5}],
           # {:a, 3}
           [{:mktup, 8, 2}],
           [{:tset, 8, 0, 3}],
           [{:ldi, 9, 3}],
           [{:tset, 8, 1, 9}],
           [{:send, 1, 8}],
           # collect three replies in arrival order
           [{:recv, 10}],
           [{:recv, 11}],
           [{:recv, 12}],
           [{:halt}]
         ]},
        child: {1,
         [
           # selectively wait for the {:b, _} shape first
           [{:recv_start}],
           [{:recv_hash, {:tuple, 2, :b}}],
           :scan,
           [{:recv_peek, 1, :none}],
           [{:recv_take, 2}],
           [{:jmp, :got_b}],
           :none,
           [{:recv_wait}],
           [{:jmp, :scan}],
           :got_b,
           [{:send, 0, 2}],
           # then drain in order
           [{:recv, 3}],
           [{:send, 0, 3}],
           [{:recv, 4}],
           [{:send, 0, 4}],
           [{:ldn, 5}],
           [{:ret, 5}]
         ]}
      })

    run = fn ->
      m = prog |> Machine.new(engines: 1, contexts: 4) |> Machine.boot(:main, [])
      Machine.run(m, 50_000)
    end

    {:halted, m1} = run.()
    {:halted, m2} = run.()

    assert root_reg(m1, 10) == {:b, 2}
    assert root_reg(m1, 11) == {:a, 1}
    assert root_reg(m1, 12) == {:a, 3}
    refute Enum.any?(Machine.deaths(m1), fn {_, r} -> r != :normal end)
    assert m1.cycle == m2.cycle, "selective receive must not break determinism"
  end

  test "recv_waitt: timeout path taken when nothing arrives" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:recv_start}],
           [{:ldi, 1, 50}],
           :wait,
           [{:recv_waitt, 1, :timed_out}],
           # a message arrived (never happens here)
           [{:lda, 2, :got_message}],
           [{:halt}],
           :timed_out,
           [{:lda, 2, :timeout}],
           [{:halt}]
         ]}
      })

    m = prog |> Machine.new() |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m, 10_000)

    assert root_reg(m, 2) == :timeout
    assert m.cycle >= 50
  end

  # ---------------------------------------------------------------------------
  # Garbage collection
  # ---------------------------------------------------------------------------

  test "live data survives collections while garbage is reclaimed" do
    # live list [20, 10] built first; then 150 garbage tuples (4 words each)
    # churn through a 128-word semispace — several collections required.
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:ldn, 1}],
           [{:ldi, 2, 10}],
           [{:cons, 3, 2, 1}],
           [{:ldi, 4, 20}],
           [{:cons, 5, 4, 3}],
           # loop: i in r6, limit r7, one r8
           [{:ldi, 6, 0}],
           [{:ldi, 7, 150}],
           [{:ldi, 8, 1}],
           :loop,
           [{:mktup, 9, 3}],
           [{:tset, 9, 0, 6}],
           [{:add, 6, 6, 8}],
           [{:blt, 6, 7, :loop}],
           [{:halt}]
         ]}
      })

    m = prog |> Machine.new(heap_words: 128) |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m, 100_000)

    assert root_reg(m, 5) == [20, 10]
    # `halt` reaps its caller now (notes/33), the way the netlist's
    # `dbg_deaths` always has, so `normal` is expected here. Anything
    # else means something crashed, which is what this ever meant.
    assert Machine.deaths(m) |> Enum.reject(&match?({_, :normal}, &1)) == []
    assert length(m.stats.gc) >= 2, "expected multiple collections, got #{length(m.stats.gc)}"

    # every collection's live set fit comfortably in a semispace
    assert Enum.all?(m.stats.gc, fn {_cyc, _eid, live} -> live < 128 end)
  end

  test "live data exceeding a semispace is :heap_full, not a hang" do
    # grow a live list forever on a tiny heap
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:ldn, 1}],
           [{:ldi, 2, 7}],
           :loop,
           [{:cons, 1, 2, 1}],
           [{:jmp, :loop}]
         ]}
      })

    m = prog |> Machine.new(heap_words: 64) |> Machine.boot(:main, [])
    {:quiescent, m} = Machine.run(m, 100_000)

    assert [{_pid, :heap_full}] = Machine.deaths(m)
  end

  test "a collection mid-bundle keeps the in-flight window coherent" do
    # cons chains where every allocation's operands come from registers that
    # themselves point into the heap — any stale-root bug corrupts the list.
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:ldn, 1}],
           [{:ldi, 6, 0}],
           [{:ldi, 7, 30}],
           [{:ldi, 8, 1}],
           :loop,
           [{:cons, 2, 6, 1}],
           [{:cons, 3, 6, 2}],
           [{:hd, 4, 3}],
           [{:mov, 1, 2}],
           [{:add, 6, 6, 8}],
           [{:blt, 6, 7, :loop}],
           [{:halt}]
         ]}
      })

    m = prog |> Machine.new(heap_words: 96) |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m, 200_000)

    # `halt` reaps its caller now (notes/33), the way the netlist's
    # `dbg_deaths` always has, so `normal` is expected here. Anything
    # else means something crashed, which is what this ever meant.
    assert Machine.deaths(m) |> Enum.reject(&match?({_, :normal}, &1)) == []
    assert length(m.stats.gc) >= 1
    # r1 holds the list [29, 28, ..., 0]
    assert root_reg(m, 1) == Enum.to_list(29..0//-1)
    assert root_reg(m, 4) == 29
  end

  # ---------------------------------------------------------------------------
  # Bounded mailboxes
  # ---------------------------------------------------------------------------

  test "mailbox overflow exits the receiver :mailbox_full; monitor reports it" do
    prog =
      Asm.assemble(%{
        main: {0,
         [
           [{:spawn, 1, :sink, 0}],
           [{:monitor, 2, 1}],
           [{:ldi, 3, 7}],
           [{:ldi, 4, 0}],
           [{:ldi, 5, 24}],
           [{:ldi, 6, 1}],
           :flood,
           [{:send, 1, 3}],
           [{:add, 4, 4, 6}],
           [{:blt, 4, 5, :flood}],
           [{:recv, 7}],
           [{:halt}]
         ]},
        sink: {0,
         [
           # never receives; just burns its slot
           [{:ldi, 0, 0}],
           :spin,
           [{:jmp, :spin}]
         ]}
      })

    m = prog |> Machine.new(mailbox_depth: 16) |> Machine.boot(:main, [])
    {:halted, m} = Machine.run(m, 100_000)

    assert {:DOWN, {:ref, _}, {:pid, 0, _, _}, :mailbox_full} = root_reg(m, 7)
    assert {_pid, :mailbox_full} = List.keyfind(Machine.deaths(m), :mailbox_full, 1)
  end
end
