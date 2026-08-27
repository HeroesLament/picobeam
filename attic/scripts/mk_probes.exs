# Build a ladder of tiny probe images for hardware bring-up bisection.
#
#   mix run scripts/mk_probes.exs
#
# Each lands in _emit/sd/ as its own .img. Iterate WITHOUT resynthesis:
# dd one onto the card at seek=8192, reinsert in the ULX3S, FIRE1, read.
#
#   probe_a  ldi + out                 -> expect 42  (LEDs 1,3,5)
#   probe_b  add                       -> expect 33  (LEDs 0,5)
#   probe_c  one call/ret + dest write -> expect  7  (LEDs 0,1,2)
#   probe_d  branch (cmplt/bift)       -> expect  9  (LEDs 0,3)
#   probe_e  fib(3), two-deep recursion-> expect  2  (LED 1)
#   fib      fib(10), the real demo    -> expect 55  (LEDs 0,1,2,4,5)

progs = %{
  "probe_a" =>
    {%{main: {0, [[{:ldi, 0, 42}], [{:out, 0}], [{:halt}]]}}, :main},
  "probe_b" =>
    {%{main:
       {0,
        [
          [{:ldi, 0, 20}],
          [{:ldi, 1, 13}],
          [{:add, 2, 0, 1}],
          [{:out, 2}],
          [{:halt}]
        ]}}, :main},
  "probe_c" =>
    {%{
       main:
         {0,
          [
            [{:ldi, 0, 7}],
            [{:arg, 0, 0}],
            [{:call, 1, :id, 1}],
            [{:out, 1}],
            [{:halt}]
          ]},
       id: {1, [[{:ret, 0}]]}
     }, :main},
  "probe_d" =>
    {%{main:
       {0,
        [
          [{:ldi, 0, 1}],
          [{:ldi, 1, 2}],
          [{:cmplt, 2, 0, 1}],
          [{:bift, 2, :yes}],
          [{:ldi, 3, 4}],
          [{:out, 3}],
          [{:halt}],
          :yes,
          [{:ldi, 3, 9}],
          [{:out, 3}],
          [{:halt}]
        ]}}, :main},
  "probe_e" =>
    {%{
       main:
         {0,
          [
            [{:ldi, 0, 3}],
            [{:arg, 0, 0}],
            [{:call, 1, :fib, 1}],
            [{:out, 1}],
            [{:halt}]
          ]},
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
     }, :main}
}

File.mkdir_p!("_emit/sd")

for {name, {prog, entry}} <- progs do
  img = PicoBEAM.Encoding.image(PicoBEAM.Asm.assemble(prog), entry)
  bundles_bin = for w <- img.image, into: <<>>, do: <<w::72>>

  body =
    <<0x70, 0x42, 0x4D, 0x31, length(img.image)::16-little, 0::16-little>> <> bundles_bin

  pad = rem(512 - rem(byte_size(body), 512), 512)
  File.write!("_emit/sd/#{name}.img", body <> :binary.copy(<<0>>, pad))
  IO.puts("#{name}: #{length(img.image)} bundles")
end

IO.puts("write one:  sudo dd if=_emit/sd/probe_a.img of=/dev/rdiskN bs=512 seek=8192")
IO.puts("__MK_PROBES_DONE__")
