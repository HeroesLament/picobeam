# 42 — Funs, maps, and the two-version rule

The collector is in (`notes/41`), which unblocks everything that
allocates. This is the design for the three things that do: closures,
maps (and structs behind them), and hot code loading.

It is one note because the three share a decision. **What a call target
is** — a literal in a bundle, a word baked into a heap object, or an
entry read out of a table at call time — is the difference between a
local call, a fun, and a fully-qualified call, and BEAM's two-version
rule is a statement about exactly that.

## Funs

### The object

A fun is a boxed object with a header, laid out exactly like a tuple,
but the POINTER carries tag `fun` (0x7):

```
cell 0:  [ hdr(1 + nfree) | funinfo ]
cell 1:  [ free0          | free1   ]
cell 2:  [ free2          | free3   ]  ...
```

`funinfo` is an immediate carrying `{entry:9, arity:4, nfree:4}` packed
into a fixnum.

Same shape as a tuple, on purpose. `Collector`'s `obj_cells` already
computes `(arity + 2) >>> 1` from the header, so a fun costs two lines
— `T_FUN` joins `ev_ptr` and joins the `obj_cells` mux — rather than a
second kind of object for the collector to know about. `istag rd, rs,
:fun` is `is_function/1` for free.

Not an actual tuple, also on purpose. `tget`/`tarity` fault on a
non-tuple tag, so `element/2` on a fun raises, which is what BEAM
guarantees. `tset` is relaxed to accept tag 4 OR tag 7, because "fill
the freshly made object" is an idiom that already exists and a second
copy of it would be a second thing to keep right.

### The ops

```
mkfun   rd, k, nfree     k is a POOL index; pool[k] IS the funinfo word
tset    rf, 1 + j, rs    free variable j — funinfo is word 0 after the header
callfun rd, rf, arity    args staged 0..arity-1; the machine appends the
                         nfree free variables at arity..arity+nfree-1 and
                         calls `entry` with total arity = arity + nfree
```

`mkfun` reads the pool because the pool already exists, already travels
in the `.pbi` image, and already arrives through the side door, the card
and the wire. A dedicated fun table would have meant `.pbi` v3 and a
change to `SdBoot`, `ImageParser` and `UartLoader` for a memory holding
one word per fun.

The free-variable append is BEAM's convention, not an invention:
`call_fun Arity` takes the fun in `x[Arity]` and the closure's variables
become the LAST arguments. The consequence is the good part — **the
callee is an ordinary function** of arity `arity + nfree` and has no way
to reach "the closure" at all, so there is no `fget`, no closure
register, and no special frame.

### The entry is baked in, and that is the rule

`mkfun` copies a funinfo word that already contains the entry bundle.
Nothing is looked up at `callfun` time.

That is not a shortcut taken for the hardware's sake. It is half of
BEAM's two-version rule: **a fun made from a version of a module keeps
running that version**, forever, whatever is loaded afterwards. Baking
the entry into the object is the mechanism by which that is true here.

### badfun and badarity

BEAM raises `{badfun, F}` when the target of a call is not a fun and
`{badarity, {F, Args}}` when the counts disagree. picoBEAM has neither
atom.

Reserved atoms 0..17 are ABI and program atoms are numbered from 18 by
`Encoding.image/2` at build time, so APPENDING `badfun` (18) and
`badarity` (19) renumbers nothing that is already fixed — program atoms
simply start at 20 in the next build, and every image in the tree is
rebuilt by the gate on every run anyway. The only stale artefact is a
card that has already been flashed, and reflashing one is now 170 ms
over a wire (`notes/37`).

So: append them. A machine that raises `badarg` where BEAM raises
`badfun` is a machine whose supervisors match on the wrong reason.

## Maps, and structs for free

### v1 is a flatmap and nothing else

BEAM has two representations: a flatmap (small, sorted key and value
arrays) and a hashmap (a HAMT) above 32 keys. v1 builds flatmaps only,
and refuses to grow past 32 pairs with `system_limit`.

