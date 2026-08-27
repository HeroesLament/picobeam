defmodule Counter do
  @moduledoc """
  The walkthrough app: a registered counter server and a client,
  written the way you'd write it on real BEAM.
  """

  def main do
    # start the server and give it a NAME — no pid plumbing after this
    pid = :erlang.spawn(Counter, :server, [0])
    true = :erlang.register(:counter, pid)

    # clients talk to the NAME
    :ok = incr(5)
    :ok = incr(10)
    :ok = incr(27)

    :erlang.display(get())

    true = :erlang.unregister(:counter)
    :erlang.exit(pid, :kill)
    :erlang.halt()
  end

  # -- client API: the gen_server call shape --------------------------------
  def incr(n) do
    send(:counter, {:incr, self(), n})

    receive do
      {:ok, _new} -> :ok
    end
  end

  def get do
    send(:counter, {:get, self()})

    receive do
      {:value, v} -> v
    end
  end

  # -- the server loop: state as an argument, forever -----------------------
  def server(count) do
    receive do
      {:incr, from, n} ->
        send(from, {:ok, count + n})
        server(count + n)

      {:get, from} ->
        send(from, {:value, count})
        server(count)
    end
  end
end
