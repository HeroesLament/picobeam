# Recursion past the frame store's depth — `:stack_overflow` on gates.
#
#   mix run scripts/mk_deep.exs   -> _emit/m3/deep{,_pool,_expect}.hex
#
# `FrameRamProc` addresses frames as {slot:5, depth:4, idx:4} and has
# raised `overflow` since M3 pass 5. The engine declared `fr_ovf` and
# never read it, so the 16th nested call pushed no frame, recorded no
# link, and returned into the 15th caller's — a wrong answer, silently.
# `notes/31` wires it to the fault chain and brings the model's own
# limit down to the same 15, so this program faults in both.
#
# `f/1` is deliberately NOT tail recursive: the addition after the call
# is what forces a frame per level. `tailloop` already proves the tail
# case stays flat, and the two together are the whole contract.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(deep).
-export([main/0]).

main() ->
    erlang:display(f(30)),
    erlang:halt().

f(0) -> 0;
f(N) -> 1 + f(N - 1).
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/deep.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/deep.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/deep.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/deep_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/deep_expect.hex",
  (if m.out_raw == [], do: "fffffffff", else: Enum.map_join(m.out_raw, "\n", &hx.(&1, 9))) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("model deaths = #{inspect(Machine.deaths(m))}")
IO.puts("__DEEP_DONE__")
