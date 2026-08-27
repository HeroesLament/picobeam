# 11 — Boot and images: the bitstream is the machine, the SD card is the tenant

Decisions from the boot/deployment design discussion (2026-08-22).
Companion to `10-userland.md`. The ESP32 is deliberately out of scope.

## The split, and why it is load-bearing

Application code does not live in the bitstream. This is not repo hygiene;
it decouples the two compile cycles that must never be coupled: synthesis
(minutes-to-hours, changes rarely) and code (seconds, changes constantly).
If changing a restart policy required a nextpnr run, the machine would be
unusable past week two.

- **Bitstream** — the machine: fabric, IP, boundary declarations, stage-0
  loader, boundary-hash CSR. Lives in QSPI flash (ECP5's normal
  configuration path).
- **Code image** — the tenant: the application, pre-linked. Lives on the
  microSD card as a file. The card is the unit of field deployment: build
  `myapp.pbi`, copy it next to the golden image, insert, power on.

Consequence: the "shared code ROM" of the fit model is ROM only for the
stage-0 loader. The main code store and atom table are write-once-at-boot
RAM, filled by the loader while the engines sit in reset — no arbiter
needed, load completes before fetch begins.

## The image format: packbeam's role, ELF's discipline

The `.pbi` (name provisional) plays the role AtomVM's `.avm`/packbeam plays
— one file, drop it on the card — but is **pre-linked**, not an archive.
AtomVM parses BEAM chunks and resolves atoms at load time because it has a
runtime module system; we do not and should not pay for one. `mix
pico.image` emits the image flattened:

- header: magic, format version, **SDK/boundary hash**, entry point,
  initial supervision-tree spec
- atom table section — application atoms already at final indices, stacked
  above the reserved hardware region (whose indices are fixed by
  `pico_beam`'s version, so silicon can emit fault reasons blind)
- code section(s) — calls resolved to code addresses
- per-section CRCs + total length

Payoff: the loader stays dumb (seek, stream, checksum, compare, go) and
boot time is a **constant** — fitting for a machine whose personality is
"the timing is a number". Runtime linking is a month-shaped temptation on
the charter's out-list. Whole-image reload is the v1 answer to "no hot code
loading": rewriting ~34 KB and re-seeding the tree is a soft reboot in
milliseconds.

## Stage-0: the first Erlang program the machine runs is its own bootloader

Walking a FAT filesystem in RTL is a classic month; walking it in software
is an afternoon. So stage-0 is picoBEAM code in bitstream-initialised EBR,
running on engine 0 with the rest of the fabric in reset, talking to a dumb
SD-SPI block through the same port/SIF boundary as everything else
(SPI-mode SD at ~20–25 MHz — estimate — is entirely sufficient). It:

1. reads the DIP switches and the boot-state sector
2. picks a slot (precedence below), walks FAT, finds the image
3. streams it into code RAM + atom table, checking per-section CRCs
4. compares the image's SDK hash against the bitstream's boundary CSR —
   on mismatch: loud refusal (LEDs/USB), fall back; never a half-booted
   mystery
5. seeds the initial tree from the header, releases the engines

Being an ordinary process, the loader is inside the supervision story: a
boot failure is an exit, and the level-0 fabric watchdog has something
concrete to catch.

## Slots, DIP switches, and A/B fallback

Slot 0 is the **golden image**: written once, never the deploy target.
The ULX3S's four DIP switches are spent as override, not happy path:

| Switch | Meaning |
|---|---|
| 1–2 | forced slot select (0–3) |
| 3 | safe mode: boot slot 0, skip all automatics |
| 4 | free |

Default DIP position means **automatic**: normal boots must not depend on
switch state, because the A/B logic protects an unattended board while a
human-set switch rescues an attended one. Precedence, top wins:
safe-mode bit → forced-slot bits → boot-state automatics → default slot.

**A/B automatics:** the loader bumps a boot-attempt counter before
jumping; the application's "boot good" check-in clears it; after 3 failed
attempts (choice, not measurement) on the selected slot the loader falls
back to the known-good slot and says so. Push-a-broken-MAC-layer recovery
is a power cycle, not a JTAG session.

**Boot state lives in one reserved raw sector outside the filesystem**
(the gap before the first partition). One block read, one block write, no
FAT-write machinery in stage-0 — the uboot-env problem solved the boring
way. Image *files* stay FAT-visible for humans; boot *state* stays a raw
sector for the machine. (The Nerves artifact-checksum gotcha in our own
history is the reason the hash/fallback path is non-negotiable, not
nice-to-have.)

## Sizing and the ceiling

v1 image ≈ the fit model's shared code store: 15 EBR × 2,304 B = ~34 KB
plus the 2-EBR atom table (arithmetic). At SPI-mode rates that loads in
tens of milliseconds (estimate); boot time is dominated by SD card init.

The ceiling-lifter is already an open question: if Q5's JOP-style method
cache is built, the v2 arrangement is image → SDRAM at boot, EBR as the
method cache filled from SDRAM — code size then bounded by 32 MB, not
block RAM, with JOP's worst-case-analysable miss behaviour intact. The
method cache is not just a WCET mechanism; it is the memory hierarchy that
makes real applications fit. (Appended to Q5 in `08-open-questions.md` —
it strengthens the "build it at M2" leaning.)

## Load paths and roadmap touches

- **SD** is the field path. **USB (M8's CDC stack)** is the bench path —
  seconds, no card shuffle — and the loader prefers it when a host is
  talking. M8 therefore gains a second role: not just observability but
  the development code-load channel.
- One hardware caution for the ULX3S: the SD lines are shared with the
  ESP32's pins. Whatever firmware that chip carries must be quiet on the
  bus during boot (hold it in reset if in doubt) — a chatty stock firmware
  poking the card mid-load would fail magnificently confusingly. Recorded
  as a pin fact only; the ESP32 plays no role in this design.
- The boot chain end to end: QSPI → bitstream (machine + stage-0 +
  boundary CSR) → loader → DIP/boot-state → slot → verify → load →
  seed tree → release engines → application.
