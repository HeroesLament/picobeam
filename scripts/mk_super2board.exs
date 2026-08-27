# The V1 demo (notes/53 §Phase 5, notes/54): a supervisor on engine 0
# keeps a REGISTERED server alive across a cross-engine kill.
#
#   mix run scripts/mk_super2board.exs
#     -> _emit/m3/super2{,_pool,_expect}.hex   (tb_super2 gate)
#     -> _emit/sd/super2.img                   (board push)
#
# What the six displays show, in order:
#   the server's pid — ENGINE FIELD 1 (round-robin placed it away)
#   3, then 7        — served BY NAME across the ring, state carried
#   killed           — exit(Pid, kill) crossed, untrappable there,
#                      and the LINK brought the news back
#   the restart pid  — engine field 0 this time (round-robin moved on;
#                      supervision does not care where a process runs)
#   5                — fresh state: the name follows the ROLE
#
# Board verdict: OO=05 (last out low byte), XX=01 (killed).

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(super2).
-export([main/0, idle/0, server/0]).

main() ->
    _Pad = erlang:spawn(super2, idle, []),
    process_flag(trap_exit, true),
    start(),
    erlang:display(erlang:whereis(ctr)),
    ctr ! {add, 3, erlang:self()},
    receive {sum, A} -> erlang:display(A) end,
    ctr ! {add, 4, erlang:self()},
    receive {sum, B} -> erlang:display(B) end,
    P1 = erlang:whereis(ctr),
    erlang:exit(P1, kill),
    receive {'EXIT', _P, R} -> erlang:display(R) end,
    start(),
    erlang:display(erlang:whereis(ctr)),
    ctr ! {add, 5, erlang:self()},
    receive {sum, C} -> erlang:display(C) end,
    erlang:halt().

start() ->
    S = erlang:spawn(super2, server, []),
    erlang:link(S),
    true = erlang:register(ctr, S),
    ok.

idle() ->
    receive _ -> ok end.

server() ->
    loop(0).

loop(N) ->
    receive
        {add, K, From} ->
            M = N + K,
            From ! {sum, M},
            loop(M)
    end.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/super2.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/super2.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new(engines: 2) |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 2_000_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/super2.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!(
  "_emit/m3/super2_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n"
)

File.write!(
  "_emit/m3/super2_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n"
)

bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>
pool_bin = for w <- img.pool, into: <<>>, do: <<w::40>>

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <> bundles_bin <> pool_bin

pad = rem(512 - rem(byte_size(body), 512), 512)
File.mkdir_p!("_emit/sd")
File.write!("_emit/sd/super2.img", body <> :binary.copy(<<0>>, pad))

IO.puts("super2: #{length(img.image)} bundles, pool=#{length(img.pool)}")
IO.puts("model out: #{inspect(m.out)}")
IO.puts("model raw: #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("status=#{status} halted=#{m.halted} cycles=#{m.cycle}")
IO.puts("image: #{byte_size(body)} bytes on the wire")
IO.puts("__SUPER2_DONE__")
