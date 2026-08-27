# `spawn_link/3`, and what happens when a spawned function RETURNS.
#
#   mix run scripts/mk_slink.exs   -> _emit/m3/slink{,_pool,_expect}.hex
#
# `notes/30` shipped `spawn_link/3` as "spawn then link" and the model
# agreed, but the gates did not: `spawn` + `display` + `halt` produced
# 459 outputs alternating 2, 1 where the model produced one. The link
# was innocent. What the trace showed (`notes/31`) is that a process
# whose ENTRY function returns did not exit — `ret` popped an empty
# frame stack, read link zero, and continued at bundle 0, which is
# `main`, so the child re-ran the whole program and spawned another.
#
# This is the shape that pins it down without racing `halt`: the child
# does its work, sends a result back, and RETURNS. The parent blocks in
# `receive`, so the child must have exited on its own for the parent to
# be the last one standing. Two deaths, no faults, one output.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(slink).
-export([main/0, w/1]).

main() ->
    Me = erlang:self(),
    erlang:spawn_link(slink, w, [Me]),
    receive
        X -> erlang:display(X)
    end,
    erlang:halt().

w(P) -> P ! 7.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/slink.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/slink.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/slink.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/slink_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/slink_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
for {f, b} <- img.bases, do: IO.puts("  #{f} @ #{b}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("__SLINK_DONE__")
