defmodule PicoBEAM.SupSmpTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.{Erl, Machine}

  # notes/53 Phase 4 — supervision crosses engines. These are the
  # model halves of tb_slink2 / tb_mon2, kept as permanent tests: the
  # expect files those testbenches compare against are regenerated
  # from exactly these programs, so if the model's cross-engine signal
  # semantics drift, this fails before a simulation ever runs.

  defp run2(src) do
    File.mkdir_p!("/tmp/pb_erl")
    path = "/tmp/pb_erl/supsmp_#{:erlang.unique_integer([:positive])}.erl"
    File.write!(path, src)
    prog = Erl.compile_file(path)

    {status, m} =
      prog
      |> Machine.new(engines: 2)
      |> Machine.boot(:"main/0", [])
      |> Machine.run(2_000_000)

    {status, m}
  end

  test "links cross engines: abnormal, normal, and noproc exits all arrive" do
    {status, m} =
      run2("""
      -module(sl2t).
      -export([main/0, idle/0, worker/0, quick/0]).
      main() ->
          process_flag(trap_exit, true),
          _L = erlang:spawn(sl2t, idle, []),
          W = erlang:spawn(sl2t, worker, []),
          erlang:link(W),
          W ! go,
          receive {'EXIT', P1, R1} -> erlang:display(P1), erlang:display(R1) end,
          _F = erlang:spawn(sl2t, idle, []),
          Q = erlang:spawn(sl2t, quick, []),
          erlang:link(Q),
          Q ! go,
          receive {'EXIT', P2, R2} -> erlang:display(P2), erlang:display(R2) end,
          erlang:link(W),
          receive {'EXIT', P3, R3} -> erlang:display(P3), erlang:display(R3) end,
          erlang:halt().
      idle() -> receive _ -> ok end.
      worker() -> receive go -> erlang:display(1 + x) end.
      quick() -> receive go -> ok end.
      """)

    assert status == :halted
    # the worker and quick both live on ENGINE 1 (round-robin placed)
    assert [{:pid, 1, _, _}, :badarith, {:pid, 1, _, _}, :normal, {:pid, 1, _, _}, :noproc] =
             m.out
  end

  test "monitors cross engines: normal DOWN, kill->killed, and noproc" do
    {status, m} =
      run2("""
      -module(mn2t).
      -export([main/0, idle/0, target/0]).
      main() ->
          _L = erlang:spawn(mn2t, idle, []),
          T = erlang:spawn(mn2t, target, []),
          Ref1 = erlang:monitor(process, T),
          erlang:display(Ref1),
          T ! go,
          receive {'DOWN', Ra, Pa, Rsa} ->
              erlang:display(Ra), erlang:display(Pa), erlang:display(Rsa)
          end,
          _F = erlang:spawn(mn2t, idle, []),
          V = erlang:spawn(mn2t, idle, []),
          Ref2 = erlang:monitor(process, V),
          erlang:exit(V, kill),
          receive {'DOWN', Rb, _Pb, Rsb} ->
              erlang:display(Rb == Ref2), erlang:display(Rsb)
          end,
          Ref3 = erlang:monitor(process, T),
          receive {'DOWN', Rc, _Pc, Rsc} ->
              erlang:display(Rc == Ref3), erlang:display(Rsc)
          end,
          erlang:halt().
      idle() -> receive _ -> ok end.
      target() -> receive go -> ok end.
      """)

    assert status == :halted

    assert [ref, ref, {:pid, 1, _, _}, :normal, true, :killed, true, :noproc] = m.out
    assert {:ref, _} = ref
  end
end
