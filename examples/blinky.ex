# Blinky — the hello-world of FPGAs, as a BEAM process.
#
#   mix run scripts/mk_blinky.exs   -> _emit/sd/blinky.img
#   bash scripts/board_push.sh _emit/sd/blinky.img, then HOLD BTN2
#
# There is no GPIO poke anywhere in this file. `:erlang.display/1`
# retires an `out`, the top already mirrors the last out's low byte
# onto the eight LEDs while BTN2 is held, and `receive after N` is
# the timer wheel — N in machine cycles, so 6_000_000 at 12 MHz is
# half a second. The process SLEEPS between toggles: descheduled,
# seat surrendered, a 1 Hz blink costing two bundles a second.
defmodule Blinky do
  def main do
    loop(0)
  end

  def loop(led) do
    :erlang.display(led)

    receive do
    after
      6_000_000 -> :ok
    end

    loop(255 - led)
  end
end
