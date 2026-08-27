# 43 — Binaries, and therefore strings

Maps landed with `notes/42`, and Elixir strings are the other half of
what "runs real Elixir" has to mean. A string is a UTF-8 binary, so this
note is about binaries and the string part follows.

## One byte per word, on purpose

A binary is a boxed object shaped like everything else in this machine:

```
word 0        hdr(1 + n)
word 1        the byte count
word 2 + i    byte i
```

One byte per 36-bit word. Four times the memory a packed layout would
use, on a machine whose semispace is 128 cells — so `"hello world"`
costs six of them.

That is a decision and not an oversight, and the reason is the ISA:

```
mkbin rd, rn        allocate a binary of rn BYTES
binat rd, rb, ri    byte ri; index 0 is the byte count
mset  rb, rv        write at the latched index — the map op, reused
```

Every one of those is **byte indexed**. How many bytes share a word is
known only to `Heap`'s address arithmetic, so packing four to a word
later changes that arithmetic and a byte-select mux — and not one
compiled program, not one prelude function, not one line of the front
end. The expensive version is the one that can be replaced without
breaking anything, which is the version to build first.

The gates cost of the whole feature was two commands. `mkbin` is
`mkmap`'s allocation with a different header multiplier and a different
result tag; `binat` is `mapat`'s read with a different tag check. `mset`
was already there and now accepts a map or a binary — the two objects
whose index a program COMPUTES rather than knows.

## There is no constant area, and a string is where that shows

`Encoding`'s literal pool holds 36-bit WORDS. A binary is a heap object,
so it cannot live there, and a string literal is therefore
**constructed** — the same as a tuple literal or a list literal has
always been on this machine.

The cost is real and it is not hidden:

* two bundles per byte while the index fits `tset`'s four bits, four per
  byte after that
* a string in a PATTERN pays it again, on every match, because matching
  builds the literal to compare against

`"hello"` is ten bundles of code. `bin_demo.ex` is 406, and most of that
is strings.

BEAM puts literals in a per-module constant area and terms point into
it. Doing that here means a third address space beside the heap and the
code store, a tag that says "this pointer is into constants", and a
collector that knows not to move what it finds there. It is a real
feature and it is where the next big saving is.

## What erlc does to strings before we see them

Two things, and both would have made a matcher that did the obvious
thing wrong.

**Adjacent literal bytes are packed into one wide segment.** `"hi"` in a
pattern is not two eight-bit fields; it is

```erlang
#c_bitstr{val = 26729, size = 16, unit = 1, type = integer, flags = [unsigned, big]}
```

— one sixteen-bit integer. A matcher that only understands `size = 8`
understands almost no Elixir strings at all. `expand_bytes/2` unpacks
any segment whose size is a multiple of eight, big-endian, which is what
the flags on every one of them say.

**`a <> b` is a `c_binary` with two `:binary`/`:all` segments**, not a
call to anything. So concatenation is the same code path as
`<<x, y, z>>`, and both fold through the prelude's `bin_concat/2`.

## The rest is a copy

`<<c, rest::binary>>` binds `rest` by **copying** it. BEAM would make a
sub-binary — a base pointer, an offset and a length, three words and no
copy — and every operation on every binary would then have to know that
a binary might be one.

That is the feature this machine does not have, and the shape of it is
worth writing down while the decision is fresh:

* a fourth boxed layout, `{base, offset, length}`, under the same `bin`
  tag or a new one
* `binat` learning to follow it, which is a second heap read on the
  critical path of every byte access
* the collector learning that a sub-binary keeps its base alive
* `mset` refusing one, because a sub-binary is a view and not storage

Until then, walking a string with `<<_c, rest::binary>>` is O(n²) in
allocation, which for a 200-turn loop is nine collections. It works, and
`binelixir` proves it works, and it is the wrong way to write a loop on
this machine — `binat` with an index is the right one.

## What Elixir gets

```elixir
c = a <> b                          # concatenation
:erlang.byte_size(c)                # binat index 0
:binary.at(s, i)                    # byte access
:erlang.binary_to_list(s)           # and back
:erlang.list_to_binary([104, 105])
:erlang.is_binary(s)                # a tag test
def greet("hi"), do: 1              # a literal in a pattern
def head(<<c, rest::binary>>), ...  # a byte and a tail
def count(<<>>, n), do: n           # ...and the empty binary
```

`bin_demo.ex` runs all of it, on the netlist, against the model's `out`
stream, through eighteen collections.

## What is not done

* **Sub-binaries**, above.
* **A constant area** for literals, above.
* `==` on binaries is word equality, so two equal strings at different
  addresses compare unequal in an EXPRESSION. In a PATTERN they compare
  correctly, because a pattern goes through `bin_eq/2`. That asymmetry
  is not binaries' fault — tuples and lists have had it since M1 — but
  strings are where a programmer meets it first, and it belongs on the
  scoreboard rather than in a footnote.
* Unicode. A binary is bytes; `String.length/1` counts codepoints, and
  nothing here knows what a codepoint is.
* Bit-level syntax. `<<x::4>>` is refused rather than approximated: this
  machine has binaries, not bitstrings.
