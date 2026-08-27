defmodule PicoBEAM.CounterSmpTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Ex, Machine}

  # The guard dog (`notes/52`/`notes/53`): the walkthrough app that
  # found the engine-is-a-node misconception, run in the configuration
  # that found it. If placement ever again makes an ordinary program's
  # `register/2` fail, this is the test that says so.
  test "the counter walkthrough runs on two engines, wherever the server lands" do
    prog = Ex.compile_file("priv/demo/counter.ex")

    {status, m} =
      prog
      |> Machine.new(engines: 2)
      |> Machine.boot(:"main/0", [])
      |> Machine.run(500_000)

    assert status == :halted
    assert m.out == [42]
    assert Enum.sort(Enum.map(m.stats.deaths, &elem(&1, 1))) == [:killed, :normal]
  end
end
