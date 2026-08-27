# M4 eviction demo: five processes block on `receive` while only four
# seats exist, so blocked residents MUST be evicted for the root to keep
# running — and the one that is later sent a message must be woken from
# the evicted-blocked state, re-queued, re-seated, and resumed.
alias PicoBEAM.{Asm, Encoding}

program = %{
  main:
    {0,
     [
       [{:ldi, 3, 1}],
       [{:ldi, 5, 0}],
       [{:ldi, 1, 5}],
       # the FIRST waiter's pid is kept in r9: it is the one most likely
       # to have been seated, blocked, and then evicted
       [{:arg, 0, 1}],
       [{:spawn, 9, :waiter, 1}],
       [{:sub, 1, 1, 3}],
       :loop,
       [{:arg, 0, 1}],
       [{:spawn, 2, :waiter, 1}],
       [{:sub, 1, 1, 3}],
       [{:cmpeq, 4, 1, 5}],
       [{:bift, 4, :done}],
       [{:jmp, :loop}],
       :done,
       # let every waiter reach its receive and be evicted
       [{:ldi, 6, 500}],
       :delay,
       [{:sub, 6, 6, 3}],
       [{:cmpeq, 7, 6, 5}],
       [{:biff, 7, :delay}],
       # wake exactly one of them
       [{:ldi, 8, 99}],
       [{:send, 9, 8}],
       # `ret`, not `halt`. Since `notes/33` a `halt` here would stop
       # the VM before the waiter this just woke had a chance to run —
       # and the woken waiter reporting 99 is the entire assertion. A
       # top-level `ret` exits the root with `normal` (`notes/31`) and
       # leaves the machine running.
       [{:ret, 8}]
     ]},
  waiter:
    {1,
     [
       :wl,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 1, :wl}],
       [{:recv_take, 1}],
       [{:out, 1}],
       [{:ret, 1}]
     ]}
}

img = Encoding.image(Asm.assemble(program), :main)
File.mkdir_p!("_emit/m3")
File.write!("_emit/m3/evict.hex",
  Enum.join(Enum.map(img.image, fn w ->
    w |> Integer.to_string(16) |> String.pad_leading(18, "0")
  end), "\n") <> "\n")
IO.puts("bundles=#{length(img.image)} entry=#{img.entry} waiter=#{img.bases.waiter}")
