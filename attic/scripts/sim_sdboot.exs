# Simulate SdBoot against a software SD-card model.
#
#   mix run scripts/sim_sdboot.exs
#
# Phase 1: capture every bit SdBoot clocks out (MOSI sampled on SCK
# rising edges) and print the byte stream — the CMD0 framing, verbatim.
# Phase 2: a minimal card model answers R1=0x01 to CMD0, and we check
# the FSM advances to CMD8 (phase/state movement) instead of erroring.

{:ok, sim} = Hw.Sim.start(PicoBEAM.RTL.SdTb)
Hw.Sim.set(sim, :rst, 0)
Hw.Sim.set(sim, :miso, 1)

defmodule Card do
  # a tiny SPI SD card: assembles MOSI bits into bytes once CS is low,
  # recognizes CMD0 (0x40 .. 0x95), and after NCR=2 bytes answers 0x01.
  def new, do: %{bits: [], bytes: [], resp: [], sck: 0, seen_cmd0: false, ncr: 0}

  def step(card, sck, cs, mosi) do
    rising = card.sck == 0 and sck == 1
    falling = card.sck == 1 and sck == 0
    card = %{card | sck: sck}

    card =
      if rising and cs == 0 do
        bits = card.bits ++ [mosi]

        if length(bits) == 8 do
          byte = Integer.undigits(bits, 2)
          card = %{card | bits: [], bytes: card.bytes ++ [byte]}
          maybe_respond(card, byte)
        else
          %{card | bits: bits}
        end
      else
        card
      end

    # present the next response bit on falling edges (MSB first)
    {miso_out, card} =
      if falling and cs == 0 do
        case card.resp do
          [b | rest] -> {b, %{card | resp: rest}}
          [] -> {1, card}
        end
      else
        {nil, card}
      end

    {card, miso_out}
  end

  defp maybe_respond(card, byte) do
    # detect end of CMD0: last 6 bytes = 40 00 00 00 00 95
    tail = Enum.take(card.bytes, -6)

    if tail == [0x40, 0, 0, 0, 0, 0x95] and card.resp == [] and not card.seen_cmd0 do
      # NCR: one idle byte (8 ones), then R1 = 0x01
      resp = List.duplicate(1, 8) ++ for(b <- 7..0, do: Bitwise.band(Bitwise.bsr(0x01, b), 1))
      %{card | seen_cmd0: true, resp: resp}
    else
      card
    end
  end
end

card = Card.new()

{card, _} =
  Enum.reduce(1..30_000, {card, nil}, fn t, {card, _} ->
    sck = Hw.Sim.get(sim, :sck)
    cs = Hw.Sim.get(sim, :cs_n)
    mosi = Hw.Sim.get(sim, :mosi)

    {card, miso_out} = Card.step(card, sck, cs, mosi)
    if miso_out != nil, do: Hw.Sim.set(sim, :miso, miso_out)

    Hw.Sim.tick(sim, :clk, 1)

    st = Hw.Sim.get(sim, :state_dbg)
    err = Hw.Sim.get(sim, :err)

    if err != 0 or st == 9 do
      IO.puts("t=#{t} FSM ERROR err=#{err} state=#{st} last_rx=#{inspect(Hw.Sim.get(sim, :last_rx), base: :hex)}")
      IO.puts("bytes sent by host so far: #{inspect(Enum.map(card.bytes, &Integer.to_string(&1, 16)))}")
      System.halt(1)
    end

    if st == 4 do
      IO.puts("t=#{t} REACHED CMD8-R7 state — CMD0 accepted by the card model!")
      IO.puts("host bytes: #{inspect(Enum.map(card.bytes, &Integer.to_string(&1, 16)))}")
      System.halt(0)
    end

    {card, nil}
  end)

IO.puts("timeout: never reached CMD8. host bytes: #{inspect(Enum.map(card.bytes, &Integer.to_string(&1, 16)))}")
IO.puts("state=#{Hw.Sim.get(sim, :state_dbg)} cs=#{Hw.Sim.get(sim, :cs_n)} sck_seen=#{card.sck}")
IO.puts("__SIM_SD_DONE__")
