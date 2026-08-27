# Links, on the engine: a process that dies takes its linked peers
# with it, and a trapping peer gets told instead.
#
#   mix run scripts/mk_super.exs
#
# Two images, because the two halves of `link/1` are different claims:
#
#   super_kill  — the root links a child; the child raises badarith;
#                 the root dies of badarith too, without ever running
#                 another bundle. Three processes, three deaths.
#   super_trap  — same, except the root sets trap_exit first, so the
#                 signal is converted to a message at the delivery path
#                 and the root survives to see it.

alias PicoBEAM.{Asm, Encoding, Machine, Term}

spin = fn label ->
  [
    label,
    [{:ldi, 14, 1}],
    [{:cmpeq, 15, 14, 14}],
    [{:bift, 15, label}]
  ]
end

kill_prog = %{
  main:
    {0,
     [
       [{:ldi, 1, 0}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :child, 1}],
       [{:link, 2}],
       [{:ldi, 3, 100}],
       [{:out, 3}]
       # alive, and doing nothing, when the child goes
     ] ++ spin.(:spin)},
  child:
    {1,
     [
       [{:ldi, 1, 1}],
       [{:ldn, 2}],
       # an integer plus NIL: badarith, reserved reason 3
       [{:add, 3, 1, 2}],
       [{:halt}]
     ]}
}

trap_prog = %{
  main:
    {0,
     [
       [{:trapexit, 1}],
       [{:ldi, 1, 0}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :child, 1}],
       [{:link, 2}],
       [{:ldi, 3, 100}],
       [{:out, 3}],
       # wait for the signal to arrive as mail, then say so. Reading
       # the {'EXIT', From, Reason} tuple itself needs the deserialiser
       # in the engine; what is asserted here is that a TRAPPING
       # process survives its linked child and is woken by the message.
       [{:recv_start}],
       [{:recv_wait}],
       [{:ldi, 4, 55}],
       [{:out, 4}]
     ] ++ spin.(:tspin)},
  child:
    {1,
     [
       [{:ldi, 1, 1}],
       [{:ldn, 2}],
       [{:add, 3, 1, 2}],
       [{:halt}]
     ]}
}

# exit2: a signal aimed at ONE process rather than fanned out over a
# link set. The child is not linked to anybody; it dies because it was
# named. Reason 5 is `overflow`, chosen because nothing in this program
# could have produced it by accident — if the child dies of that, it
# died of the exit2 and not of its own arithmetic.
exit2_prog = %{
  main:
    {0,
     [
       [{:ldi, 1, 0}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :child, 1}],
       # let the child actually get seated and run before killing it
       [{:ldi, 5, 200}],
       [{:ldi, 6, 1}],
       [{:ldi, 7, 0}],
       :wait,
       [{:sub, 5, 5, 6}],
       [{:cmpeq, 8, 5, 7}],
       [{:biff, 8, :wait}],
       # the reason is an ATOM: `notes/13` fixes reserved-atom indices
       # by ABI precisely so a signal can name a reason without
       # allocating, and `exit2` is the user-facing door onto that path
       [{:lda, 9, :overflow}],
       [{:exit2, 2, 9}],
       [{:ldi, 4, 77}],
       [{:out, 4}],
       [{:halt}]
     ]},
  child:
    {1, [] ++ spin.(:cspin)}
}

# monitor: watching a process rather than being tied to it. The
# watcher does NOT die when the target does — it gets a message
# carrying the ref it was handed, which is how it tells one of its
# monitors from another.
mon_prog = %{
  main:
    {0,
     [
       [{:ldi, 1, 0}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :child, 1}],
       [{:monitor, 10, 2}],
       # the ref is a REF-tagged word (tag 6); out its low byte so the
       # testbench can see one was handed back at all
       [{:ldi, 3, 100}],
       [{:out, 3}],
       # block until the DOWN arrives
       [{:recv_start}],
       [{:recv_wait}],
       [{:ldi, 4, 66}],
       [{:out, 4}],
       [{:halt}]
     ]},
  child:
    {1,
     [
       [{:ldi, 1, 1}],
       [{:ldn, 2}],
       [{:add, 3, 1, 2}],
       [{:halt}]
     ]}
}

# recv_waitt: a receive with a deadline. Two runs of the same shape,
# and the difference between them is the whole point:
#
#   timeout_hit  — nothing is ever sent, the deadline expires, and the
#                  process resumes at the pc `recv_waitt` named
#   timeout_miss — a message arrives first, the deadline is cancelled,
#                  and the process resumes past the wait as usual
#
# `ldc` supplies the delay because it is far past ldi's 12-bit reach —
# which is the sort of thing that made `ldc` worth building.
wait_prog = fn send_first ->
  %{
    main:
      {0,
       [
         [{:self, 1}],
         [{:arg, 0, 1}],
         [{:spawn, 2, :child, 1}],
         [{:recv_start}],
         # `ldc` supplies the delay because 4000 is far past ldi's
         # 12-bit reach — the sort of thing that made `ldc` worth
         # building
         [{:ldc, 5, 4000}],
         [{:recv_waitt, 5, :late}],
         # a message arrived inside the deadline
         [{:ldi, 6, 1}],
         [{:out, 6}],
         [{:halt}],
         :late,
         # nothing did
         [{:ldi, 7, 2}],
         [{:out, 7}],
         [{:halt}]
       ]},
    # The child SPINS rather than halting. `halt` is `erlang:halt/0` —
    # stop the machine — and the model takes that literally, so a child
    # that halts ends the run before the root's deadline can expire.
    # (The engine treats halt as a process exit, which is a divergence
    # worth its own line in notes/24 rather than a workaround here.)
    child:
      {1,
       (if send_first do
          [[{:ldi, 1, 42}], [{:send, 0, 1}]]
        else
          []
        end) ++ spin.(:cwait)}
  }
end

File.mkdir_p!("_emit/m3")
hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

for {name, prog} <- [{"super_kill", kill_prog}, {"super_trap", trap_prog},
                     {"super_exit2", exit2_prog},
                     {"super_mon", mon_prog},
                     {"super_tmo_hit", wait_prog.(false)},
                     {"super_tmo_miss", wait_prog.(true)}] do
  asm = Asm.assemble(prog)
  img = Encoding.image(asm, :main)

  File.write!("_emit/m3/#{name}.hex",
    Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

  m = asm |> Machine.new() |> Machine.boot(:main, [])
  {status, m} = Machine.run(m, 100_000)

  File.write!("_emit/m3/#{name}_pool.hex",
    (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

  File.write!("_emit/m3/#{name}_expect.hex",
    Enum.map_join(m.out, "\n", &hx.(Term.int(&1), 9)) <> "\n")

  IO.puts("#{name}: status=#{status} bundles=#{length(img.image)} " <>
            "outs=#{inspect(m.out)} deaths=#{inspect(Machine.deaths(m))}")
end

IO.puts("__SUPER_DONE__")
