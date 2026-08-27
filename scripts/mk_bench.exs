# picoBEAM benchmark suite, v1 (notes/18).
#
# Each program brackets the work between two `out` markers — 0xA0 to
# start, 0xA1 to finish — so a cycle-exact simulator can time the span
# without any instrumentation inside the machine. Every number below is
# therefore CYCLES PER OPERATION, which is the clock-independent figure
# that actually describes the architecture; rates at a given MHz fall
# out of it.
#
#   mix run scripts/mk_bench.exs

alias PicoBEAM.{Asm, Encoding}

File.mkdir_p!("_emit/bench")

mark_start = [[{:ldi, 15, 0xA0}], [{:out, 15}]]
mark_end = [[{:ldi, 15, 0xA1}], [{:out, 15}], [{:halt}]]

# A 4-bundle body repeated N times. Solo, this measures the barrel's
# single-process cost (T cycles per bundle); with four copies running it
# measures aggregate issue.
loop_body = fn n, label_a, label_b ->
  [
    [{:ldi, 1, n}],
    [{:ldi, 2, 1}],
    [{:ldi, 3, 0}],
    label_a,
    [{:sub, 1, 1, 2}],
    [{:cmpeq, 4, 1, 3}],
    [{:biff, 4, label_b}]
  ]
end

n_loop = 1000

benches = %{
  # B1 — one process spinning a 3-bundle loop
  "b1_solo_loop" => %{
    main: {0, mark_start ++ loop_body.(n_loop, :lp, :lp) ++ mark_end},
    ops: n_loop * 3,
    what: "bundles retired, one process"
  },

  # B2 — four processes spinning the same loop concurrently
  "b2_quad_loop" => %{
    main:
      {0,
       mark_start ++
         [
           [{:ldi, 5, 3}],
           [{:ldi, 6, 1}],
           [{:ldi, 7, 0}],
           :sp,
           [{:spawn, 8, :worker, 0}],
           [{:sub, 5, 5, 6}],
           [{:cmpeq, 9, 5, 7}],
           [{:biff, 9, :sp}]
         ] ++ loop_body.(n_loop, :lp, :lp) ++ mark_end},
    # the worker RETURNS when it is done rather than halting: `halt` is
    # `erlang:halt/0` since `notes/33`, so the first worker to finish
    # would stop the other three and the root mid-measurement
    extra: %{worker: {0, loop_body.(n_loop, :wlp, :wlp) ++ [[{:ret, 0}]]}},
    ops: n_loop * 3 * 4,
    what: "bundles retired, four processes"
  },

  # B3 — message round trips
  "b3_pingpong" => %{
    main:
      {0,
       mark_start ++
         [
           [{:self, 1}],
           [{:arg, 0, 1}],
           [{:spawn, 2, :pong, 1}],
           [{:ldi, 3, 200}],
           [{:ldi, 4, 1}],
           [{:ldi, 5, 0}],
           :rt,
           [{:send, 2, 3}],
           :rx,
           [{:recv_start}],
           [{:recv_wait}],
           [{:recv_peek, 7, :rx}],
           [{:recv_take, 7}],
           [{:sub, 3, 3, 4}],
           [{:cmpeq, 8, 3, 5}],
           [{:biff, 8, :rt}]
         ] ++ mark_end},
    extra: %{
      pong:
        {1,
         [
           :pl,
           [{:recv_start}],
           [{:recv_wait}],
           [{:recv_peek, 1, :pl}],
           [{:recv_take, 1}],
           [{:send, 0, 1}],
           [{:jmp, :pl}]
         ]}
    },
    ops: 200,
    what: "message round trips (2 messages each)"
  },

  # B4 — spawn and reap
  "b4_spawn" => %{
    main:
      {0,
       mark_start ++
         [
           [{:ldi, 1, 100}],
           [{:ldi, 2, 1}],
           [{:ldi, 3, 0}],
           :sl,
           [{:spawn, 4, :nothing, 0}],
           [{:sub, 1, 1, 2}],
           [{:cmpeq, 5, 1, 3}],
           [{:biff, 5, :sl}]
         ] ++ mark_end},
    # ditto, and here it is the whole benchmark: a hundred processes
    # that spawn and immediately stop. One `halt` among them would end
    # the run at the first one.
    extra: %{nothing: {0, [[{:ret, 0}]]}},
    ops: 100,
    what: "processes spawned"
  },

  # B5 — call and return
  "b5_callret" => %{
    main:
      {0,
       mark_start ++
         [
           [{:ldi, 1, 100}],
           [{:ldi, 2, 1}],
           [{:ldi, 3, 0}],
           :cl,
           [{:arg, 0, 1}],
           [{:call, 6, :leaf, 1}],
           [{:sub, 1, 1, 2}],
           [{:cmpeq, 5, 1, 3}],
           [{:biff, 5, :cl}]
         ] ++ mark_end},
    extra: %{leaf: {1, [[{:ret, 0}]]}},
    ops: 100,
    what: "call/return pairs"
  },

  # B6 — fib(15), the classic
  "b6_fib15" => %{
    main:
      {0,
       mark_start ++
         [
           [{:ldi, 1, 15}],
           [{:arg, 0, 1}],
           [{:call, 2, :fib, 1}]
         ] ++ mark_end},
    extra: %{
      fib:
        {1,
         [
           [{:ldi, 1, 2}, {:ldi, 3, 1}],
           [{:cmplt, 2, 0, 1}],
           [{:bift, 2, :base}],
           [{:sub, 4, 0, 3}],
           [{:arg, 0, 4}],
           [{:call, 5, :fib, 1}],
           [{:sub, 7, 0, 1}],
           [{:arg, 0, 7}],
           [{:call, 8, :fib, 1}],
           [{:add, 9, 5, 8}],
           [{:ret, 9}],
           :base,
           [{:ret, 0}]
         ]}
    },
    ops: 1,
    what: "fib(15) = 610, whole computation"
  }
}

manifest =
  for {name, spec} <- Enum.sort(benches) do
    program = Map.merge(%{main: spec.main}, Map.get(spec, :extra, %{}))
    img = Encoding.image(Asm.assemble(program), :main)

    File.write!("_emit/bench/#{name}.hex",
      Enum.join(Enum.map(img.image, fn w ->
        w |> Integer.to_string(16) |> String.pad_leading(18, "0")
      end), "\n") <> "\n")

    IO.puts("#{name}: bundles=#{length(img.image)} ops=#{spec.ops}  (#{spec.what})")
    "#{name} #{length(img.image)} #{spec.ops}"
  end

File.write!("_emit/bench/manifest.txt", Enum.join(manifest, "\n") <> "\n")
IO.puts("__BENCH_IMAGES_DONE__")
