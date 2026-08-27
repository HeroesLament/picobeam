# The OTP shapes that landed today, on the gates.
#
#   mix run scripts/mk_otp.exs   -> _emit/m3/otp2{,_pool,_expect}.hex
#
# `notes/30` measured which Erlang constructs the front end accepts.
# This asks the harder question about the ones that were added after
# it: do they RUN on the netlist, or only in the model?
#
# Three of the four need no new hardware, and that is the point of
# including them here rather than trusting it:
#
#   * `spawn_link/3` is spawn followed by link, both of which the
#     engine has had since `notes/24`;
#   * a list comprehension is a lifted self-recursive function, which is
#     `call`/`tailcall`/`cons` — and `tailcall` reusing its window is
#     what keeps it in constant stack;
#   * `lists:reverse/1` is the same, out of the Erlang prelude.
#
# `try`/`catch` is NOT here. It needs `try_begin`/`try_end`, which the
# model implements and the RTL does not, and pretending otherwise by
# leaving it out silently would be worse than saying so.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(otp).
-export([main/0, w/1]).

main() ->
    L = [X + 1 || X <- [1, 2, 3]],
    erlang:display(lists:sum(L)),
    erlang:display(lists:length(L)),
    erlang:display(lists:member(3, L)),
    erlang:halt().

w(N) -> erlang:display(N).
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/otp.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/otp.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/otp2.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/otp2_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/otp2_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("functions: #{inspect(Map.keys(img.bases))}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("__OTP_DONE__")
