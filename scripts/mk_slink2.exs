# Cross-engine LINKS: the notes/53 Phase-4 gate, first half.
#
#   mix run scripts/mk_slink2.exs  -> _emit/m3/slink2{,_pool,_expect}.hex
#
# One image, two engines. The trapping parent on engine 0 links to
# workers the round-robin placed on engine 1, and every flavor of exit
# crosses the ring:
#
#   * an ABNORMAL death (badarith) arrives as {'EXIT', W, badarith} —
#     ring kind 6 out of the far engine's death walk
#   * a NORMAL return arrives as {'EXIT', Q, normal} — the reason that
#     kills nobody still reaches a trapping partner (the source-side
#     filter that used to hide it is gone)
#   * a link to a pid that is already DEAD answers {'EXIT', W, noproc}
#     — the dead-letter rule turning a kind-3 request into a kind-6
#     reply
#
# The expectations come from `Machine` with `engines: 2`.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(slink2).
-export([main/0, idle/0, worker/0, quick/0]).

main() ->
    process_flag(trap_exit, true),
    _L = erlang:spawn(slink2, idle, []),
    W = erlang:spawn(slink2, worker, []),
    erlang:link(W),
    W ! go,
    receive {'EXIT', P1, R1} -> erlang:display(P1), erlang:display(R1) end,
    _F = erlang:spawn(slink2, idle, []),
    Q = erlang:spawn(slink2, quick, []),
    erlang:link(Q),
    Q ! go,
    receive {'EXIT', P2, R2} -> erlang:display(P2), erlang:display(R2) end,
    erlang:link(W),
    receive {'EXIT', P3, R3} -> erlang:display(P3), erlang:display(R3) end,
    erlang:halt().

idle() ->
    receive _ -> ok end.

worker() ->
    receive go -> erlang:display(1 + x) end.

quick() ->
    receive go -> ok end.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/slink2.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/slink2.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(engines: 2) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/slink2.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!(
  "_emit/m3/slink2_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n"
)

File.write!(
  "_emit/m3/slink2_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n"
)

IO.puts("slink2: #{length(img.image)} bundles, pool=#{length(img.pool)}")
IO.puts("model out: #{inspect(m.out)}")
IO.puts("model raw: #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("status=#{status} halted=#{m.halted} cycles=#{m.cycle}")
IO.puts("__SLINK2_DONE__")
