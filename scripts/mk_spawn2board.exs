# Cross-engine spawn, on silicon (`notes/49`).
#
#   mix run scripts/mk_spawn2board.exs   -> _emit/sd/spawn2.img
#   mix run scripts/pbpush.exs _emit/sd/spawn2.img
#
# The debug UART carries only the LOW BYTE of the most recent `out`
# (`notes/44`), so the program prints a PROGRESS MARKER at each step and
# the last one to land is what the status line shows. That turns one
# byte into a position report:
#
#   00  nothing — the machine never got past the first spawn
#   01  the LOCAL spawn returned a pid
#   02  the REMOTE spawn returned a pid — the ring round trip closed
#   03  the local echo replied
#   04  the remote echo replied — a process on engine 1 ran, received a
#       message across the ring while BLOCKED, and answered
#   2a  ...and both children's `self` matched the pid `spawn` handed
#       back, which is the invariant `tb_m3_pass7` checks locally
#
# `entry1 = 0x1FF` means "do not boot engine 1" (`notes/36`). Engine 1
# gets the code and no process; everything it runs arrives over the ring.

alias PicoBEAM.{Asm, Encoding, Machine}

prog = %{
  main:
    {0,
     [
       [{:self, 15}],
       [{:arg, 0, 15}],
       [{:spawn, 1, :echo, 1}],
       [{:ldi, 12, 1}],
       [{:out, 12}],
       [{:arg, 0, 15}],
       [{:spawn, 2, :echo, 1}],
       [{:ldi, 12, 2}],
       [{:out, 12}],
       [{:ldi, 5, 11}],
       [{:send, 1, 5}],
       :w1,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 6, :w1}],
       [{:recv_take, 6}],
       [{:ldi, 12, 3}],
       [{:out, 12}],
       [{:cmpeq, 10, 6, 1}],
       [{:ldi, 7, 22}],
       [{:send, 2, 7}],
       :w2,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 8, :w2}],
       [{:recv_take, 8}],
       [{:ldi, 12, 4}],
       [{:out, 12}],
       [{:cmpeq, 11, 8, 2}],
       [{:bift, 10, :a}],
       [{:jmp, :done}],
       :a,
       [{:bift, 11, :b}],
       [{:jmp, :done}],
       :b,
       [{:ldi, 12, 42}],
       [{:out, 12}],
       :done,
       [{:halt}]
     ]},
  # forever { receive X -> send Parent, self() }
  echo:
    {1,
     [
       :loop,
       [{:recv_start}],
       [{:recv_wait}],
       [{:recv_peek, 1, :loop}],
       [{:recv_take, 1}],
       [{:self, 2}],
       [{:send, 0, 2}],
       [{:jmp, :loop}]
     ]}
}

asm = Asm.assemble(prog)
img = Encoding.image(asm, :main)

{status, m} =
  asm |> Machine.new(engines: 2) |> Machine.boot(:main) |> Machine.run(200_000)

bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>
pool_bin = for w <- img.pool, into: <<>>, do: <<w::40>>

body =
  <<0x70, 0x42, 0x4D, 0x32, length(img.image)::16-little, length(img.pool)::16-little,
    img.entry::16-little, 0x1FF::16-little>> <> bundles_bin <> pool_bin

pad = rem(512 - rem(byte_size(body), 512), 512)
File.mkdir_p!("_emit/sd")
File.write!("_emit/sd/spawn2.img", body <> :binary.copy(<<0>>, pad))

IO.puts("bundles=#{length(img.image)} pool=#{length(img.pool)} entry=#{img.entry} status=#{status}")
IO.puts("out = #{inspect(m.out)}")
IO.puts("last out byte = 0x#{Integer.to_string(rem(List.last(m.out), 256), 16)}")
IO.puts("image: #{byte_size(body)} bytes on the wire")
IO.puts("__SPAWN2BOARD_DONE__")