Keys are restricted to IMMEDIATES — fixnums, atoms, nil, pids, refs —
so key comparison is 36-bit word equality and needs no recursive term
comparison in gates. A compound key raises `badarg` at `mapput`. That is
a real restriction and it is the one that makes the whole feature fit;
it is also, in practice, every key any Elixir struct or keyword-shaped
map has.

### The object

Tag `map` = **0xE**, one of the two tags still free, and again the
tuple's shape:

```
cell 0:  [ hdr(1 + 2n) | mapinfo(n) ]
cell 1:  [ k0          | v0         ]
cell 2:  [ k1          | v1         ]  ...
```

Pairs are kept SORTED BY KEY WORD at construction. Not for BEAM
compatibility — BEAM sorts by term order, and an atom's term order is
its name where here it is its table index — but so that two maps with
the same keys have the same layout, which makes map equality a word
compare per pair instead of a search per pair. `maps:keys/1` order is
unspecified in BEAM, so the difference is not observable through the
API; where it WOULD be observable is `maps:to_list/1` feeding something
order-sensitive, and that is worth a scoreboard line rather than a
redesign.

### The ops

```
mkmap   rd, n              allocate a map of n pairs; fill with tset
mapget  rd, rm, rk         value for key, or raise badkey
mapfind rd, rm, rk, none   the pattern-match / is_map_key form: branch
mapput  rd, rm, rk, rv     FUNCTIONAL update — a fresh map
mapsize rd, rm
```

`mapget` and `mapfind` are a scan over at most 32 pairs on heap port A,
so they park the context the way a receive scan does — bounded, and
paid by the process asking. Sorted keys make a binary search possible
(5 probes rather than 32) and that is the obvious optimisation, not the
first version.

`mapput` allocates. Every map update is a fresh object, which is what
BEAM does for a flatmap and is why the collector had to come first.

### Structs need nothing

An Elixir struct is a map with a `__struct__` key whose value is the
module atom. `%User{name: n}` is `%{__struct__: User, name: n}`, and
`%User{u | name: n}` is a map update with a compile-time guarantee that
the key exists. Both are already the map ops above, and `__struct__` is
an atom key, which is an immediate.

So there is no struct feature. There is a map feature and a front end
that already lowers structs to maps before we see them — which is worth
saying out loud, because "maps, structs, and funs" reads like three
things and is two.

## The two-version rule

BEAM's contract, precisely:

* Two versions of a module can be loaded at once: **current** and
  **old**.
* A **fully-qualified** call — `Mod:Fun/Arity` — always enters the
  CURRENT version.
* A **local** call stays inside the version that is executing it.
* Loading a third version purges the old one, and any process still
  executing purged code is killed with `killed`.

Each clause maps onto a decision about where a call target comes from,
and picoBEAM already makes two of the three.

| BEAM | picoBEAM | target comes from |
|---|---|---|
| local call | `call rd, f, arity` | a literal in the bundle |
| fun call | `callfun rd, rf, arity` | a word baked into the heap object |
| fully-qualified call | `call_ext rd, x, arity` | `exports[x]`, read at call time |

`call_ext` is the only new thing, and the export table is the only new
memory: a small array, index to entry bundle, one entry per exported
function. Rewriting `exports[x]` redirects every FUTURE fully-qualified
call and disturbs nothing already running, because a process inside the
old code holds absolute pcs in its own frames and return addresses.

That is the two-version rule, in one indirection. It is not an
approximation of it.

### What loading looks like

`notes/39` generalised pbo/1 to "pushing images into mass storage
devices for the purposes of rapid iteration". Hot loading is the same
protocol pointed at code memory instead of the card:

1. a `LOAD` frame carrying bundles and an absolute base
2. an `EXPORTS` frame carrying `{index, entry}` pairs
3. the export writes are applied together, at a point where no
   `call_ext` is mid-flight — which is the same quiescence the collector
   already waits for (`notes/41`)

