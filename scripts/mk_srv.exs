# A gen_server-shaped process, in application atoms.
#
#   mix run scripts/mk_srv.exs   -> _emit/m3/srv{,_pool,_expect}.hex
#
# This is the shape all of OTP is made of: a function that receives a
# request, replies, and calls ITSELF with new state. Three things had to
# be true before it could exist, and until today one of them was not.
#
#   * `tailcall` must reuse the window, or the 65th request overflows
#     the register stack (proven separately by `mk_tailloop.exs`);
#   * `send` of a compound term must COPY it, or `{From, inc}` ships a
#     heap pointer (notes/22's postscript);
#   * and a program must be able to name its OWN atoms.
#
# That last one was the wall. `Encoding` could only number the eighteen
# reserved atoms, so `inc`, `stop` and `reply` were unencodable and no
# OTP protocol could be written at all. The atom table fixes it, and it
# costs the hardware nothing: `lda` has always carried a 12-bit index
# and the ALU has always turned it into an atom term. 4,096 atoms were
# available the whole time; only the toolchain refused to number them.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(srv).
-export([main/0, srv/1]).

main() ->
    P = spawn(srv, srv, [0]),
    P ! {self(), inc},
    receive
        {reply, A} -> erlang:display(A)
    end,
    P ! {self(), inc},
    receive
        {reply, B} -> erlang:display(B)
    end,
    P ! stop,
    erlang:display(done),
    erlang:halt().

srv(N) ->
    receive
        {From, inc} ->
            From ! {reply, N + 1},
            srv(N + 1);
        stop ->
            ok
    end.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/srv.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/srv.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/srv.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/srv_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/srv_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("atom table: #{inspect(img.atoms)}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("words     = #{inspect(Enum.map(m.out_raw, &hx.(&1, 9)))}")
IO.puts("__SRV_DONE__")
