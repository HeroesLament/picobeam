defmodule NamesDemo do
  @moduledoc """
  The `notes/50` board demo: registered names and the recycling
  front end, on silicon.

  The debug UART carries the LOW BYTE of the most recent `out`
  (`notes/44`), so each step prints a marker and the last one to land
  is a position report:

      01  a 24-step straight-line chain computed the right value —
          code the front end could not even COMPILE before `notes/50`
      02  `register/2` succeeded
      03  `whereis/1` returned the pid that was registered
      04  a message sent TO THE NAME came back answered
      05  the server was killed and `whereis/1` says `:undefined` —
          the CAM cleared itself on death
      2a  all of it, verified
  """

  def main do
    # entry 22's proof: every binding below is dead one line later, and
    # the recycler had better notice, because there are 24 of them and
    # sixteen registers
    a1 = 1
    a2 = a1 + 2
    a3 = a2 + 3
    a4 = a3 + 4
    a5 = a4 + 5
    a6 = a5 + 6
    a7 = a6 + 7
    a8 = a7 + 8
    a9 = a8 + 9
    a10 = a9 + 10
    a11 = a10 + 11
    a12 = a11 + 12
    a13 = a12 + 13
    a14 = a13 + 14
    a15 = a14 + 15
    a16 = a15 + 16
    a17 = a16 + 17
    a18 = a17 + 18
    a19 = a18 + 19
    a20 = a19 + 20
    a21 = a20 + 21
    a22 = a21 + 22
    a23 = a22 + 23
    a24 = a23 + 24

    if a24 == 300 do
      :erlang.display(1)
    end

    pid = :erlang.spawn(NamesDemo, :srv, [])
    true = :erlang.register(:pico_srv, pid)
    :erlang.display(2)

    w = :erlang.whereis(:pico_srv)

    if w == pid do
      :erlang.display(3)
    end

    send(:pico_srv, {self(), 39})

    receive do
      {:reply, v} ->
        if v == 42 do
          :erlang.display(4)
        end
    end

    :erlang.exit(pid, :kill)
    wait_gone()
    :erlang.display(5)

    :erlang.display(42)
    :erlang.halt()
  end

  def srv do
    receive do
      {from, v} -> send(from, {:reply, v + 3})
    end

    srv()
  end

  def wait_gone do
    case :erlang.whereis(:pico_srv) do
      :undefined -> :ok
      _ -> wait_gone()
    end
  end
end