Purging is the part v1 will not have. Code memory is 512 bundles, so a
second version must fit beside the first, and nothing tracks which
processes are executing which range. Loading a third version will
overwrite the first, and a process still inside it will run whatever
lands there. **That is a real gap and it should be written down as one**
rather than described as a purge, because it fails the way BEAM's
`code:purge/1` explicitly does not: silently, and with wrong answers
instead of a dead process.

The honest v1 statement is: two versions, and the loader refuses a third
until the old one is unreferenced — which needs a per-slot "which
version is this process in" bit, and that bit is cheap. It is one
`ProcTable` column and a comparison at load time.

## Order

1. `badfun` / `badarity` appended to the reserved atoms — one line, and
   everything after it depends on the numbering being settled.
2. Funs: `mkfun`, `tset` relaxed, `callfun`; `Collector` gains `T_FUN`;
   `Erl.translate_core` lifts `c_fun` and computes free variables.
3. Maps: tag 0xE, `mkmap`/`mapget`/`mapfind`/`mapput`/`mapsize`;
   structs arrive with them for nothing.
4. `call_ext` and the export table, then the loader frames.

Funs first because `call_ext`'s indirection is the same machinery as
`callfun`'s — read a word, latch it as the call target — and building
it twice would be building it wrong once.

---

## Postscript: step 2 is done on the model

`badfun`, `badarity`, `badkey` and `badmap` are appended to the reserved
atoms. `mkfun` and `callfun` are in the ISA, the assembler, the encoder
and `Machine`, and `test/fun_test.exs` covers a closure that captures a
variable and is called twice, `is_function/1` against `is_tuple/1`,
`element/2` on a fun raising `bad_tag`, the wrong arity raising
`badarity`, calling a non-fun raising `badfun`, and — the one that
matters — **a closure surviving several collections with its captured
variable intact** on a 64-word heap.

That last test failed the first time it ran, and it failed for the
reason `notes/40` predicted in the RTL and did not check for on the
model: `Machine`'s collector tested `tag in [:cons, :tuple]` in three
separate places, so the first closure to survive a collection was left
pointing into from-space. The fix is a module attribute — `@boxed
[:cons, :tuple, :fun]` — and the RTL's `Collector` and `RootWalker` got
the same treatment through their tag params, including one place in
`Collector`'s state 1 that still spelled the test as `== 3` and `== 4`
in numbers.

So the bug `notes/40` armed and disarmed in the RTL was alive on the
model the whole time, and the feature that would have triggered it is
the one that just found it.

`PicoBEAM.Heap`'s tags are params now too — the "separate, mechanical
job" `notes/40` named. The emitted logic is bit-identical, verified line
by line; what changed is that there is one place where a tag number is
decided.

## Postscript: funs run on the netlist

`tb_fixed:funs` builds a closure, calls it, collects around it and calls
it again; `tb_fixed:funbad` and `tb_fixed:funar` are the two ways it
goes wrong; `tb_fixed:fnelixir` is the same feature written as Elixir
`fn` rather than as slots. Gate 57 ok, 0 failed.

### The convention changed, and the note it changed is this one

The section above says the caller appends the free variables to the
argument registers, because that is what BEAM's `call_fun` does. It does
not survive contact with this machine.

BEAM's x-registers are a flat array the emulator can extend for free.
The staging bank here is a per-context memory written from the X stage,
and the X stage belongs to a different seat every cycle — so "append n
words to the staging bank of a context that is parked" is a background
FSM with its own write path into `RegWindowCtx`, on the scale of the
deserialiser.

So the closure rides as the LAST ARGUMENT and the callee unpacks it:

```
mkfun   rd, f, nfree      allocate; f is a pool index by image time
tset    rd, 1 + j, rs     captured variable j
arg     arity, rf         the closure, as the last argument
callfun rd, rf, arity     check the tag and the arity, call the entry
fget    rd, rf, 1 + j     ...and inside, unpack variable j
```

`fget` is the mirror of `tset` and shares `tget`'s entire datapath —
same offset arithmetic, same bank select. What differs is the tag it
demands and therefore the reason it refuses, which is the whole point of
a fun having a tag of its own.

