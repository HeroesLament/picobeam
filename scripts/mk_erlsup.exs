# A real Erlang module, compiled through the front end, all the way to
# bundles, run on the engine.
#
#   mix run scripts/mk_erlsup.exs   -> _emit/m3/erlsup{,_pool,_expect}.hex
#
# Everything before this was hand-written in the bundle ISA. This is
# the first program on picoBEAM that a person would have written as
# Erlang: `process_flag(trap_exit, true)`, `spawn`, `link`,
# `receive ... after`, `exit/2`, and a tuple pattern in the receive
# clause that only matches because the deserialiser rebuilt the
# {'EXIT', From, Reason} the dying worker's signal left behind.
#
# The clause destructures rather than printing the message whole on
# purpose: `out` of a compound term emits a heap POINTER, which says
# nothing about what is at the other end. Printing `Reason` and
# `is_pid(From)` compares word-for-word against the model and is a
# statement about the contents.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(sup).
-export([main/0, worker/1]).

main() ->
    process_flag(trap_exit, true),
    P = spawn(sup, worker, [7]),
    link(P),
    erlang:display(1),
    receive
        {'EXIT', From, Reason} ->
            erlang:display(Reason),
            erlang:display(is_pid(From))
    after 5000 ->
        erlang:display(2)
    end,
    erlang:display(99),
    erlang:halt().

worker(N) ->
    erlang:display(N),
    exit(self(), badarith).
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/sup.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/sup.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/erlsup.hex",
  Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/erlsup_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

# the gate's expectation is the model's own output, encoded the way the
# engine's `out` port emits it
alias PicoBEAM.Term

File.write!("_emit/m3/erlsup_expect.hex",
  Enum.map_join(m.out, "\n", fn
    v when is_integer(v) -> hx.(Term.int(v), 9)
    true -> hx.(Term.atom(Enum.find_index(Term.reserved_atoms(), &(&1 == true))), 9)
    false -> hx.(Term.atom(Enum.find_index(Term.reserved_atoms(), &(&1 == false))), 9)
    v when is_atom(v) -> hx.(Term.atom(Enum.find_index(Term.reserved_atoms(), &(&1 == v))), 9)
  end) <> "\n")

IO.puts("bundles=#{length(img.image)} entry=#{img.entry} pool=#{inspect(img.pool)}")
IO.puts("model: status=#{status} out=#{inspect(m.out)}")
IO.puts("__ERLSUP_DONE__")
