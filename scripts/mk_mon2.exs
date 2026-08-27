# Cross-engine MONITORS and exit/2: the notes/53 Phase-4 gate, second
# half.
#
#   mix run scripts/mk_mon2.exs  -> _emit/m3/mon2{,_pool,_expect}.hex
#
# One image, two engines. The watcher on engine 0 monitors processes
# the round-robin placed on engine 1:
#
#   * `monitor` of a live remote pid is a kind-5 request landing in the
#     far SignalTable; the ref is minted HOME (displayed, then compared
#     against the ref the DOWN carries — the two words must be equal,
#     which is why no engine field is needed in a ref: every ref a
#     process ever matches was minted by its own engine)
#   * the target's NORMAL return comes back as {'DOWN', Ref, T, normal}
#     — ring kind 7 from the far death walk
#   * `exit(Victim, kill)` crosses as kind 6, is untrappable there, and
#     the DOWN reports `killed` — the kill/killed translation at the
#     RECEIVING engine, exactly the model's rule
#   * `monitor` of a DEAD remote pid answers {'DOWN', Ref, _, noproc}
#
# The expectations come from `Machine` with `engines: 2`.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(mon2).
-export([main/0, idle/0, target/0]).

main() ->
    _L = erlang:spawn(mon2, idle, []),
    T = erlang:spawn(mon2, target, []),
    Ref1 = erlang:monitor(process, T),
    erlang:display(Ref1),
    T ! go,
    receive {'DOWN', Ra, Pa, Rsa} ->
        erlang:display(Ra), erlang:display(Pa), erlang:display(Rsa)
    end,
    _F = erlang:spawn(mon2, idle, []),
    V = erlang:spawn(mon2, idle, []),
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

idle() ->
    receive _ -> ok end.

target() ->
    receive go -> ok end.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/mon2.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/mon2.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(engines: 2) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/mon2.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!(
  "_emit/m3/mon2_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n"
)

File.write!(
  "_emit/m3/mon2_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n"
)

IO.puts("mon2: #{length(img.image)} bundles, pool=#{length(img.pool)}")
IO.puts("model out: #{inspect(m.out)}")
IO.puts("model raw: #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("status=#{status} halted=#{m.halted} cycles=#{m.cycle}")
IO.puts("__MON2_DONE__")
