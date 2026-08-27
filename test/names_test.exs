defmodule PicoBEAM.NamesTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Ex, Machine}

  # `notes/50` — register/whereis/unregister, and `Name ! Msg`.

  defp run_main(src, opts \\ []) do
    prog = Ex.compile_string(src)

    {status, m} =
      prog
      |> Machine.new(opts)
      |> Machine.boot(:"main/0", [])
      |> Machine.run(500_000)

    {status, m}
  end

  test "register, whereis, send-to-name, unregister round trip" do
    {status, m} =
      run_main("""
      defmodule NameDemo do
        def main do
          pid = :erlang.spawn(NameDemo, :echo, [])
          true = :erlang.register(:echo_srv, pid)

          # whereis finds it, and it is the same pid
          ^pid = :erlang.whereis(:echo_srv)

          # send THROUGH the name
          send(:echo_srv, {self(), 41})

          receive do
            {:reply, v} -> :erlang.display(v + 1)
          end

          true = :erlang.unregister(:echo_srv)
          :undefined = :erlang.whereis(:echo_srv)
          :erlang.display(:ok)
          :erlang.halt()
        end

        def echo do
          receive do
            {from, v} -> send(from, {:reply, v})
          end

          echo()
        end
      end
      """)

    assert status == :halted
    assert m.out == [42, :ok]
  end

  test "whereis on a never-registered name is :undefined" do
    {status, m} =
      run_main("""
      defmodule UndefDemo do
        def main do
          :erlang.display(:erlang.whereis(:nobody))
          :erlang.halt()
        end
      end
      """)

    assert status == :halted
    assert m.out == [:undefined]
  end

  test "a dying process auto-unregisters, and its name can be taken again" do
    {status, m} =
      run_main("""
      defmodule AutoDemo do
        def main do
          pid = :erlang.spawn(AutoDemo, :mortal, [])
          true = :erlang.register(:worker, pid)
          send(:worker, :die)
          wait_gone()
          # re-register under the same name: only legal if the death
          # released it
          me = self()
          true = :erlang.register(:worker, me)
          ^me = :erlang.whereis(:worker)
          :erlang.display(:ok)
          :erlang.halt()
        end

        def mortal do
          receive do
            :die -> :ok
          end
        end

        def wait_gone do
          case :erlang.whereis(:worker) do
            :undefined -> :ok
            _ -> wait_gone()
          end
        end
      end
      """)

    assert status == :halted
    assert m.out == [:ok]
  end

  test "double registration is badarg on the caller" do
    {status, m} =
      run_main("""
      defmodule DupDemo do
        def main do
          true = :erlang.register(:me, self())
          child = :erlang.spawn(DupDemo, :idle, [])
          # a second registration of the SAME name must fail
          :erlang.register(:me, child)
          :erlang.display(:unreachable)
          :erlang.halt()
        end

        def idle do
          receive do
            _ -> :ok
          end
        end
      end
      """)

    # main dies of badarg; nothing prints, nothing halts the VM
    assert status != :halted
    assert m.out == []
    assert [{_, :badarg} | _] = m.stats.deaths
  end

  test "send to an unregistered name is badarg" do
    {status, m} =
      run_main("""
      defmodule NoNameDemo do
        def main do
          send(:ghost, :hello)
          :erlang.display(:unreachable)
          :erlang.halt()
        end
      end
      """)

    assert status != :halted
    assert m.out == []
    assert [{_, :badarg} | _] = m.stats.deaths
  end

  test "the registry is node-global: engine 1 sees engine 0's names" do
    {status, m} =
      run_main(
        """
        defmodule TwoEngDemo do
          def main do
            true = :erlang.register(:root, self())
            me = self()
            # first spawn stays home; the second (immediate args)
            # round-robins to engine 1 and asks for the name THERE
            _local = :erlang.spawn(TwoEngDemo, :probe, [me])

            receive do
              {:saw, v} -> :erlang.display(is_pid(v))
            end

            _remote = :erlang.spawn(TwoEngDemo, :probe, [me])

            receive do
              {:saw, v} -> :erlang.display(is_pid(v))
            end

            :erlang.halt()
          end

          def probe(reply_to) do
            send(reply_to, {:saw, :erlang.whereis(:root)})
          end
        end
        """,
        engines: 2
      )

    assert status == :halted
    # BOTH children see the pid — `notes/53`: an engine is a scheduler,
    # the machine is the node, and the registry belongs to the node.
    # (This test asserted the opposite for one note's time.)
    assert m.out == [true, true]
  end

  test "a child the round-robin placed remote can be registered" do
    # the counter walkthrough's exact failure (`notes/52`), asserted
    # green: spawn -> other engine -> register -> send by name
    {status, m} =
      run_main(
        """
        defmodule RemRegDemo do
          def main do
            # first spawn stays home, second crosses (notes/49 placement)
            _local = :erlang.spawn(RemRegDemo, :idle, [])
            remote = :erlang.spawn(RemRegDemo, :echo, [])
            true = :erlang.register(:far_srv, remote)
            send(:far_srv, {self(), 41})

            receive do
              {:reply, v} -> :erlang.display(v + 1)
            end

            :erlang.display(:erlang.whereis(:far_srv) == remote)
            :erlang.halt()
          end

          def idle do
            receive do
              _ -> :ok
            end
          end

          def echo do
            receive do
              {from, v} -> send(from, {:reply, v})
            end

            echo()
          end
        end
        """,
        engines: 2
      )

    assert status == :halted
    assert m.out == [42, true]
  end
end
