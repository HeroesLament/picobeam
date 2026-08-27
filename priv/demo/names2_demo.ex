# tb_names2 — the registry is NODE state, not engine state (notes/53).
#
# One image, two engines. Placement is round-robin from home, so the
# first spawn stays on engine 0 and the second crosses to engine 1.
# Every claim below is a thing the per-engine registry could not do:
#
#   * the client, on engine 1, resolves :srv — registered on engine 0
#     — and sends to it BY NAME (the CAM hit carries the pid's engine
#     field, so 77 crosses the ring)
#   * the client registers ITSELF (:cli) through the CAM's B port
#   * the client registers a REMOTE pid (:far — the idle process, which
#     lives on engine 0): aliveness comes from the peer engine's probe
#     port, not the local table
#   * whereis on engine 0 sees both names engine 1 wrote
#   * send-by-name crosses back (:cli resolves to an engine-1 pid)
#   * unregister + miss still answer :undefined
#
# A pid may hold only ONE registered name (register is badarg on a
# pid_taken), which is why :far names the idle process and not the
# client — the first draft of this file learned that from the model.
defmodule Names2 do
  def main do
    true = :erlang.register(:srv, self())
    local = :erlang.spawn(Names2, :idle, [])
    remote = :erlang.spawn(Names2, :client, [local])

    receive do
      {:hello, v} -> :erlang.display(v)
    end

    # the :hello above is sent AFTER the client registers, and proves
    # the client exists — so everything below is race-free. The paired
    # displays must be the same pid word — the expect file, not an ==,
    # carries the claim.
    :erlang.display(remote)
    :erlang.display(:erlang.whereis(:cli))
    :erlang.display(local)
    :erlang.display(:erlang.whereis(:far))

    send(:cli, {:token, 88})

    receive do
      {:echo, v} -> :erlang.display(v)
    end

    true = :erlang.unregister(:srv)
    :erlang.display(:erlang.whereis(:srv))
    :erlang.halt()
  end

  def idle do
    receive do
      _ -> :ok
    end
  end

  def client(buddy) do
    true = :erlang.register(:cli, self())
    true = :erlang.register(:far, buddy)
    send(:srv, {:hello, 77})

    receive do
      {:token, v} -> send(:srv, {:echo, v})
    end

    receive do
      _ -> :ok
    end
  end
end
