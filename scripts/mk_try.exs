# `try`/`catch` on the gates (notes/32).
#
#   mix run scripts/mk_try.exs   -> _emit/m3/try{,_pool,_expect}.hex
#
# `notes/30` shipped `try`/`catch` in the model and said plainly that
# the RTL had nothing. This is the program that says whether it does
# now, and it is written to exercise both landings:
#
#   * `deep/1` protects a CALL, so the fault happens one frame below
#     the `try` and the frames have to be unwound before the handler
#     can run — the shape `erlc` actually emits;
#   * `shallow/0` raises in the try-owner's OWN frame, where there is
#     nothing to unwind and the handler is one register write away;
#   * `deep(0)` takes the happy path, so `try_end` has to leave the
#     protected expression's result alone;
#   * `nest/0` opens a second `try` inside the first one's protected
#     expression, lets the INNER one catch, and then faults again so the
#     OUTER one has to still be there. That is the whole reason the
#     catch state is a per-process stack and not a single register, and
#     a machine that got the nesting wrong would still pass every other
#     case here.
#
# The reasons are checked, not just the fact of catching: `overflow` is
# reserved atom 5 and `badarg` is 10, and a handler that caught the
# wrong one would still "work".

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(trycatch).
-export([main/0]).

main() ->
    erlang:display(deep(1)),
    erlang:display(deep(0)),
    erlang:display(shallow()),
    erlang:display(nest()),
    erlang:halt().

deep(A) ->
    try f(A) of
        X -> X
    catch
        _:E -> E
    end.

shallow() ->
    try erlang:error(badarg) of
        X -> X
    catch
        _:E -> E
    end.

nest() ->
    try g(shallow()) of
        Y -> Y
    catch
        _:E -> E
    end.

g(A) -> A + 1.

f(A) -> 2147483647 + A.
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/trycatch.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/trycatch.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/try.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/try_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/try_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
for {f, b} <- img.bases, do: IO.puts("  #{f} @ #{b}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("model raw = #{inspect(Enum.map(m.out_raw, &Integer.to_string(&1, 16)))}")
IO.puts("__TRY_DONE__")
