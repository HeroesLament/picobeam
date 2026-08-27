defmodule PicoBEAM.Term do
  @moduledoc """
  The 36-bit term representation (notes/03-architecture.md).

      generic:  [ tag : 4 ][           payload : 32           ]
      PID:      [ tag : 4 ][ engine : 4 ][ slot : 6 ][ serial : 22 ]

  A term is modeled as a plain non-negative integer < 2^36 — exactly the word
  the hardware carries. The reference model never smuggles Elixir richness
  through a word: anything that doesn't fit a payload lives on a heap and the
  word is a pointer.

  Fixnums are signed 32-bit two's complement in the payload. Arithmetic that
  leaves that range TRAPS (exit reason `:overflow`) — it never wraps
  (notes/09, consequence 4).
  """

  import Bitwise

  @word_bits 36
  @payload_bits 32
  @payload_mask (1 <<< @payload_bits) - 1
  @word_mask (1 <<< @word_bits) - 1

  @int_min 0 - (1 <<< 31)
  @int_max (1 <<< 31) - 1

  # ---------------------------------------------------------------------------
  # Tags — 4 bits. Three spare (0xD..0xF).
  # ---------------------------------------------------------------------------
  @tags %{
    int: 0x0,
    atom: 0x1,
    nil: 0x2,
    cons: 0x3,
    tuple: 0x4,
    pid: 0x5,
    ref: 0x6,
    fun: 0x7,
    bin: 0x8,
    hdr: 0x9,
    fwd: 0xA,
    retaddr: 0xB,
    catch: 0xC,
    # WIRE-ONLY. A `wcons` word never lives on a heap and never reaches
    # a register: it exists for the length of a message, as the marker
    # the serialiser emits after a cons cell's head and tail. Tuples
    # need no such tag because they already have a header word (`hdr`)
    # and the serialiser emits that same word. See `PicoBEAM.Serial`.
    wcons: 0xD,
    # `notes/42` — a flatmap. Tuple-shaped like a fun: a header, then a
    # count, then the key/value pairs, one pair per CELL so a probe reads
    # both halves at once. The tag is its own so `element/2` on a map
    # raises and `is_map/1` is a tag test.
    map: 0xE
  }

  # Reserved atom indices — fixed by pico_beam's version so hardware can emit
  # fault reasons with zero allocation (notes/10). Application atoms are
  # interned above @reserved_atom_count.
  @reserved_atoms [
    :normal,
    :killed,
    :kill,
    :badarith,
    :bad_tag,
    :overflow,
    :heap_full,
    :mailbox_full,
    :stack_overflow,
    :system_limit,
    :badarg,
    :noproc,
    :EXIT,
    :DOWN,
    true,
    false,
    :ok,
    :error,
    # `notes/42` — appended, not inserted. Indices 0..17 are ABI and a
    # renumber there would move every reason the RTL emits as a literal;
    # program atoms are numbered from `@reserved_atom_count` by
    # `Encoding.image/2` at build time, so they simply start two higher
    # in the next build. BEAM raises `{badfun, F}` for a call to a
    # non-fun and `{badarity, {F, Args}}` when the counts disagree, and a
    # machine that says `badarg` for either is one whose supervisors
    # match on the wrong reason.
    :badfun,
    :badarity,
    # `map` tag terms have their own key error, and it is not `badarg`:
    # `Map.fetch!/2` and `%{m | k => v}` both raise `{badkey, K}`.
    :badkey,
    # a map past the flatmap ceiling, kept distinct from `system_limit`
    # so the message says which limit
    :badmap,
    # `notes/50` — `whereis/1` on an unregistered name returns
    # `:undefined`, and the GATES return it as a literal atom word, so
    # its index is ABI the same way a fault reason's is. Appended, per
    # the rule above.
    :undefined
  ]
  @reserved_atom_count length(@reserved_atoms)

  def word_bits, do: @word_bits
  def int_min, do: @int_min
  def int_max, do: @int_max
  def reserved_atoms, do: @reserved_atoms
  def reserved_atom_count, do: @reserved_atom_count

  def tag_value(name), do: Map.fetch!(@tags, name)

  # ---------------------------------------------------------------------------
  # Word construction / inspection
  # ---------------------------------------------------------------------------

  def make(tag_name, payload) when payload >= 0 do
    tag_value(tag_name) <<< @payload_bits ||| (payload &&& @payload_mask) &&& @word_mask
  end

  def tag(word), do: word >>> @payload_bits &&& 0xF

  def tag_name(word) do
    t = tag(word)
    {name, _} = Enum.find(@tags, fn {_, v} -> v == t end)
    name
  end

  def payload(word), do: word &&& @payload_mask

  def is?(word, tag_name), do: tag(word) == tag_value(tag_name)

  # ---------------------------------------------------------------------------
  # Fixnums — signed 32-bit, trap on overflow
  # ---------------------------------------------------------------------------

  def int(v) when v >= @int_min and v <= @int_max do
    make(:int, v &&& @payload_mask)
  end

  def int_value(word) do
    raw = payload(word)
    if (raw &&& 1 <<< 31) != 0, do: raw - (1 <<< 32), else: raw
  end

  @doc "Checked fixnum construction: {:ok, word} | {:error, :overflow}."
  def int_checked(v) when v >= @int_min and v <= @int_max, do: {:ok, int(v)}
  def int_checked(_), do: {:error, :overflow}

  # ---------------------------------------------------------------------------
  # Atoms, nil, pointers, pids, refs
  # ---------------------------------------------------------------------------

  def atom(index) when index >= 0, do: make(:atom, index)
  def nil_term, do: make(:nil, 0)

  @doc """
  A cons or tuple pointer, built from a WORD address.

  The payload it carries is the **cell** index — `notes/03` specified a
  uniform two-word cell and `RTL.Heap` addresses cells, so a pointer
  names the cell, not the word inside it. The model used to name the
  word, which meant an `out` of any compound term printed a different
  number on the two sides and no gate-vs-model comparison of a compound
  result was possible at all (`notes/26` bug 5). The heap's moduledoc
  always said the model was the side that would move; this is it moving.

  Callers keep working in words — every heap index in `Machine` is a word
  index — and the conversion lives here, once, rather than as a `>>> 1`
  scattered over twenty call sites.
  """
  def cons(word_addr), do: make(:cons, cell_of(word_addr))
  def tuple(word_addr), do: make(:tuple, cell_of(word_addr))

  @doc "Cell index of a word address. Objects are cell-aligned, so this is exact."
  def cell_of(word_addr), do: word_addr >>> 1

  @doc "Word address a cell index names."
  def cell_word(cell), do: cell <<< 1

  @doc "The word address a cons/tuple pointer points at."
  def word_of(word), do: cell_word(payload(word))

  @doc """
  Round a word count up to whole cells. A tuple of even arity is an odd
  number of words (`hdr` + elems) and would leave the bump pointer mid-cell,
  which the RTL cannot express — it allocates whole cells and wastes the odd
  word. The model now wastes it too, so both run out of heap at the same
  allocation.
  """
  def cell_round(n), do: n + (n &&& 1)
  def hdr(arity), do: make(:hdr, arity)

  @doc """
  A fun POINTER (`notes/42`). Cell-addressed like `cons` and `tuple`,
  because a fun is a boxed object laid out exactly like a tuple: a
  header, then `funinfo`, then the captured free variables. The tag is
  what differs, and it differs so that `element/2` on a fun raises the
  way BEAM promises.

  This used to make a fun word out of an INDEX, from a version of the
  plan where a fun named an entry in a table. Nothing called it.
  """
  def fun(word_addr), do: make(:fun, cell_of(word_addr))

  @doc """
  A map POINTER. Cell-addressed like every other boxed object.

      word 0        hdr(1 + 2n)
      word 1        the pair count, as a fixnum
      word 2 + 2j   key j
      word 3 + 2j   value j

  So pair `j` is exactly cell `j + 1`, and one heap read returns both
  halves of it — which is what makes a linear probe one cycle per pair
  rather than two.
  """
  def map(word_addr), do: make(:map, cell_of(word_addr))

  @doc """
  A binary POINTER (`notes/43`).

      word 0        hdr(1 + n)
      word 1        the byte count
      word 2 + i    byte i

  One byte per word in v1 — four times the memory a packed layout wants,
  and deliberate: `binat` is BYTE indexed, so how many bytes share a word
  is invisible above the store and can change without touching a single
  compiled program.
  """
  def bin(word_addr), do: make(:bin, cell_of(word_addr))

  @doc """
  `funinfo` — the immediate a closure carries in its first word:
  `{entry, arity, nfree}` packed into a fixnum. `entry` is a pc, so it
  is a function NAME's index on the model and a bundle address in an
  image, exactly as every other pc in this machine is.
  """
  def funinfo(entry, arity, nfree), do: int(entry * 256 + arity * 16 + nfree)

  def funinfo_entry(word), do: div(int_value(word), 256)
  def funinfo_arity(word), do: rem(div(int_value(word), 16), 16)
  def funinfo_nfree(word), do: rem(int_value(word), 16)

  @doc """
  The empty list, as a word.

  Also what the heap's cell padding is written with: an object of odd
  word count occupies a whole cell and leaves a word behind, and that
  word has to be a term the collector will not follow (`notes/40`).
  """
  def nil_word, do: make(:nil, 0)
  def ref(serial), do: make(:ref, serial)

  @doc "PID payload: engine(4) | slot(6) | serial(22)."
  def pid(engine, slot, serial)
      when engine in 0..15 and slot in 0..63 and serial in 0..0x3FFFFF do
    make(:pid, engine <<< 28 ||| slot <<< 22 ||| serial)
  end

  def pid_engine(word), do: payload(word) >>> 28 &&& 0xF
  def pid_slot(word), do: payload(word) >>> 22 &&& 0x3F
  def pid_serial(word), do: payload(word) &&& 0x3FFFFF
end
