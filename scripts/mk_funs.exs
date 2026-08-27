# Closures, through the whole engine (`notes/42`).
#
#   mix run scripts/mk_funs.exs   -> _emit/m3/funs{,_pool,_expect}.hex
#
# `mkfun` allocates a closure, `tset` fills its captured variable,
# `callfun` reads the entry out of the object and commits a call to it,
# and the callee unpacks what it captured with `fget`. The same closure
# is called twice with different arguments, so the object is reused
# rather than consumed.
#
# The heap is 128 cells and this program allocates a fresh 2-tuple every
# turn of a loop it runs between the two calls, so the closure survives
# a collection in the middle — which is the part that proves the
# collector knows `fun` is a pointer, and not merely that `callfun`
# works on a heap nobody has disturbed.

alias PicoBEAM.{Asm, Encoding, Machine}

program =
  Asm.assemble(%{
    main:
      {0,
       [
         # capture 100 in a closure over `adder`
         [{:ldi, 1, 100}],
         [{:mkfun, 2, :adder, 1}],
         [{:tset, 2, 1, 1}],
         # call it: 5 + 100
         [{:ldi, 3, 5}],
         [{:arg, 0, 3}, {:arg, 1, 2}],
         [{:callfun, 4, 2, 1}],
         [{:out, 4}],
         # churn the heap hard enough to collect, keeping only the closure
         [{:ldi, 5, 200}],
         [{:ldi, 6, 1}],
         [{:ldi, 7, 0}],
         :loop,
         [{:mktup, 8, 2}],
         [{:tset, 8, 0, 5}],
         [{:tset, 8, 1, 5}],
         [{:sub, 5, 5, 6}],
         [{:cmpeq, 9, 5, 7}],
         [{:biff, 9, :loop}],
         # ...and call it again, after everything has moved
         [{:ldi, 10, 1}],
         [{:arg, 0, 10}, {:arg, 1, 2}],
         [{:callfun, 11, 2, 1}],
         [{:out, 11}],
         # a fun is a fun and not a tuple
         [{:istag, 12, 2, :fun}],
         [{:out, 12}],
         [{:istag, 13, 2, :tuple}],
         [{:out, 13}],
         [{:halt}]
       ]},
    # arity 2: the visible argument, then the closure itself
    adder: {2, [[{:fget, 2, 1, 1}], [{:add, 3, 0, 2}], [{:ret, 3}]]}
  })

img = Encoding.image(program, :main)

m =
  program
  |> Machine.new(heap_words: 256)
  |> Machine.boot(:main, [])

{status, m} = Machine.run(m, 200_000)

hx = fn w, n -> w |> Integer.to_string(16) |> String.pad_leading(n, "0") end

File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/funs.hex", Enum.map_join(img.image, "\n", &hx.(&1, 18)) <> "\n")

File.write!("_emit/m3/funs_pool.hex",
  (if img.pool == [], do: "000000000", else: Enum.map_join(img.pool, "\n", &hx.(&1, 9))) <> "\n")

File.write!("_emit/m3/funs_expect.hex",
  Enum.map_join(m.out_raw, "\n", &hx.(&1, 9)) <> "\n")

IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} status=#{status}")
IO.puts("collections=#{length(Map.get(m.stats, :gc, []))}")
IO.puts("out = #{inspect(m.out)}")

# ---- and the two ways a call through a closure goes wrong.
#
# BEAM raises `{badfun, F}` for a call to something that is not a fun
# and `{badarity, {F, Args}}` when the counts disagree, and until
# `notes/42` this machine said `badarg` to both — which is the
# difference between a supervisor that can match on what happened and
# one that cannot.
#
# `badfun` is raised by the STORE, at X, on the ordinary fault path, so
# it costs nothing. `badarity` cannot be known until the funinfo comes
# back a cycle later, by which time the seat has moved on: it is the
# first death in this machine raised for a seat that is not at X.

emit = fn name, prog, entry ->
  i = Encoding.image(prog, entry)
  mm = prog |> Machine.new(heap_words: 256) |> Machine.boot(entry, [])
  {st, mm} = Machine.run(mm, 100_000)

  File.write!("_emit/m3/#{name}.hex", Enum.map_join(i.image, "\n", &hx.(&1, 18)) <> "\n")

  File.write!("_emit/m3/#{name}_pool.hex",
    (if i.pool == [], do: "000000000", else: Enum.map_join(i.pool, "\n", &hx.(&1, 9))) <> "\n")

  File.write!("_emit/m3/#{name}_expect.hex",
    (if mm.out_raw == [], do: "FFFFFFFFF", else: Enum.map_join(mm.out_raw, "\n", &hx.(&1, 9))) <> "\n")

  IO.puts("#{name}: status=#{st} deaths=#{inspect(mm.stats.deaths)}")
end

emit.("funbad",
  Asm.assemble(%{
    main:
      {0,
       [
         [{:ldi, 1, 3}],
         [{:arg, 0, 1}],
         [{:callfun, 2, 1, 0}],
         [{:out, 2}],
         [{:halt}]
       ]}
  }),
  :main)

emit.("funar",
  Asm.assemble(%{
    main:
      {0,
       [
         [{:ldi, 1, 7}],
         [{:mkfun, 2, :adder, 1}],
         [{:tset, 2, 1, 1}],
         # `adder` is a fun of arity 1; call it with two arguments
         [{:arg, 0, 1}, {:arg, 1, 1}],
         [{:arg, 2, 2}],
         [{:callfun, 3, 2, 2}],
         [{:out, 3}],
         [{:halt}]
       ]},
    adder: {2, [[{:fget, 2, 1, 1}], [{:add, 3, 0, 2}], [{:ret, 3}]]}
  }),
  :main)

IO.puts("__FUNS_DONE__")
