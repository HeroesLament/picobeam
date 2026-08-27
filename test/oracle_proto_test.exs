defmodule PicoBEAM.OracleProtoTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias PicoBEAM.Oracle.Proto

  # `notes/39` is the specification and this file is the part of it that
  # runs. Every property here is a sentence in that note.

  test "CRC-16/CCITT-FALSE agrees with the standard check vector" do
    assert Proto.crc16("123456789") == 0x29B1
  end

  test "a frame round-trips, including bytes that need stuffing" do
    payload = <<Proto.sync(), Proto.esc(), 0x00, 0xFF, Proto.sync()>>
    wire = Proto.frame(:wdata, payload)

    assert {[{:wdata, ^payload}], <<>>, ""} = Proto.unframe(wire)
  end

  test "SYNC occurs only at a frame boundary" do
    # the property the stuffing exists for: whatever the payload is, the
    # sync byte appears exactly once, at the front
    payload = for i <- 0..255, into: <<>>, do: <<i>>
    wire = Proto.frame(:data, payload)

    assert :binary.matches(wire, <<Proto.sync()>>) |> length() == 1
    assert <<sync, _::binary>> = wire
    assert sync == Proto.sync()
  end

  test "the board's ASCII line survives between frames" do
    line = "p000 6 9 00 001 004 0 0 07 86 00 00\r\n"
    wire = line <> Proto.frame(:out, <<0, 0x100000037::40>>) <> line

    {frames, <<>>, text} = Proto.unframe(wire)

    assert [{:out, _}] = frames
    assert text == line <> line
  end

  test "a corrupted frame never happened" do
    wire = Proto.frame(:ping, <<1, 2, 3, 4>>)
    # flip a payload bit
    <<head::binary-size(6), b, rest::binary>> = wire
    bad = head <> <<bxor(b, 0x40)>> <> rest

    assert {[], _, _} = Proto.unframe(bad)
  end

  test "a truncated frame resynchronises at the next SYNC" do
    good = Proto.frame(:out, <<1, 0x000000037::40>>)
    truncated = :binary.part(good, 0, 4)

    {frames, <<>>, _} = Proto.unframe(truncated <> good)

    assert [{:out, _}] = frames
  end

  test "the last frame in a buffer is delivered without a following one" do
    # length-driven, not scan-to-next-SYNC: a board that only spoke when
    # it was about to speak again would be useless
    assert {[{:ping, <<9, 9, 9, 9>>}], <<>>, ""} =
             Proto.unframe(Proto.frame(:ping, <<9, 9, 9, 9>>))
  end

  test "a partial frame is held, not guessed at" do
    wire = Proto.frame(:ping, <<1, 2, 3, 4>>)
    head = :binary.part(wire, 0, 5)

    assert {[], ^head, ""} = Proto.unframe(head)
  end

  test "host and board type ranges do not overlap" do
    h = Map.values(Proto.host_to_board())
    b = Map.values(Proto.board_to_host())

    assert Enum.all?(h, &(&1 < 0x40))
    assert Enum.all?(b, &(&1 >= 0x80 and &1 < 0xC0))
    assert h -- b == h
  end

  test "OUT carries a whole 36-bit term" do
    word = 0xD_FFFF_FFFF
    {[{:out, p}], _, _} = Proto.unframe(Proto.frame(:out, <<3, word::40>>))

    assert %{engine: 3, word: ^word} = Proto.decode(:out, p)
  end

  test "PONG reports capabilities the host can test one at a time" do
    caps = Proto.cap(:ping) ||| Proto.cap(:out) ||| Proto.cap(:write_sd)
    p = <<0xDEADBEEF::32, Proto.version(), caps::16, 2, 104::16, 0x01>>

    d = Proto.decode(:pong, p)

    assert d.version == 1
    assert d.engines == 2
    assert Proto.cap?(d.caps, :out)
    refute Proto.cap?(d.caps, :read_state)
    assert :write_sd in d.cap_list
  end

  test "an oversized payload is refused rather than truncated" do
    assert_raise ArgumentError, fn ->
      Proto.frame(:wdata, :binary.copy(<<0>>, Proto.max_payload() + 1))
    end
  end

  test "STATUS decodes to per-engine structs plus core state" do
    eng = <<7::16-little, 0x4321::16-little, 3, 1, 5::16-little, 4::16-little, 0, 1>>
    core = <<0x08, 0x0A, 97::16-little>>

    d = Proto.decode(:status, eng <> eng <> core)

    assert length(d.engines) == 2
    assert hd(d.engines).pc == 7
    assert hd(d.engines).seats == [1, 2, 3, 4]
    assert hd(d.engines).idle
    assert d.loader_state == 8
    assert d.write_done
    assert d.from_uart
    assert d.entry0 == 97
  end
end
