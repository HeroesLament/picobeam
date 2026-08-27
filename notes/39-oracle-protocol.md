# 39 — The oracle protocol

A directive, so this note is a specification rather than a diary. It
defines **pbo/1**, the protocol spoken over the ULX3S's debug cable in
both directions: the board's view of itself out, and images and commands
in.

`PicoBEAM.Oracle.Proto` is the machine-readable copy — frame types,
field layouts and the CRC in one Elixir module that both the host tools
and the RTL emitter read, because `notes/30` already learned what
happens when two halves of this project each keep their own table.

---

## 1. What the protocol is for

Two jobs that turn out to be the same job.

**An oracle view.** In this project "the oracle" is `machine.ex` — the
model that says what the gates should do — and every testbench is a
word-for-word comparison against it. On silicon that comparison has
never been possible: the board's debug UART carries a 35-character
status line, and the only thing it says about the program's *output* is
the low byte of the most recent one. A board run cannot be diffed
against a model run.

It can now. `OUT` frames carry every `out` word, tagged by engine, in
order. `pbdiff` compares a board transcript against `Machine.run/2`'s
`out_raw` and prints the first divergence. That closes the last gap
between the model and the machine: model → netlist was closed by the
gate, netlist → silicon was not closed by anything.

**Rapid iteration.** `notes/37` made an image pushable over one wire and
`notes/38` made it stick. Both are hard-wired: one image format, one
device, one sector. Generalising that to *arbitrary bytes at an
arbitrary block address on a selectable device* is most of the work of
having a protocol at all, so it is the same job.

## 2. Physical and framing

115200 8N1 by default, one wire each way, no flow control. The FTDI will
do 3 Mbaud and the receiver is a divider; `PING` reports the current
divisor and a future `SETBAUD` can change it.

A frame is:

```
  SYNC  TYPE  LEN_LO LEN_HI  PAYLOAD…  CRC_LO CRC_HI
  0x01   1B      2B (LE)      LEN B      2B (LE)
```

`LEN` counts payload bytes only, 0..1024. `CRC` is CRC-16/CCITT-FALSE
(poly 0x1021, init 0xFFFF, no reflection, no final xor) over `TYPE`,
`LEN` and `PAYLOAD` — everything after `SYNC`, before stuffing.

**Stuffing.** Inside a frame, after `SYNC` and including the CRC:

```
  0x01  →  0x02 0x21
  0x02  →  0x02 0x22
```

(escape, then the byte xor 0x20 — SLIP's trick with different
constants). So `SYNC` occurs **only** at a frame boundary, by
construction. That is the property worth paying for: after any number of
dropped or spurious bytes, the receiver resynchronises at the next
`SYNC` and is provably at a frame start, rather than scanning for a
plausible-looking header and hoping. A frame that fails CRC is
discarded silently; a frame that overruns `LEN` is discarded at the next
`SYNC`.

### 2.1 Why `SYNC` is `0x01`

Because `0x01` and `0x02` are not printable ASCII, and the board still
emits its human-readable status line as plain text between frames.

That is deliberate. The 35-character line is what you read when you have
just flashed a board, have no tools running, and want to know whether it
is alive — `screen /dev/cu.usbserial-* 115200` shows it, unchanged,
with short unreadable bursts between lines where the binary frames go. A
protocol that made the cable unreadable without its own client would
have been a regression dressed as progress.

## 3. Frame types

Host → board is `0x00`–`0x3F`. Board → host is `0x80`–`0xBF`. Everything
else is reserved and MUST be ignored (not NAKed — an unknown frame from
a newer peer is not an error).

### 3.1 Host → board

| type | name | payload |
|---|---|---|
| `0x01` | `PING` | `token:4` |
| `0x02` | `READ` | `space:1, addr:4, count:2` |
| `0x03` | `WOPEN` | `device:1, lba:4, len:4` |
| `0x04` | `WDATA` | `seq:2, bytes:…` |
| `0x05` | `WCLOSE` | `flags:1` |
| `0x06` | `BOOT` | `entry0:2, entry1:2` |
| `0x07` | `RESET` | `scope:1` |
| `0x08` | `SUB` | `mask:2, divisor:2` |

`WCLOSE.flags`: bit 0 `VERIFY` — read the blocks back and compare;
bit 1 `LOAD` — parse the written image and load it through the side
door; bit 2 `BOOT` — and then boot it. `LOAD|BOOT` together are exactly
what `notes/37`'s bare push did, which is now one special case of a
general facility rather than the only thing on offer.

`RESET.scope`: 0 engines only, 1 the whole core (loader included),
2 request a full reconfiguration if the platform can.

