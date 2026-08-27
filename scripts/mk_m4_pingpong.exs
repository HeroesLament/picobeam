# M4 exit demo: ping-pong. The root spawns a pong server, hands it the
# root's own pid, and then bounces a counter back and forth N times
# before reporting. Every message is an IMMEDIATE (a fixnum or a pid),
# so this runs before the heap and the serialiser return.
#
#   mix run scripts/mk_m4_pingpong.exs

alias PicoBEAM.{Asm, Encoding}

rounds = 20

program = %{
  main:
    {0,
     [
       # r1 = my own pid; hand it to the pong process as its argument
       [{:self, 1}],
       [{:arg, 0, 1}],
       [{:spawn, 2, :pong, 1}],
       # r3 = the counter, r4 = 1, r5 = rounds
       [{:ldi, 3, 0}],
       [{:ldi, 4, 1}],
       [{:ldi, 5, rounds}],
       :ploop,
       [{:send, 2, 3}],
       # wait for the reply, take it, count the round
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 6, :ploop_wait}],
       [{:recv_take, 6}],
       [{:add, 3, 3, 4}],
       [{:cmpeq, 7, 3, 5}],
       [{:bift, 7, :pdone}],
       [{:jmp, :ploop}],
       :ploop_wait,
       # peek found nothing: go round the wait again
       [{:jmp, :ploop}],
       :pdone,
       [{:out, 3}],
       [{:halt}]
     ]},
  # pong(ParentPid): forever { receive X -> send Parent, X }
  pong:
    {1,
     [
       :wloop,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 1, :wloop}],
       [{:recv_take, 1}],
       [{:send, 0, 1}],
       [{:jmp, :wloop}]
     ]}
}

img = Encoding.image(Asm.assemble(program), :main)
File.mkdir_p!("_emit/m3")

File.write!("_emit/m3/pingpong.hex",
  Enum.join(Enum.map(img.image, fn w ->
    w |> Integer.to_string(16) |> String.pad_leading(18, "0")
  end), "\n") <> "\n")

IO.puts("bundles=#{length(img.image)} entry=#{img.entry} pong=#{img.bases.pong} rounds=#{rounds}")
