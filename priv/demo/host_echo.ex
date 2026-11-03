defmodule HostEcho do
  # The first program to talk to the host (ring node 15, `RingHost`).
  # Engine 0 says hello by sending its own pid to the host, then answers
  # every integer the host sends with that integer plus one. Immediates
  # only, so each message is one head and one flit each way.

  def main do
    send(:erlang.host(), self())
    loop()
  end

  def loop do
    receive do
      n ->
        send(:erlang.host(), n + 1)
        loop()
    end
  end
end
