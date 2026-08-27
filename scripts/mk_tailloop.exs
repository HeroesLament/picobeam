# `tailcall`, which every OTP loop is made of.
#
#   mix run scripts/mk_tailloop.exs   -> _emit/m3/tailloop{,_expect}.hex
#
# `notes/27` lists `tailcall` among the ops that are wired into the
# engine and have never executed. It is the sharpest entry on that list
# because it is not exotic: a `gen_server` is a function that receives a
# message, does something, and calls ITSELF. In Erlang that runs in
# constant stack forever. If `tailcall` pushes a window instead of
# reusing one, the machine's register stack — 64 frames — overflows on
# the 65th iteration, and every long-lived OTP process dies of
# `stack_overflow` for no reason a programmer could see.
#
# So the loop below runs 200 times on purpose. Anything under 65 would
# pass whether the op works or not.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(loop).
-export([main/0]).

main() -> count(0).

count(N) ->
    case N < 200 of
        true  -> count(N + 1);
        false -> erlang:display(N), erlang:halt()
    end.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/loop.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/loop.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/tailloop.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/tailloop_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/tailloop_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status} out=#{inspect(m.out)} cycles=#{m.cycle}")
IO.puts("__TAILLOOP_DONE__")