The cost is one argument slot and one `fget` per captured variable. It
is invisible from Elixir, which is where the semantics that matter live:
`fn` captures, `f.(x)` calls, `is_function/1` is true, `element/2`
raises, and a wrong arity says `badarity`.

### Where the two errors come from

They come from different places, and that turned out to be the
interesting part.

**`badfun`** is raised by the STORE, at X, for the seat at X, on the
ordinary fault path — because `callfun` reads the closure through
`fget`, and `fget` type-checks. It cost one term in `fault_reason`.

**`badarity`** cannot be known until the funinfo comes back, one cycle
after X, by which time the seat has moved on. It is the first death in
this machine raised for a seat that is NOT at X, and it needed three
things: a `bad_en`/`bad_seat` pair into `BarrelSeq` that forces a seat
to state 7 whatever state it is in, a pending bit so an X-stage fault in
the same cycle keeps the death port, and a reason that is still alive
one cycle later — because `sfl` is a register, so `died` fires the cycle
AFTER the error is noticed and reads `any_fault_r` then.

That last one is `notes/26`'s failure class two, met for the fourth
time: a value produced at one moment and consumed at another. It cost a
one-bit register and it was a wrong answer (`normal`) rather than a
crash until the testbench asked for the reason by name.

The same machinery is what `notes/26` entry 16 needs — a rebuild that
still does not fit after a collection has to kill the RECEIVER, which is
also not at X.

### The pipeline, end to end

`callfun` at X issues the funinfo read and parks exactly like a call.
One cycle later the seat's target latch takes the entry out of
`rd_late`; the F slot that commits the call is at least three cycles
after that, so nothing waits. The only thing `callfun` needed beyond
`call` was to be included where `call` records its DESTINATION register
— missing that is the difference between a closure that returns its
answer and one that returns it into r0, and it is what the first run
did.

### Two things erlc does that a test has to defeat

`n = 100; fn x -> x + n end` compiles to a closure over NOTHING: the
optimiser folds the literal into the body. A demo written that way tests
`mkfun` with `nfree = 0` and proves nothing about capture. The captured
value has to come from somewhere erlc cannot see — a function call is
enough.

The same goes for the heap churn a collection needs: `_ = {n, n}` in a
loop is folded away entirely, because nothing reads the tuple. Taking an
element of it keeps it.

### And one bug that was exactly the shape this project keeps finding

`Term.funinfo/3` packs `{entry, arity, nfree}`. The MODEL computed the
arity as `total - 1` under the new convention; `Encoding` still computed
it as `total - nfree`, from the old one. For a closure over one variable
the two agree. For a closure over NOTHING — which is what erlc's folding
produces — they differ by one, and every such call died of `badarity`
on the gates while passing on the model.

A value decided in one place and copied into another, for the fifth
time. The fix is that `funinfo_word/4` is the only caller on the image
side and `funinfo_for!/3` the only one on the model side, and both now
say `total - 1` next to a comment explaining why.

### What it cost in the store

`mkfun` is heap command 7 — allocate `cell_round(2 + nfree)`, header in
bank 0, funinfo in bank 1, result tagged `fun`. `fget` is command 8,
which is why `cmd` there is four bits now: group 2 has sixteen code
points and only eight ever reached the store.

The funinfo comes from the literal pool, and there was one wrinkle worth
recording. `LitPool`'s address is driven from the X stage, because `ldc`
writes on the wb2 turn and its answer is allowed to be a cycle late. A
heap command needs its `pa` AT X. So `mkfun`'s pool read is addressed a
stage earlier, off the D-stage bundle, through a second read port — one
more EBR per engine. Re-timing `ldc` to match would have been changing a
working path for a convenience.

### Still to do

* Elixir's `&fun/1` capture, and a fun escaping as `{:c_var, _, {f, a}}`
  rather than as a `c_fun`. Both are closures over nothing and reuse
  everything here; neither is wired up.
* `apply/2` and `apply/3` with a runtime argument list.
* Maps, and then `call_ext` and the two-version rule.
