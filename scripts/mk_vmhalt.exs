# `erlang:halt/0` stops the VM, not the process that called it.
#
#   mix run scripts/mk_vmhalt.exs   -> _emit/m3/vmhalt{,_pool,_expect}.hex
#
# `notes/26` bug 2 was the last place the model and the netlist
# disagreed about a feature that has shipped: the model froze the whole
# machine and the engine exited one process, and every program written
# for this machine so far hid it by halting last.
#
# This one does not hide it. The child SENDS before it starts looping,
# so by the time `main` halts the child has provably run and is
# provably still runnable — and then it spins in a tail-recursive loop
# that never ends on its own. The assertions are the three halves of
# the same statement:
#
#   WANT_IDLE   the machine stopped
#   WANT_OCC=1  with a live process still in it
#   WANT_DEATHS=1  and only the caller of `halt` gone
#
# An engine that exited one process would still be spinning in
# `forever/0` when the cycle cap hit.

alias PicoBEAM.{Erl, Encoding, Machine}

src = """
-module(vmhalt).
-export([main/0, w/1]).

main() ->
    Me = erlang:self(),
    erlang:spawn(vmhalt, w, [Me]),
    receive
        X -> erlang:display(X)
    end,
    erlang:halt().

w(P) ->
    P ! 1,
    forever().

forever() -> forever().
"""

File.mkdir_p!("/tmp/pb_erl")
File.write!("/tmp/pb_erl/vmhalt.erl", src)

prog = Erl.compile_file("/tmp/pb_erl/vmhalt.erl")
img = Encoding.image(prog, :"main/0")

m = prog |> Machine.new() |> Machine.boot(:"main/0", [])
{status, m} = Machine.run(m, 500_000)

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.write!("_emit/m3/vmhalt.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")
File.write!("_emit/m3/vmhalt_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")
File.write!("_emit/m3/vmhalt_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} status=#{status}")
IO.puts("model out = #{inspect(m.out)}")
IO.puts("model deaths = #{inspect(Machine.deaths(m))}")
IO.puts("__VMHALT_DONE__")