`SUB.mask` selects which unsolicited frames the board emits — bit 0
`STATUS`, bit 1 `OUT`, bit 2 `EVENT`, bit 3 the ASCII line — and
`divisor` sets the `STATUS` rate in units of 4,096 clocks. `mask` is
`0x000B` at reset: status, out, and the ASCII line.

### 3.2 Board → host

| type | name | payload |
|---|---|---|
| `0x81` | `PONG` | `token:4, ver:1, caps:2, engines:1, baud_div:2, devices:1` |
| `0x82` | `DATA` | `space:1, addr:4, bytes:…` |
| `0x83` | `ACK` | `ref:1, seq:2, status:1` |
| `0x84` | `NAK` | `ref:1, seq:2, reason:1` |
| `0x85` | `OUT` | `engine:1, word:5` |
| `0x86` | `STATUS` | see 3.4 |
| `0x87` | `EVENT` | `kind:1, engine:1, slot:1, detail:4` |
| `0x88` | `LOG` | ASCII |

`OUT.word` is the 36-bit term, big-endian in 5 bytes, top nibble zero —
the same encoding the `.pbi` pool uses, so the host decodes it with the
same three lines. This is the oracle frame; everything else is
convenience.

`EVENT.kind`: 1 process died, 2 abnormal death, 3 fault, 4 halt,
5 collection, 6 loader state change. `detail` carries the reason atom
index for a death and the state for the loader.

### 3.3 Address spaces for `READ`

| space | unit | returns |
|---|---|---|
| `0x00` `CODE` | bundle index | 9 bytes |
| `0x01` `POOL` | pool index | 5 bytes |
| `0x02` `HEAP` | cell | 10 bytes (two 36-bit words) |
| `0x03` `PROC` | slot | `state:1, serial:4, pc:2, reason:1, flags:1` |
| `0x04` `WINDOW` | seat×16 + reg | 5 bytes |
| `0x05` `MBOX` | slot×64 + index | `word:5, hash:2` |
| `0x06` `COUNT` | counter id | 4 bytes |
| `0x07` `BLOCK` | device sector | 512 bytes |

`0x07` is how a host verifies a write, and how `pbdiff` can be pointed
at what is actually on the card rather than what it believes it sent.

Spaces `0x02`–`0x05` require read ports into memories the engines are
using. Those are specified here and **not implemented in pbo/1** — see
§6. `CODE`, `POOL`, `COUNT` and `BLOCK` are.

### 3.4 `STATUS`

Per engine, 12 bytes each, concatenated:

```
  pc:2  seats:2 (four 5-bit states, packed)  occ:1  qcount:1
  spawns:2  deaths:2  faults:1  flags:1
```

then 4 bytes of core state: `loader:1` (state | err<<4), `write:1`
(busy, done, err, from_uart), `entry0:2`.

Binary, because the ASCII line's fields have been repurposed twice
already (`notes/26` bug 3, `notes/36`) and each repurposing is a lie in
somebody's terminal until the note is read. A struct is not a lie.

## 4. Mass storage

`WOPEN`/`WDATA`/`WCLOSE` write **opaque bytes at a block address on a
named device**. Nothing in the transfer knows what a `.pbi` is; the
image format is a payload, not a protocol feature.

| device | id | block | notes |
|---|---|---|---|
| microSD | `0x00` | 512 B | CMD24, `notes/38` |
| SPI flash | `0x01` | 256 B page / 4 KB erase | specified, not implemented |

`PONG.devices` is a bitmap of what this bitstream actually has, so a
host tool written today works against a bitstream built tomorrow, and
vice versa. That matters more here than in most places: reflashing is
twenty-five minutes of place-and-route, so the host and the board will
routinely be different ages.

`WDATA.seq` numbers the chunks from zero. The board `ACK`s each one and
`NAK`s a gap; the host retransmits from the last acknowledged sequence.
There is no window — at 115200 the receiver has 104 clocks per byte and
the buffer is 8 KB, so the only thing an ack buys is *knowing*, and
knowing is the point of having a protocol.

The SPI flash entry is why the device field exists at all. Writing the
config flash means a board that boots a program with no card in it,
which is the natural end of the road `notes/37` started down — and it is
specified now so that adding it later is an implementation, not a
protocol change.

## 5. Rules

1. **Unsolicited frames may arrive at any time**, including between a
   request and its response. The protocol is asynchronous, not
   lockstep; a host that assumes the next frame after `READ` is its
   `DATA` will be wrong the first time a process dies.
2. **Unknown frame types are ignored, not NAKed.** Version skew is the
   normal case, not an error.
