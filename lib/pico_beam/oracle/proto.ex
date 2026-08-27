defmodule PicoBEAM.Oracle.Proto do
  @moduledoc """
  **pbo/1** — the wire format, in one place.

  `notes/39` is the specification; this module is the machine-readable
  copy of it, and it is the copy that both halves read. The host tools
  encode and decode with the functions below; `scripts/emit_proto.exs`
  writes the same constants into a Verilog header the RTL includes. The
  alternative is a table in a note, a table in Elixir and a table in
  Verilog, drifting — which is `notes/30`'s lesson about atoms, and it
  cost a day.

      SYNC  TYPE  LEN(2 LE)  PAYLOAD  CRC16(2 LE)
      0x01

  Stuffed after `SYNC`: `0x01` → `0x02 0x21`, `0x02` → `0x02 0x22`.
  CRC-16/CCITT-FALSE over TYPE, LEN and PAYLOAD, before stuffing.

  `SYNC` is `0x01` because it is not printable ASCII: the board still
  emits its human status line as plain text between frames, so a bare
  `screen` on the port is still useful. See `notes/39` §2.1.
  """

  import Bitwise

  @sync 0x01
  @esc 0x02
  @esc_xor 0x20
  @version 1
  @max_payload 1024

  def sync, do: @sync
  def esc, do: @esc
  def version, do: @version
  def max_payload, do: @max_payload

  # ---- frame types ---------------------------------------------------------
  # host -> board
  @h2b %{
    ping: 0x01,
    read: 0x02,
    wopen: 0x03,
    wdata: 0x04,
    wclose: 0x05,
    boot: 0x06,
    reset: 0x07,
    sub: 0x08
  }

  # board -> host
  @b2h %{
    pong: 0x81,
    data: 0x82,
    ack: 0x83,
    nak: 0x84,
    out: 0x85,
    status: 0x86,
    event: 0x87,
    log: 0x88
  }

  @types Map.merge(@h2b, @b2h)
  @names Map.new(@types, fn {k, v} -> {v, k} end)

  def types, do: @types
  def type(name), do: Map.fetch!(@types, name)
  def name(code), do: Map.get(@names, code)
  def host_to_board, do: @h2b
  def board_to_host, do: @b2h

  # ---- address spaces for READ ---------------------------------------------
  @spaces %{code: 0x00, pool: 0x01, heap: 0x02, proc: 0x03, window: 0x04,
            mbox: 0x05, count: 0x06, block: 0x07}
  @space_names Map.new(@spaces, fn {k, v} -> {v, k} end)

  def spaces, do: @spaces
  def space(name), do: Map.fetch!(@spaces, name)
  def space_name(code), do: Map.get(@space_names, code)

  # `READ` unit size in bytes, by space. `block` is the device's block.
  @space_unit %{code: 9, pool: 5, heap: 10, proc: 9, window: 5, mbox: 7,
                count: 4, block: 512}
  def space_unit(name), do: Map.fetch!(@space_unit, name)

  # ---- devices -------------------------------------------------------------
  @devices %{microsd: 0x00, spiflash: 0x01}
  def devices, do: @devices
  def device(name), do: Map.fetch!(@devices, name)

  # ---- WCLOSE flags --------------------------------------------------------
  @wclose_verify 0x01
  @wclose_load 0x02
  @wclose_boot 0x04
  def wclose_flags(opts) do
    (if(opts[:verify], do: @wclose_verify, else: 0)) |||
      (if opts[:load], do: @wclose_load, else: 0) |||
      if(opts[:boot], do: @wclose_boot, else: 0)
  end

  # ---- SUB mask ------------------------------------------------------------
  @sub_status 0x0001
  @sub_out 0x0002
  @sub_event 0x0004
  @sub_ascii 0x0008
  def sub_mask(opts) do
    (if(opts[:status], do: @sub_status, else: 0)) |||
      (if opts[:out], do: @sub_out, else: 0) |||
      (if opts[:event], do: @sub_event, else: 0) |||
      if(opts[:ascii], do: @sub_ascii, else: 0)
  end

  # ---- capability bits, mirroring notes/39 §6 ------------------------------
  @caps %{
    ping: 0x0001,
    out: 0x0002,
    status: 0x0004,
    event: 0x0008,
    write_sd: 0x0010,
    boot: 0x0020,
    read_code: 0x0040,
    read_block: 0x0080,
    read_state: 0x0100,
    write_flash: 0x0200
  }
  def caps, do: @caps
  def cap(name), do: Map.fetch!(@caps, name)
  def cap?(bits, name), do: (bits &&& cap(name)) != 0

  def cap_list(bits), do: for({k, v} <- @caps, (bits &&& v) != 0, do: k)

  # ---- EVENT kinds ---------------------------------------------------------
  @events %{died: 1, abnormal: 2, fault: 3, halt: 4, gc: 5, loader: 6}
  def events, do: @events
  def event_name(k), do: Enum.find_value(@events, fn {n, v} -> v == k && n end)

  # ---- CRC-16/CCITT-FALSE --------------------------------------------------
  @doc """
  Poly 0x1021, init 0xFFFF, no reflection, no final xor.

  Chosen over a sum because a debug cable's failure mode is a dropped or
  doubled byte, and a sum cannot see a transposition. The RTL costs a
  16-bit shift register and eight xors.
  """
  def crc16(bin), do: crc16(bin, 0xFFFF)

  def crc16(<<>>, acc), do: acc

  def crc16(<<b, rest::binary>>, acc) do
    acc = bxor(acc, b <<< 8) &&& 0xFFFF
    acc = Enum.reduce(1..8, acc, fn _, a ->
      if (a &&& 0x8000) != 0, do: bxor(a <<< 1, 0x1021) &&& 0xFFFF, else: (a <<< 1) &&& 0xFFFF
    end)
    crc16(rest, acc)
  end

  # ---- framing -------------------------------------------------------------

  @doc "Encode one frame, ready for the wire."
  def frame(type, payload \\ <<>>) when is_binary(payload) do
    t = if is_atom(type), do: type(type), else: type
    len = byte_size(payload)

    if len > @max_payload do
      raise ArgumentError, "payload #{len} exceeds #{@max_payload}"
    end

    body = <<t, len::16-little>> <> payload
    crc = crc16(body)
    <<@sync>> <> stuff(body <> <<crc::16-little>>)
  end

  @doc "Byte stuffing: SYNC and ESC are the only two bytes that need it."
  def stuff(bin), do: for(<<b <- bin>>, into: <<>>, do: stuff_byte(b))

  defp stuff_byte(@sync), do: <<@esc, bxor(@sync, @esc_xor)>>
  defp stuff_byte(@esc), do: <<@esc, bxor(@esc, @esc_xor)>>
  defp stuff_byte(b), do: <<b>>

  @doc """
  Pull frames out of a byte stream.

  Returns `{frames, rest, text}` — decoded frames, the unconsumed tail,
  and any bytes that fell OUTSIDE a frame, which is the board's plain
  ASCII status line and is handed back rather than discarded.
  """
  def unframe(bin), do: scan(bin, [], <<>>)

  defp scan(<<>>, acc, text), do: {Enum.reverse(acc), <<>>, text}

  defp scan(<<@sync, rest::binary>> = all, acc, text) do
    case take_frame(rest, <<>>) do
      {:ok, body, tail} ->
        case check(body) do
          {:ok, frame} -> scan(tail, [frame | acc], text)
          :error -> scan(tail, acc, text)
        end

      # a SYNC inside what should have been a frame means the frame was
      # truncated. Stuffing guarantees SYNC cannot occur in a payload, so
      # this is not a guess: restart from the SYNC we found.
      {:resync, tail} ->
        scan(tail, acc, text)

      :incomplete ->
        {Enum.reverse(acc), all, text}
    end
  end

  defp scan(<<b, rest::binary>>, acc, text), do: scan(rest, acc, text <> <<b>>)

  # LENGTH-driven, with SYNC as the abort. Scanning to the next SYNC
  # instead would mean the last frame in a buffer is never delivered
  # until another one starts — which is exactly the kind of "works in
  # the test, hangs on the wire" that a protocol should not have.
  defp take_frame(bin, acc) do
    want = frame_size(acc)

    cond do
      want != nil and byte_size(acc) == want ->
        {:ok, acc, bin}

      want == :bad ->
        {:resync, bin}

      true ->
        case bin do
          <<>> -> :incomplete
          <<@sync, _::binary>> -> {:resync, bin}
          <<@esc>> -> :incomplete
          <<@esc, b, rest::binary>> -> take_frame(rest, acc <> <<bxor(b, @esc_xor)>>)
          <<b, rest::binary>> -> take_frame(rest, acc <> <<b>>)
        end
    end
  end

  # TYPE(1) + LEN(2) + payload + CRC(2), once LEN is in hand
  defp frame_size(<<_t, len::16-little, _::binary>>) when len <= @max_payload, do: 3 + len + 2
  defp frame_size(<<_t, _len::16-little, _::binary>>), do: :bad
  defp frame_size(_), do: nil

  defp check(<<t, len::16-little, rest::binary>>) when byte_size(rest) == len + 2 do
    <<payload::binary-size(len), crc::16-little>> = rest

    if crc16(<<t, len::16-little>> <> payload) == crc do
      {:ok, {name(t) || t, payload}}
    else
      :error
    end
  end

  defp check(_), do: :error

  # ---- payload helpers -----------------------------------------------------

  @doc "A 36-bit term as five big-endian bytes, top nibble zero."
  def term_bytes(word), do: <<word::40>>
  def term_of(<<word::40>>), do: word

  def decode(:pong, <<token::32, ver, caps::16, engines, baud_div::16, devices>>),
    do: %{token: token, version: ver, caps: caps, cap_list: cap_list(caps),
          engines: engines, baud_div: baud_div, devices: devices}

  def decode(:out, <<engine, word::40>>), do: %{engine: engine, word: word}

  def decode(:ack, <<ref, seq::16-little, status>>),
    do: %{ref: name(ref) || ref, seq: seq, status: status}

  def decode(:nak, <<ref, seq::16-little, reason>>),
    do: %{ref: name(ref) || ref, seq: seq, reason: reason}

  def decode(:event, <<kind, engine, slot, detail::32-little>>),
    do: %{kind: event_name(kind) || kind, engine: engine, slot: slot, detail: detail}

  def decode(:data, <<space, addr::32-little, bytes::binary>>),
    do: %{space: space_name(space) || space, addr: addr, bytes: bytes}

  def decode(:log, ascii), do: %{text: ascii}

  def decode(:status, bin), do: decode_status(bin, [])

  def decode(other, bin), do: %{type: other, raw: bin}

  defp decode_status(<<pc::16-little, seats::16-little, occ, qcount, spawns::16-little,
                       deaths::16-little, faults, flags, rest::binary>>, acc)
       when byte_size(rest) >= 4 do
    e = %{
      pc: pc,
      seats: for(i <- 0..3, do: seats >>> (i * 4) &&& 0xF),
      occ: occ,
      qcount: qcount,
      spawns: spawns,
      deaths: deaths,
      faults: faults,
      idle: (flags &&& 1) != 0,
      faulted: (flags &&& 2) != 0
    }

    decode_status(rest, [e | acc])
  end

  defp decode_status(<<loader, write, entry0::16-little>>, acc) do
    %{
      engines: Enum.reverse(acc),
      loader_state: loader &&& 0xF,
      loader_err: loader >>> 4,
      write_busy: (write &&& 1) != 0,
      write_done: (write &&& 2) != 0,
      write_err: (write &&& 4) != 0,
      from_uart: (write &&& 8) != 0,
      entry0: entry0
    }
  end

  defp decode_status(_, acc), do: %{engines: Enum.reverse(acc)}
end