3. **The board never initiates a request.** It emits events and answers;
   it never asks the host for anything. A debug cable that can be
   *driven* by the target is a debug cable that can be used against you.
4. **`READ` is the only way to observe, `WRITE` the only way to change.**
   There is no "poke this register" frame and there will not be one.
   The board exposes named spaces with defined units, and that set is
   the whole attack surface.
5. **A frame that fails CRC never happened.** No NAK, no counter, no
   retry — the host's timeout handles it. Reporting corruption over the
   corrupted channel is a way to turn one bad frame into two.

## 6. What is built, and what is written down

Being precise about this is the point of writing the protocol before
building all of it.

**Built and tested:**

| | where |
|---|---|
| framing, stuffing, CRC-16 | `PicoBEAM.Oracle.Proto` |
| frame/field/space/device/capability tables | `PicoBEAM.Oracle.Proto` |
| encode, decode, stream reassembly | `PicoBEAM.Oracle.Proto` |
| the properties in §2 and §5, as assertions | `test/oracle_proto_test.exs` |

Thirteen tests, and each one is a sentence in this note: that `SYNC`
occurs exactly once in a frame whatever the payload, that the board's
ASCII line survives between frames, that a corrupted frame never
happened, that a truncated frame resynchronises at the next `SYNC`, that
the last frame in a buffer is delivered without a following one, and
that the CRC agrees with CCITT-FALSE's standard check vector.

**Specified, with the RTL still to come:**

Every frame type. The board today speaks the *pre-protocol* dialect —
`notes/37`'s bare `pBM2` push and `notes/38`'s write-through, with the
35-character ASCII line coming back — and that dialect is a strict
subset of `WOPEN`/`WDATA`/`WCLOSE(LOAD|BOOT)` with the framing removed.
The framer, the deframer and the command dispatch are the next
increment; §7 is what makes building them safe to do incrementally.

The rows that are specified but will stay unimplemented longest are
`READ` of `HEAP`, `PROC`, `WINDOW` and `MBOX`. They need read ports into
memories the engines are actively using, and a debug port that steals a
cycle from the machine it is observing changes what it observes. Doing
it properly means the spare port of a true dual-port BRAM, an arbiter
for the ones with no spare port, and a timing argument for each. That is
a milestone, not an afternoon — and a host tool can ask `PONG` whether
this board has it rather than finding out by getting nothing back.

## 7. Compatibility

`PONG.ver` is `1`. `caps` is a bitmap of §6's implemented rows. A host
MUST check `caps` before using a facility and MUST tolerate a board that
answers only `PING`.

The bare `pBM2` push from `notes/37` still works and is still the
fastest way to get an image onto a board: the framer ignores anything
that is not a `SYNC`, and the raw image loader is still watching the
same byte stream for its magic. Two protocols on one wire, neither able
to trigger the other — `0x01` is not `p`, and `pBM2` contains no `0x01`.
That is not an accident of the encoding; it is the reason the sync byte
was chosen after the magic already existed.

---

## 8. The dialect that runs today, on silicon

Before the framing exists, the thing it will replace already works, and
it works on the board:

```
push:    p03b 0 9 00 001 004 0 5 91 80 00 00
                                  │ ││
                                  │ │└─ from_uart: this image came off the wire
                                  │ └── the card write finished, no error
                                  └──── 0x91 = 145, the pushed program's answer
reflash: p03b 0 9 00 001 004 0 0 91 80 00 00
                                  │ │
                                  │ └─── from_uart: 0
                                  └───── loader state 8: read off the CARD
```

An image went down one wire; the machine rebooted into it; the card was
rewritten behind the running program; and after a reconfiguration the
loader found the new image on the card and booted it with nothing
attached but power.

That is the loop `notes/37` and `notes/38` were aiming at, closed on
hardware. What pbo/1 adds is not the capability — it is being able to
ask the board what it has, address a device and a block, know whether a
chunk arrived, and get the machine's `out` stream back word for word so
a board run can be diffed against the model the way a netlist run
already is.

### A tooling note that cost half an hour

`fujprog` talks to the FTDI through libusb, which detaches the kernel
driver. After any JTAG operation, `/dev/cu.usbserial-*` still exists and
reads from it block forever — the device node is there and nothing is
behind it. `fujprog -t` re-attaches; `fujprog -P <tty> -a <file>` sends a
raw file through the TTY. So on this machine the sequence is
`fujprog -P … -a image.img` to push and `fujprog -t` to watch, and a
plain `cat` in between will hang rather than fail.

Worth knowing before writing a host tool that assumes it owns the port.
