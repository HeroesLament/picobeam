defmodule PicoBEAM.Machine do
  @moduledoc """
  The M1 reference model: the fabric as a pure, deterministic Elixir
  interpreter. Notes/00 priority: get the ISA wrong HERE, where it is cheap.
  RTL is later co-simulated against this, bundle by bundle — "the instrument
  is the device under test" countermeasure, same as ECOMP 1999.

  ## What is modeled faithfully

  * N engines advancing in lockstep, one bundle per engine-cycle, fixed
    barrel rotation over T context seats (Q9: an empty/blocked seat is an
    idle cycle, never redistributed — the 1/T guarantee is structural).
  * Clean-on-call register windows: `call` bumps a window, args arrive via
    `arg` write-through staging, `ret` pops and delivers to the recorded
    destination register. Nothing is saved or restored. Reading a register
    the current window never wrote is a FAULT (`:uninit`) — single
    assignment enforced at runtime, which is exactly the property the
    hardware exploits.
  * The bundle contract: slots read pre-bundle state, writes commit
    together (the assembler rejects intra-bundle hazards; the model applies
    writes after evaluating all slots, so a violation that slipped through
    would still behave as the hardware would).
  * Per-engine private heaps (bump allocation, 1 cycle), messages COPIED
    via a unidirectional ring with latency = @wire_base + hops + flits.
  * PID full-comparison at delivery: slot AND serial must match or the
    message dead-letters (the incarnation contract).
  * Fixnum overflow, bad tags, heap exhaustion, register-stack overflow —
    all TRAP into exit reasons carried on reserved atoms.
  * Links, monitors, exit signals, trap_exit — signals ride the same ring
    with the same bounded latency.

  ## Also modeled (second M1 increment)

  * Per-engine Cheney collection between two semispaces (heap_words EACH),
    triggered on allocation failure; live-exceeds-semispace is `:heap_full`
    (Q7). The mutator is charged ZERO cycles — the port-B claim, stated as
    an assumption the RTL must earn at M5. `stats.gc` records live words
    per collection for Bacon-style sizing checks. In-flight bundle state
    (window, writes, staging) is part of the root set — the
    mutator/collector interface contract, in model form.
  * Selective receive: an 8-bit shape hash (tag, arity, first-atom) is
    computed at enqueue; `recv_start`/`recv_hash`/`recv_peek`/`recv_skip`/
    `recv_take`/`recv_wait[t]` walk candidates the way BEAM's receive loop
    does, with the scan itself free (the port-B matcher). `stats.scans`
    records scan distances for the receive-latency bound.
  * Bounded mailboxes (`mailbox_depth`): overflow exits the RECEIVER with
    `:mailbox_full` — the Q7-shaped answer; backpressure on the sender
    would leak one process's slowness into another's WCET.
  * Receive timeouts via the timer wheel (`recv_waitt`).

  ## Also modeled (third M1 increment — the M3 on-ramp)

  * Run queues and reduction-budget descheduling. Each engine holds up to
    T seated processes plus a FIFO run queue. A seated process is
    descheduled only when its budget exhausts WITH waiters present (empty
    queue: the budget resets and the seat is kept — Q9's promise applies
    to residents); `yield` forces the same path. Blocked residents are
    evicted at rotation when runnable work waits. Seats fill lazily as the
    rotation visits them, paying a fixed swap-in cost (notes/05: ~32 cy;
    `stats.swap_stall` counts the cycles it costs, `stats.swaps` the
    switches). Spawn beyond N×T queues instead of failing; the 64-slot
    proc table (the PID's 6-bit slot field) is the architectural limit and
    exhausting it is `:system_limit` on the spawner.

  ## Also modeled (fourth M1 increment)

  * Link/monitor registration rides the ring: the local half registers at
    issue, the remote half is a wire, and a request arriving for a
    dead/stale pid answers back on the ring with :noproc (an exit signal
    for link, a DOWN for monitor) — Erlang's semantics with a bounded
    latency attached. The model shortcut is retired.

  ## Deliberately simplified at this stage of M1 (each is a listed TODO)

  * The GC trigger is allocation failure; a real concurrent collector
    starts earlier and paces itself — pacing is an M5 modeling concern.
  * Swap cost is a constant; with register WINDOWS the resident frame
    count varies, so the RTL either bounds resident frames per context or
    the notes/05 ±0-jitter swap claim needs restating (flagged for M2).
  """

  alias PicoBEAM.{Encoding, Term}

  import Bitwise

  @wire_base 2
  # 15, not 64: `FrameRamProc` stores {slot:5, depth:4, idx:4} and
  # refuses a push at depth 15, so 15 frames is what the MACHINE has.
  # The model held 64 and faulted nowhere near the same place, which
  # made it the wrong oracle for exactly the programs that need one —
  # deep recursion. Widening this is a memory-count change in the RTL
  # first (`notes/31`), and this number follows it, not the reverse.
  @max_rstack 15
  @default_budget 256
  # Context swap-in: fixed context size over a fixed port width (notes/05:
  # ~32 cy, jitter ±0). NOTE for M2: with register WINDOWS the resident
  # frame count varies, so real swap cost is frames x window/port — either
  # bound the resident frames per context or the ±0 claim needs restating.
  @default_swap_cost 32

  defstruct code: %{},
            # ring node 15 (`RingHost`): what the program sent to the host,
            # oldest first, as {dest pid, payload}. Nothing answers here; a
            # host emulator reads this and injects replies.
            host_out: [],
            engines: {},
            n_engines: 1,
            t_contexts: 4,
            heap_words: 8192,
            mailbox_depth: 64,
            atoms: %{},
            # `notes/53` — the registered-name table, atom payload ->
            # pid word, on the MACHINE: an engine is a scheduler, the
            # machine is the node, and BEAM's registry is node-global.
            # (It lived per-engine for one note's time — `notes/50`
            # built it under `notes/12`'s engine-is-a-node doctrine,
            # and `notes/53` retired the doctrine.)
            names: %{},
            atoms_rev: %{},
            next_atom: 0,
            cycle: 0,
            wires: [],
            wire_seq: 0,
            timers: [],
            out: [],
            # The same `out` values as raw 36-bit words. `out` holds decoded
            # Elixir terms, which is what a person wants to read — but a
            # testbench compares WORDS, and a decoded term cannot express the
            # pointer a compound result actually is. Every `mk_*.exs` used to
            # re-encode `out` by hand with its own is_integer/is_atom lambda,
            # which worked only because no test could report a pointer. Now
            # one can.
            out_raw: [],
            halted: false,
            budget: @default_budget,
            swap_cost: @default_swap_cost,
            stats: %{
              bundles: 0,
              idle: 0,
              sends: 0,
              deaths: [],
              wire_latencies: [],
              gc: [],
              scans: [],
              swaps: 0,
              swap_stall: 0
            }

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  def new(program, opts \\ []) do
    n = Keyword.get(opts, :engines, 1)
    t = Keyword.get(opts, :contexts, 4)

    m = %__MODULE__{
      code: program,
      n_engines: n,
      t_contexts: t,
      heap_words: Keyword.get(opts, :heap_words, 8192),
      mailbox_depth: Keyword.get(opts, :mailbox_depth, 64),
      budget: Keyword.get(opts, :budget, @default_budget),
      swap_cost: Keyword.get(opts, :swap_cost, @default_swap_cost),
      engines: List.to_tuple(Enum.map(0..(n - 1), &new_engine(&1, t)))
    }

    # Reserved atoms first, at their ABI indices, then the program's own
    # in `Encoding.program_atoms/1` order. Interning them HERE rather
    # than lazily on first use is what makes `lda 19` mean the same atom
    # in the model as in the image: both sides number from one function,
    # so they cannot drift. Lazily-interned atoms still work and land
    # after the table.
    m = Enum.reduce(Term.reserved_atoms(), m, fn a, acc -> elem(intern(acc, a), 0) end)

    Enum.reduce(PicoBEAM.Encoding.program_atoms(program), m, fn a, acc ->
      elem(intern(acc, a), 0)
    end)
  end

  defp new_engine(id, t) do
    %{
      id: id,
      heap: %{},
      hp: 0,
      # Two semispaces per engine (notes/03, notes/04): heap_words EACH.
      # `space` names the semispace being ALLOCATED into. Outside a
      # collection that is also the only one with live data in it; during
      # one it is to-space, and `gc.from` names the other (`notes/46`).
      space: 0,
      # nil, or %{from: bit, pending: MapSet of slots not yet collected}.
      # A collection is no longer an event that happens between two
      # bundles — it is a state the engine is in while it runs.
      gc: nil,
      procs: %{},
      seats: List.to_tuple(List.duplicate(nil, t)),
      seat_ready: List.to_tuple(List.duplicate(0, t)),
      run_queue: [],
      # The incarnation counter is PER SLOT, not per engine. `notes/13`
      # sized 22 bits as an ABA guard for a recycled slot, and `notes/49`
      # found the model counting engine-wide instead — so the same
      # program gave the second process serial 2 in the model and serial
      # 1 in the gates. Nothing caught it for thirty-odd testbenches
      # because no test had ever PRINTED a second pid; `tb_spawn2` does,
      # because a cross-engine spawn's whole answer is a pid.
      #
      # The gates are what silicon does and `ProcTable` says so in its
      # own comment ("first life of a slot is serial 1"), so the model
      # moves. A slot absent from this map has never been used and its
      # next life is serial 1.
      serials: %{},
      next_ref: 1,
      # whose turn it is to receive the next spawn from here (`notes/47`)
      spawn_rr: 0
    }
  end

  @doc "Spawn the root process (fun/0..N with literal term args) on engine 0."
  def boot(m, fun, args \\ []) do
    {m, _pid} = spawn_proc(m, 0, fun, args)
    m
  end

  # ---------------------------------------------------------------------------
  # Atoms
  # ---------------------------------------------------------------------------

  def intern(m, a) when is_atom(a) do
    case Map.fetch(m.atoms, a) do
      {:ok, idx} ->
        {m, idx}

      :error ->
        idx = m.next_atom

        {%{m | atoms: Map.put(m.atoms, a, idx),
             atoms_rev: Map.put(m.atoms_rev, idx, a),
             next_atom: idx + 1}, idx}
    end
  end

  def atom_word(m, a) do
    {m, idx} = intern(m, a)
    {m, Term.atom(idx)}
  end

  def atom_name(m, word), do: Map.fetch!(m.atoms_rev, Term.payload(word))

  # ---------------------------------------------------------------------------
  # Run loop
  # ---------------------------------------------------------------------------

  def run(m, max_cycles \\ 1_000_000) do
    cond do
      m.halted -> {:halted, m}
      m.cycle >= max_cycles -> {:max_cycles, m}
      quiescent?(m) -> {:quiescent, m}
      true -> m |> step() |> run(max_cycles)
    end
  end

  def quiescent?(m) do
    m.wires == [] and m.timers == [] and
      Enum.all?(Tuple.to_list(m.engines), fn e ->
        Enum.all?(e.procs, fn {_, p} -> p.state != :run end)
      end)
  end

  @doc "Advance one machine cycle: deliver due wires, fire due timers, then every engine issues one bundle."
  def step(m) do
    m = deliver_due(m)
    m = fire_timers(m)

    m =
      Enum.reduce(0..(m.n_engines - 1), m, fn eid, acc ->
        if acc.halted, do: acc, else: step_engine(acc, eid)
      end)

    %{m | cycle: m.cycle + 1}
  end

  # The scheduler, such as it is (notes: the ROTATION makes no decisions;
  # scheduling = seat management). A seated process owns its rotation slots
  # until it dies, blocks with waiters present, or exhausts its reduction
  # budget with waiters present. The run queue holds :run processes beyond
  # the T seats; seats fill lazily as the rotation visits them, paying the
  # fixed swap-in cost. The hard 1/T guarantee is therefore PER SEAT — an
  # oversubscribed engine trades it, which is Q2's "T is a solver input"
  # point seen from the other side.
  defp step_engine(m, eid) do
    m = gc_tick(m, eid)
    e = elem(m.engines, eid)
    seat = rem(m.cycle, m.t_contexts)

    case elem(e.seats, seat) do
      nil ->
        case e.run_queue do
          [] -> bump_stat(m, :idle)
          [h | t] -> m |> seat_in(eid, seat, h, t) |> bump_stat(:idle)
        end

      slot ->
        cond do
          elem(e.seat_ready, seat) > m.cycle ->
            bump_stat(m, :swap_stall)

          true ->
            case Map.get(e.procs, slot) do
              %{state: :run} = p ->
                execute_bundle(bump_stat(m, :bundles), eid, p)

              %{state: _blocked} when e.run_queue != [] ->
                # evict a blocked resident in favor of runnable work; the
                # blocked process keeps its proc-table slot and re-queues
                # on wake
                [h | t] = e.run_queue
                m |> seat_in(eid, seat, h, t) |> bump_stat(:idle)

              _ ->
                bump_stat(m, :idle)
            end
        end
    end
  end

  # The background half of `notes/46`'s schedule: one pending process per
  # cycle, in slot order, whether or not anybody is asking. Without it a
  # collection started by a busy process would never finish while a
  # blocked one sat in `pending` — and from-space would never be freed.
  #
  # A process that has NOT been collected yet is safe to run: from-space
  # is still there and its pointers still address it. Only ALLOCATION is
  # gated, which is `gc_gate/4`.
  defp gc_tick(m, eid) do
    e = elem(m.engines, eid)

    if gc_active?(e) do
      case Enum.min(MapSet.to_list(e.gc.pending), fn -> nil end) do
        nil -> m
        slot -> elem(collect_slot(m, eid, slot, []), 0)
      end
    else
      m
    end
  end

  defp seat_in(m, eid, seat, slot, rest_queue) do
    e = elem(m.engines, eid)

    e = %{e
      | seats: put_elem(e.seats, seat, slot),
        seat_ready: put_elem(e.seat_ready, seat, m.cycle + m.swap_cost),
        run_queue: rest_queue}

    %{m | engines: put_elem(m.engines, eid, e), stats: Map.update!(m.stats, :swaps, &(&1 + 1))}
  end

  defp bump_stat(m, key), do: %{m | stats: Map.update!(m.stats, key, &(&1 + 1))}

  # ---------------------------------------------------------------------------
  # Bundle execution
  # ---------------------------------------------------------------------------

  defp execute_bundle(m, eid, p) do
    {fun, idx} = p.pc
    code = m.code |> Map.fetch!(fun) |> Map.fetch!(:code)

    if idx >= tuple_size(code) do
      # fell off the end of a function — a missing terminator (ret/jmp/
      # tailcall). Loud, not silent: this is always a compiler/asm bug.
      die(m, eid, p, :badarg)
    else
      execute_bundle(m, eid, p, fun, idx, elem(code, idx))
    end
  end

  defp execute_bundle(m, eid, p, fun, idx, bundle) do
    slots = Tuple.to_list(bundle) |> Enum.reject(&(&1 == {:nop}))

    ctx = %{
      window: hd(p.windows),
      writes: %{},
      staged: p.out_args,
      next_pc: {fun, idx + 1},
      control: nil
    }

    try do
      {m, p, ctx} =
        Enum.reduce(slots, {m, p, ctx}, fn slot, {m, p, ctx} ->
          exec_slot(slot, m, eid, p, ctx)
        end)

      m |> commit(eid, p, ctx) |> post_budget(eid, p.pid)
    catch
      {:fault, m2, reason} -> die(m2, eid, p, reason)
    end
  end

  # Reduction accounting, applied to the process's FINAL post-control state.
  # Exhaustion with waiters present deschedules to the run-queue tail; with
  # an empty queue the budget simply resets (the seat is promised — Q9).
  # `yield` works by setting budget_left to 1 so this path fires naturally.
  defp post_budget(m, eid, pid) do
    case fetch_remote(m, pid) do
      %{state: :run} = p ->
        case p.budget_left - 1 do
          0 ->
            m = put_proc(m, eid, %{p | budget_left: m.budget})
            maybe_deschedule(m, eid, pid)

          n ->
            put_proc(m, eid, %{p | budget_left: n})
        end

      _ ->
        m
    end
  end

  defp maybe_deschedule(m, eid, pid) do
    e = elem(m.engines, eid)
    slot = Term.pid_slot(pid)

    case e.run_queue do
      [] ->
        m

      [h | t] ->
        seat = Enum.find(0..(m.t_contexts - 1), fn i -> elem(e.seats, i) == slot end)

        e = %{e
          | seats: put_elem(e.seats, seat, h),
            seat_ready: put_elem(e.seat_ready, seat, m.cycle + m.swap_cost),
            run_queue: t ++ [slot]}

        %{m | engines: put_elem(m.engines, eid, e),
            stats: Map.update!(m.stats, :swaps, &(&1 + 1))}
    end
  end

  # Commit register writes, staging, pc, budget — then apply any control action.
  # ctx.window (not hd(p.windows)) is the base: a mid-bundle collection may
  # have rewritten it.
  defp commit(m, eid, p, ctx) do
    window = Map.merge(ctx.window, ctx.writes)
    p = %{p | windows: [window | tl(p.windows)], out_args: ctx.staged}

    case ctx.control do
      nil -> put_proc(m, eid, %{p | pc: ctx.next_pc})
      {:goto, pc} -> put_proc(m, eid, %{p | pc: pc})
      {:spawn, rd, f, arity} -> do_spawn(m, eid, p, ctx, rd, f, arity)
      {:call, f, arity, dest} -> do_call(m, eid, p, ctx, f, arity, dest)
      {:tailcall, f, arity} -> do_tailcall(m, eid, p, ctx, f, arity)
      {:ret, value} -> do_ret(m, eid, p, value)
      {:recv, rd} -> do_recv(m, eid, p, ctx, rd)
      {:peek, rd, none_idx} -> do_peek(m, eid, p, ctx, rd, none_idx)
      {:take, rd} -> do_take(m, eid, p, ctx, rd)
      {:wait, topt} -> do_wait(m, eid, p, ctx, topt)
      {:die, reason} -> die(m, eid, p, reason)
      :halt -> do_halt(m, eid, p, ctx)
    end
  end

  # The port-B matcher: scan from the cursor for the next candidate whose
  # shape hash passes the filter. The scan itself is concurrent hardware
  # (mailbox port B), so it costs the mutator nothing — the model records
  # scan distance in stats for the receive-latency bound instead.
  defp do_peek(m, eid, p, ctx, rd, none_idx) do
    n = length(p.mailbox)

    found =
      Enum.find(p.cursor..(n - 1)//1, fn i ->
        {_w, h} = Enum.at(p.mailbox, i)
        p.filter == nil or p.filter == h
      end)

    case found do
      nil ->
        {fun, _} = p.pc
        put_proc(m, eid, %{p | cursor: n, pc: {fun, none_idx}})

      idx ->
        {word, _h} = Enum.at(p.mailbox, idx)
        m = %{m | stats: Map.update!(m.stats, :scans, &[idx - p.cursor | &1])}
        window = Map.put(hd(p.windows), rd, word)
        p = %{p | cursor: idx, windows: [window | tl(p.windows)], pc: ctx.next_pc}
        put_proc(m, eid, p)
    end
  end

  defp do_take(m, eid, p, ctx, rd) do
    if p.cursor >= length(p.mailbox), do: throw({:fault, m, :badarg})
    {word, _h} = Enum.at(p.mailbox, p.cursor)
    mailbox = List.delete_at(p.mailbox, p.cursor)
    window = Map.put(hd(p.windows), rd, word)

    p = %{p | mailbox: mailbox, cursor: 0, filter: nil,
          windows: [window | tl(p.windows)], pc: ctx.next_pc}

    put_proc(m, eid, p)
  catch
    {:fault, m2, reason} -> die(m2, eid, p, reason)
  end

  defp do_wait(m, eid, p, ctx, topt) do
    if length(p.mailbox) > p.cursor do
      # unseen messages exist — fall through and let peek examine them
      put_proc(m, eid, %{p | pc: ctx.next_pc})
    else
      {fun, _} = p.pc

      {m, timeout} =
        case topt do
          nil ->
            {m, nil}

          {t, timeout_idx} ->
            deadline = m.cycle + t
            timer = %{due: deadline, pid: p.pid}
            {%{m | timers: [timer | m.timers]}, {deadline, {fun, timeout_idx}}}
        end

      p = %{p | state: {:wait_msg, length(p.mailbox), ctx.next_pc, timeout}}
      put_proc(m, eid, p)
    end
  end

  defp fire_timers(m) do
    {due, later} = Enum.split_with(m.timers, &(&1.due <= m.cycle))
    m = %{m | timers: later}

    Enum.reduce(due, m, fn %{due: due_cycle, pid: pid}, m ->
      case fetch_remote(m, pid) do
        %{state: {:wait_msg, _seen, _resume, {deadline, timeout_pc}}} = p
        when deadline == due_cycle ->
          eid = Term.pid_engine(pid)
          wake(m, eid, %{p | state: :run, pc: timeout_pc})

        _ ->
          # stale timer: the process woke on a message, died, or re-armed
          m
      end
    end)
  end

  defp put_engine(m, eid, e), do: %{m | engines: put_elem(m.engines, eid, e)}


  defp put_proc(m, eid, p) do
    e = elem(m.engines, eid)
    e = %{e | procs: Map.put(e.procs, Term.pid_slot(p.pid), p)}
    %{m | engines: put_elem(m.engines, eid, e)}
  end

  # ---------------------------------------------------------------------------
  # Slot semantics. Reads come from the PRE-bundle window (read-old).
  # ---------------------------------------------------------------------------

  defp rd!(m, window, r) do
    case Map.fetch(window, r) do
      {:ok, w} -> w
      :error -> throw({:fault, m, :uninit})
    end
  end

  defp int!(m, w) do
    if Term.is?(w, :int), do: Term.int_value(w), else: throw({:fault, m, :badarith})
  end

  defp exec_slot(slot, m, eid, p, ctx) do
    w = fn r -> rd!(m, ctx.window, r) end
    put = fn ctx, r, val -> %{ctx | writes: Map.put(ctx.writes, r, val)} end

    case slot do
      {:ldi, rd, imm} ->
        {m, p, put.(ctx, rd, Term.int(imm))}

      {:ldn, rd} ->
        {m, p, put.(ctx, rd, Term.nil_term())}

      {:ldc, rd, {:raw, w}} ->
        {m, p, put.(ctx, rd, w)}

      {:ldc, rd, v} when is_integer(v) ->
        case Term.int_checked(v) do
          {:ok, word} -> {m, p, put.(ctx, rd, word)}
          {:error, _} -> throw({:fault, m, :overflow})
        end

      # An index means "whatever the atom table says", which is the ABI
      # atoms followed by the program's own. It used to mean only a
      # RESERVED atom, because the encoder could not number anything
      # else — so a program could not name its own atoms at all, and
      # `{From, inc}` was unencodable. Every OTP protocol is application
      # atoms; the machine could hold eighteen.
      {:lda, rd, i} when is_integer(i) ->
        {m, p, put.(ctx, rd, Term.atom(i))}

      {:lda, rd, a} ->
        {m, word} = atom_word(m, a)
        {m, p, put.(ctx, rd, word)}

      {:mov, rd, rs} ->
        {m, p, put.(ctx, rd, w.(rs))}

      {:self, rd} ->
        {m, p, put.(ctx, rd, p.pid)}

      {op, rd, ra, rb} when op in [:add, :sub, :mul, :band, :bor, :bxor] ->
        a = int!(m, w.(ra))
        b = int!(m, w.(rb))

        v =
          case op do
            :add -> a + b
            :sub -> a - b
            :mul -> a * b
            :band -> band(a, b)
            :bor -> bor(a, b)
            :bxor -> bxor(a, b)
          end

        case Term.int_checked(v) do
          {:ok, word} -> {m, p, put.(ctx, rd, word)}
          {:error, _} -> throw({:fault, m, :overflow})
        end

      # mulsr: the 64-bit intermediate is not a term and is not checked;
      # only the shifted result has to be a fixnum. `>>>` is arithmetic
      # (floor), matching the netlist's $signed(...) >>> k exactly.
      {:mulsr, rd, ra, rb, k} when k in 1..16 ->
        a = int!(m, w.(ra))
        b = int!(m, w.(rb))

        case Term.int_checked(a * b >>> k) do
          {:ok, word} -> {m, p, put.(ctx, rd, word)}
          {:error, _} -> throw({:fault, m, :overflow})
        end

      {:cmpeq, rd, ra, rb} ->
        {m, word} = atom_word(m, w.(ra) == w.(rb))
        {m, p, put.(ctx, rd, word)}

      {:cmpne, rd, ra, rb} ->
        {m, word} = atom_word(m, w.(ra) != w.(rb))
        {m, p, put.(ctx, rd, word)}

      {:cmplt, rd, ra, rb} ->
        {m, word} = atom_word(m, int!(m, w.(ra)) < int!(m, w.(rb)))
        {m, p, put.(ctx, rd, word)}

      {:cmple, rd, ra, rb} ->
        {m, word} = atom_word(m, int!(m, w.(ra)) <= int!(m, w.(rb)))
        {m, p, put.(ctx, rd, word)}

      {:istag, rd, rs, tag} ->
        {m, word} = atom_word(m, Term.is?(w.(rs), tag))
        {m, p, put.(ctx, rd, word)}

      # -- heap ----------------------------------------------------------------
      {:cons, rd, rh, rt} ->
        {m, p, ctx, addr} = alloc_exec(m, eid, p, ctx, [w.(rh), w.(rt)])
        {m, p, put.(ctx, rd, Term.cons(addr))}

      {:hd, rd, rs} ->
        {m, p, put.(ctx, rd, heap_at(m, eid, cons_addr!(m, w.(rs)) + 0))}

      {:tl, rd, rs} ->
        {m, p, put.(ctx, rd, heap_at(m, eid, cons_addr!(m, w.(rs)) + 1))}

      {:mktup, rd, arity} ->
        {m, p, ctx, addr} = alloc_exec(m, eid, p, ctx, [Term.hdr(arity) | List.duplicate(:hole, arity)])
        {m, p, put.(ctx, rd, Term.tuple(addr))}

      {:tset, rt, i, rs} ->
        addr = fillable_addr!(m, w.(rt))
        check_tuple_index!(m, eid, addr, i)
        {heap_put(m, eid, addr + 1 + i, w.(rs)), p, ctx}

      {:tget, rd, rt, i} ->
        addr = tuple_addr!(m, w.(rt))
        check_tuple_index!(m, eid, addr, i)

        case heap_at(m, eid, addr + 1 + i) do
          :hole -> throw({:fault, m, :badarg})
          word -> {m, p, put.(ctx, rd, word)}
        end

      {:tarity, rd, rt} ->
        addr = tuple_addr!(m, w.(rt))
        {m, p, put.(ctx, rd, Term.int(Term.payload(heap_at(m, eid, addr))))}

      # -- maps (`notes/42`) ---------------------------------------------------
      # A flatmap: header, pair count, then n key/value pairs one per
      # CELL. `mkmap` allocates it and `tset` fills it, exactly as
      # `mktup` and `tset` build a tuple — a map is a tuple-shaped object
      # with a tag of its own, so `element/2` on one raises.
      {:mkmap, rd, rn} ->
        n = int!(m, w.(rn))
        # 32 pairs is BEAM's flatmap ceiling, and `2 + 2n` words has to
        # fit an eight-bit header arity — the two limits agree at 32
        if n < 0 or n > 32, do: throw({:fault, m, :badmap})

        {m, p, ctx, addr} =
          alloc_exec(m, eid, p, ctx, [Term.hdr(1 + 2 * n), Term.int(n)] ++
            List.duplicate(:hole, 2 * n))

        {m, p, put.(ctx, rd, Term.map(addr))}

      # `mset rm, rv` writes at the index `mseti` latched. Per PROCESS,
      # not per seat: a process can be swapped out between the two.
      {:mseti, ri} ->
        {m, %{p | map_idx: int!(m, w.(ri))}, ctx}

      {:mset, rm, rv} ->
        addr = settable_addr!(m, w.(rm))
        check_tuple_index!(m, eid, addr, p.map_idx)
        {heap_put(m, eid, addr + 1 + p.map_idx, w.(rv)), p, ctx}

      # `mapat rd, rm, ri` — the indexed read, with the index in a
      # REGISTER because the probe loop that walks a map computes it.
      {:mapat, rd, rm, ri} ->
        addr = map_addr!(m, w.(rm))
        i = int!(m, w.(ri))
        check_tuple_index!(m, eid, addr, i)

        case heap_at(m, eid, addr + 1 + i) do
          :hole -> throw({:fault, m, :badarg})
          word -> {m, p, put.(ctx, rd, word)}
        end

      # -- binaries (`notes/43`). A binary is a tuple-shaped object like
      # every other: header, byte count, then the bytes. v1 stores one
      # byte per word, and `binat` is BYTE indexed, so packing four to a
      # word later is a change to the store and to nothing else.
      {:mkbin, rd, rn} ->
        n = int!(m, w.(rn))
        if n < 0 or n > 255, do: throw({:fault, m, :system_limit})

        {m, p, ctx, addr} =
          alloc_exec(m, eid, p, ctx, [Term.hdr(1 + n), Term.int(n)] ++
            List.duplicate(:hole, n))

        {m, p, put.(ctx, rd, Term.bin(addr))}

      {:binat, rd, rb, ri} ->
        addr = bin_addr!(m, w.(rb))
        i = int!(m, w.(ri))
        check_tuple_index!(m, eid, addr, i)

        case heap_at(m, eid, addr + 1 + i) do
          :hole -> throw({:fault, m, :badarg})
          word -> {m, p, put.(ctx, rd, word)}
        end

      # `fget rd, rf, i` — inside a closure. Index 0 is `funinfo`; index
      # 1 + j is captured variable j, the mirror of the `tset rf, 1 + j`
      # that filled it. Tag-checked as a fun, so it is not a back door
      # into a tuple and `tget` is not a back door into a closure.
      {:fget, rd, rf, i} ->
        addr = fun_addr!(m, w.(rf))
        check_tuple_index!(m, eid, addr, i)

        case heap_at(m, eid, addr + 1 + i) do
          :hole -> throw({:fault, m, :badarg})
          word -> {m, p, put.(ctx, rd, word)}
        end

      # -- funs (`notes/42`) ---------------------------------------------------
      # A closure is a tuple-shaped object: header, `funinfo`, then the
      # captured variables, which `tset rd, 1 + j, rs` fills. The tag on
      # the POINTER is what makes it a fun.
      {:mkfun, rd, f, nfree} ->
        info = funinfo_for!(m, f, nfree)

        {m, p, ctx, addr} =
          alloc_exec(m, eid, p, ctx, [Term.hdr(1 + nfree), info | List.duplicate(:hole, nfree)])

        {m, p, put.(ctx, rd, Term.fun(addr))}

      # -- staging / control ---------------------------------------------------
      {:arg, i, rs} ->
        {m, p, %{ctx | staged: Map.put(ctx.staged, i, w.(rs))}}

      {:call, rd, f, arity} ->
        {m, p, %{ctx | control: {:call, f, arity, rd}}}

      # `callfun` resolves the target out of the object and then IS a
      # call: the free variables become the last arguments, so the callee
      # is an ordinary function and the control record below is the
      # ordinary one.
      {:callfun, rd, rf, arity} ->
        {m, ctx, f, total} = resolve_fun!(m, eid, ctx, w.(rf), arity)
        {m, p, %{ctx | control: {:call, f, total, rd}}}

      {:tailcall, f, arity} ->
        {m, p, %{ctx | control: {:tailcall, f, arity}}}

      {:ret, rs} ->
        {m, p, %{ctx | control: {:ret, w.(rs)}}}

      {:jmp, idx} ->
        {fun, _} = p.pc
        {m, p, %{ctx | control: {:goto, {fun, idx}}}}

      {op, ra, rb, idx} when op in [:beq, :bne, :blt, :bge] ->
        taken? =
          case op do
            :beq -> w.(ra) == w.(rb)
            :bne -> w.(ra) != w.(rb)
            :blt -> int!(m, w.(ra)) < int!(m, w.(rb))
            :bge -> int!(m, w.(ra)) >= int!(m, w.(rb))
          end

        {fun, _} = p.pc
        {m, p, if(taken?, do: %{ctx | control: {:goto, {fun, idx}}}, else: ctx)}

      {op, rs, idx} when op in [:bift, :biff] ->
        {m, tw} = atom_word(m, op == :bift)
        {fun, _} = p.pc
        {m, p, if(w.(rs) == tw, do: %{ctx | control: {:goto, {fun, idx}}}, else: ctx)}

      # -- concurrency ---------------------------------------------------------
      # spawn defers to commit: the target may be OUR engine, and importing
      # the args can trigger a collection — committing our state first makes
      # it part of the root set instead of a stale copy.
      {:spawn, rd, f, arity} ->
        {m, p, %{ctx | control: {:spawn, rd, f, arity}}}

      {:send, rp, rm} ->
        dest0 = w.(rp)

        # `Name ! Msg` — BEAM resolves an atom destination through the
        # LOCAL registry, and an unregistered name is badarg on the
        # sender. A pid is itself; anything else is the tag fault a
        # non-destination always was.
        dest =
          cond do
            Term.is?(dest0, :pid) ->
              dest0

            Term.is?(dest0, :atom) ->
              case Map.fetch(m.names, Term.payload(dest0)) do
                {:ok, pid} -> pid
                :error -> throw({:fault, m, :badarg})
              end

            true ->
              throw({:fault, m, :bad_tag})
          end

        m = wire(bump_stat(m, :sends), eid, dest, {:message, export_term(m, eid, w.(rm))})
        {m, p, ctx}

      # -- registered names (`notes/50`) --------------------------------------
      {:reg_name, rn, rp} ->
        name = w.(rn)
        pid = w.(rp)
        {m, undef} = atom_word(m, :undefined)

        # `notes/53`: the registry is NODE-global — a pid on any engine
        # registers, because an engine is a scheduler, not a node. The
        # aliveness check already worked cross-engine; the engine
        # equality test was the misconception, and it is gone.
        ok =
          Term.is?(name, :atom) and name != undef and
            Term.is?(pid, :pid) and
            fetch_remote(m, pid) != nil and
            not Map.has_key?(m.names, Term.payload(name)) and
            pid not in Map.values(m.names)

        unless ok, do: throw({:fault, m, :badarg})

        # the gates hold the registry in an 8-entry shared CAM; a 9th
        # name is :system_limit on BOTH sides or the model is lying
        if map_size(m.names) >= 8, do: throw({:fault, m, :system_limit})

        m = %{m | names: Map.put(m.names, Term.payload(name), pid)}
        {m, p, ctx}

      {:whereis, rd, rn} ->
        name = w.(rn)
        unless Term.is?(name, :atom), do: throw({:fault, m, :badarg})
        {m, undef} = atom_word(m, :undefined)
        found = Map.get(m.names, Term.payload(name), undef)
        {m, p, put.(ctx, rd, found)}

      {:unreg, rn} ->
        name = w.(rn)

        unless Term.is?(name, :atom) and Map.has_key?(m.names, Term.payload(name)),
          do: throw({:fault, m, :badarg})

        m = %{m | names: Map.delete(m.names, Term.payload(name))}
        {m, p, ctx}

      {:recv, rd} ->
        {m, p, %{ctx | control: {:recv, rd}}}

      # -- selective receive ---------------------------------------------------
      {:recv_start} ->
        {m, %{p | cursor: 0, filter: nil}, ctx}

      {:recv_hash, spec} ->
        {m, h} = shape_hash_of_spec(m, spec)
        {m, %{p | filter: h}, ctx}

      {:recv_peek, rd, none_idx} ->
        {m, p, %{ctx | control: {:peek, rd, none_idx}}}

      # ---- try / catch -------------------------------------------------
      #
      # A catch frame records WHERE the handler is and HOW DEEP the
      # stacks were when the protected expression began. Both are
      # needed: the shape `erlc` actually emits wraps a CALL, so a raise
      # has to unwind frames before it can land, and a handler that ran
      # with the callee's window would read the wrong registers.
      {:try_begin, rd, label} ->
        frame = %{
          fun: elem(p.pc, 0),
          idx: label,
          rd: rd,
          rs: length(p.rstack),
          ws: length(p.windows)
        }

        {m, %{p | catches: [frame | p.catches]}, ctx}

      {:try_end} ->
        {m, %{p | catches: tl(p.catches)}, ctx}

      {:recv_skip} ->
        {m, %{p | cursor: p.cursor + 1}, ctx}

      {:recv_take, rd} ->
        {m, p, %{ctx | control: {:take, rd}}}

      {:recv_wait} ->
        {m, p, %{ctx | control: {:wait, nil}}}

      {:recv_waitt, rt, timeout_idx} ->
        t = int!(m, w.(rt))
        unless t > 0, do: throw({:fault, m, :badarg})
        {m, p, %{ctx | control: {:wait, {t, timeout_idx}}}}

      # Link/monitor registration RIDES THE RING (no more direct remote-table
      # mutation): the local half registers immediately, the remote half is a
      # wire. A request arriving for a dead/stale pid answers back on the
      # ring — :noproc as an exit signal (link) or a DOWN (monitor) — which
      # is Erlang's semantics with a bounded latency attached.
      {:link, rp} ->
        target = w.(rp)
        unless Term.is?(target, :pid), do: throw({:fault, m, :bad_tag})
        p = %{p | links: MapSet.put(p.links, target)}
        m = wire(m, eid, target, {:link_req, p.pid})
        {m, p, ctx}

      {:unlink, rp} ->
        target = w.(rp)
        p = %{p | links: MapSet.delete(p.links, target)}

        m =
          if Term.is?(target, :pid),
            do: wire(m, eid, target, {:unlink_req, p.pid}),
            else: m

        {m, p, ctx}

      {:monitor, rd, rp} ->
        target = w.(rp)
        unless Term.is?(target, :pid), do: throw({:fault, m, :bad_tag})
        e = elem(m.engines, eid)
        refw = Term.ref(e.next_ref)
        m = %{m | engines: put_elem(m.engines, eid, %{e | next_ref: e.next_ref + 1})}
        m = wire(m, eid, target, {:monitor_req, refw, p.pid})
        {m, p, put.(ctx, rd, refw)}

      {:exit2, rp, rr} ->
        target = w.(rp)
        unless Term.is?(target, :pid), do: throw({:fault, m, :bad_tag})
        m = wire(m, eid, target, {:exit_signal, p.pid, export_term(m, eid, w.(rr))})
        {m, p, ctx}

      {:trapexit, flag} ->
        {m, %{p | trap_exit: flag == 1}, ctx}

      # yield = force the budget to exhaust on this bundle; post_budget then
      # resets it and rotates to the run queue if anyone is waiting
      {:yield} ->
        {m, %{p | budget_left: 1}, ctx}

      {:fail, reason} when is_atom(reason) ->
        {m, p, %{ctx | control: {:die, reason}}}

      {:out, rs} ->
        {%{m | out: m.out ++ [decode(m, eid, w.(rs))], out_raw: m.out_raw ++ [w.(rs)]}, p, ctx}

      {:halt} ->
        {m, p, %{ctx | control: :halt}}
    end
  end

  # ---------------------------------------------------------------------------
  # Calls / windows
  # ---------------------------------------------------------------------------

  defp staged_args!(m, staged, arity) do
    Enum.map(0..(arity - 1)//1, fn i ->
      case Map.fetch(staged, i) do
        {:ok, w} -> w
        :error -> throw({:fault, m, :badarg})
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Funs (`notes/42`)
  #
  # `funinfo` packs {entry, arity, nfree}. `entry` is a pc, and a pc in
  # this model is a function NAME where in an image it is a bundle
  # address — the same relationship `call`'s target has, and the reason
  # `Encoding.image/2` exists. So the model stores the name's index in
  # `Encoding.fun_index_table/1`, which both sides compute from the same
  # `assembled` map rather than copying from each other.
  # ---------------------------------------------------------------------------
  defp funinfo_for!(m, f, nfree) when is_atom(f) do
    case Map.fetch(m.code, f) do
      # the lifted function takes the closure as its LAST argument, so
      # its arity is the fun's visible arity plus one
      {:ok, %{arity: total}} when total >= 1 ->
        idx = Map.fetch!(Encoding.fun_index_table(m.code), f)
        Term.funinfo(idx, total - 1, nfree)

      {:ok, _} ->
        throw({:fault, m, :badarity})

      :error ->
        throw({:fault, m, :badfun})
    end
  end

  defp funinfo_for!(m, _f, _nfree), do: throw({:fault, m, :badfun})

  # Read the closure and check the arity the way BEAM does. The CLOSURE
  # ITSELF is the last argument — the compiler stages it with an `arg`
  # slot in the same bundle — and the callee unpacks its captured
  # variables with `fget`.
  #
  # BEAM appends the free variables to the argument registers instead,
  # and `notes/42` proposed doing the same. It does not survive contact
  # with this machine: BEAM's x-registers are a flat array the emulator
  # can extend for free, while the staging bank here is a per-context
  # memory written from the X stage, so "append n words to another
  # context's staging" is a background FSM with its own write path.
  # Passing the closure and unpacking in the callee costs one argument
  # slot and one `fget` per captured variable, and is invisible from
  # Elixir — which is where the semantics that matter live.
  defp resolve_fun!(m, eid, ctx, word, arity) do
    addr = fun_addr!(m, word)
    info = heap_at(m, eid, addr + 1)

    if Term.funinfo_arity(info) != arity, do: throw({:fault, m, :badarity})

    names = m.code |> Encoding.fun_index_table() |> Map.new(fn {k, v} -> {v, k} end)

    f =
      case Map.fetch(names, Term.funinfo_entry(info)) do
        {:ok, name} -> name
        :error -> throw({:fault, m, :badfun})
      end

    {m, ctx, f, arity + 1}
  end

  defp check_arity!(m, f, arity) do
    case Map.fetch(m.code, f) do
      {:ok, %{arity: ^arity}} -> :ok
      _ -> throw({:fault, m, :badarg})
    end
  end

  defp do_spawn(m, eid, p, ctx, rd, f, arity) do
    check_arity!(m, f, arity)
    args = staged_args!(m, ctx.staged, arity)
    wire_args = Enum.map(args, &export_term(m, eid, &1))

    # Commit our own state BEFORE the child import: if the child lands on our
    # engine and its heap import collects, the table copy is a root and gets
    # rewritten; the exported args are already heap-independent.
    m = put_proc(m, eid, %{p | pc: ctx.next_pc, out_args: %{}})

    # Placement (`notes/47`, `notes/49`): round-robin from HOME, per
    # engine, and only for a spawn whose arguments are all IMMEDIATE.
    #
    # The counter was machine-global, which no engine can implement:
    # hardware has no shared state to round-robin over, and two engines
    # spawning at once would have to agree about whose turn it was.
    # `(home + rr) rem n` needs nothing but a counter each and starts
    # local, so a lone spawn stays where its arguments are. The GATES
    # implement it as `band(eng_id + sp_rr, N_ENG - 1)`, which is the
    # same function for a power-of-two engine count and nothing else —
    # every fabric this design fits is 1, 2 or 4, and `notes/49` says so
    # rather than leaving the two expressions to be compared by eye.
    #
    # The immediacy test is the honest half. A boxed argument is a
    # pointer into THIS engine's heap and the far end cannot read it;
    # carrying it means serialising, and that is not built (`notes/47`).
    # Staying home is not a semantic change — BEAM promises nothing
    # about which scheduler a process lands on — so this is a placement
    # decision, which is exactly what placement is allowed to be.
    e0 = elem(m.engines, eid)

    target =
      if Enum.all?(args, &immediate?/1) do
        rem(eid + e0.spawn_rr, m.n_engines)
      else
        eid
      end

    m = put_engine(m, eid, %{e0 | spawn_rr: e0.spawn_rr + 1})
    {m, child_pid} = spawn_serialized(m, target, f, wire_args)

    # re-fetch ourselves (possibly rewritten) and land the pid (an immediate)
    p = fetch_remote(m, p.pid)
    window = Map.put(hd(p.windows), rd, child_pid)
    put_proc(m, eid, %{p | windows: [window | tl(p.windows)]})
  catch
    {:fault, m2, reason} -> die(m2, eid, p, reason)
  end

  defp do_call(m, eid, p, ctx, f, arity, dest) do
    check_arity!(m, f, arity)
    if length(p.rstack) >= @max_rstack, do: throw({:fault, m, :stack_overflow})

    args = staged_args!(m, ctx.staged, arity)
    window = Map.new(Enum.with_index(args), fn {w, i} -> {i, w} end)
    {rf, ri} = ctx.next_pc

    p = %{
      p
      | windows: [window | p.windows],
        rstack: [{rf, ri, dest} | p.rstack],
        out_args: %{},
        pc: {f, 0}
    }

    put_proc(m, eid, p)
  catch
    {:fault, m2, reason} -> die(m2, eid, p, reason)
  end

  defp do_tailcall(m, eid, p, ctx, f, arity) do
    check_arity!(m, f, arity)
    args = staged_args!(m, ctx.staged, arity)
    window = Map.new(Enum.with_index(args), fn {w, i} -> {i, w} end)
    p = %{p | windows: [window | tl(p.windows)], out_args: %{}, pc: {f, 0}}
    put_proc(m, eid, p)
  catch
    {:fault, m2, reason} -> die(m2, eid, p, reason)
  end

  defp do_ret(m, eid, p, value) do
    case p.rstack do
      [] ->
        die(m, eid, p, :normal)

      [{rf, ri, dest} | rest] ->
        [_ | windows] = p.windows
        [caller | up] = windows
        caller = Map.put(caller, dest, value)
        p = %{p | windows: [caller | up], rstack: rest, pc: {rf, ri}}
        put_proc(m, eid, p)
    end
  end

  defp do_recv(m, eid, p, ctx, rd) do
    case p.mailbox do
      [{word, _h} | rest] ->
        window = Map.put(hd(p.windows), rd, word)

        p = %{p | mailbox: rest, cursor: 0, filter: nil,
              windows: [window | tl(p.windows)], pc: ctx.next_pc}

        put_proc(m, eid, p)

      [] ->
        put_proc(m, eid, %{p | state: {:recv, rd}, pc: ctx.next_pc})
    end
  end

  # ---------------------------------------------------------------------------
  # Heap
  # ---------------------------------------------------------------------------

  # Bump allocation into the current from-space. On exhaustion, Cheney runs
  # and the allocation retries in the fresh space; only live-data-exceeds-
  # semispace is :heap_full (Q7). The `words` being allocated are passed to
  # the collector as extra roots — a freshly imported sub-term is reachable
  # from nothing else yet.
  #
  # TIMING NOTE: the model charges the mutator ZERO cycles for collection.
  # That is the architecture's central claim (collector on port B), stated
  # here as an assumption the RTL must EARN at M5 — the retirement-counter
  # measurement in notes/05 is what upgrades this from assumption to result.
  # stats.gc records {cycle, live_words} so collector-keeps-up sizing
  # (Bacon's 1.01-1.4x) is checkable on the model.
  defp alloc(m, eid, words, owner \\ :any) do
    # whole CELLS: `RTL.Heap` allocates two-word cells and a tuple of even
    # arity is an odd number of words, so both sides waste the same word
    # and hit `heap_full` at the same allocation
    n = Term.cell_round(length(words))
    e = elem(m.engines, eid)

    # crossing the end of the semispace STARTS a collection; it does not
    # perform one. The allocation base moves and this allocation lands in
    # the fresh space (`notes/46`).
    m =
      if e.hp + n > (e.space + 1) * m.heap_words and not gc_active?(e) do
        gc_begin(m, eid)
      else
        m
      end

    # ...and the allocator has to have been collected before it may put
    # anything in to-space.
    {m, fwd} = gc_gate(m, eid, owner, words)
    words = if map_size(fwd) == 0, do: words, else: Enum.map(words, &rewrite_word(&1, fwd))

    e = elem(m.engines, eid)
    if e.hp + n > (e.space + 1) * m.heap_words, do: throw({:fault, m, :heap_full})

    heap =
      words
      |> pad_cell()
      |> Enum.with_index()
      |> Enum.reduce(e.heap, fn {w, i}, h -> Map.put(h, e.hp + i, w) end)

    e2 = %{e | heap: heap, hp: e.hp + n}
    {%{m | engines: put_elem(m.engines, eid, e2)}, e.hp}
  end

  # ---------------------------------------------------------------------------
  # The collector (`notes/46`): Cheney copying between semispaces, run ONE
  # PROCESS AT A TIME while the rest of the engine keeps executing.
  #
  # It works because `send` copies and `spawn` copies, so no pointer is
  # ever held by two processes and every object graph on the heap is
  # private to exactly one of them. Collecting a process therefore needs
  # that process stopped and nothing else — which is what BEAM does, and
  # for the same reason.
  #
  # A process is collected WHOLE: roots evacuated, then the Cheney scan
  # run to completion over what that evacuation produced, before it
  # resumes. Roots alone would not do. A copied object's contents are
  # still from-space pointers until something scans them, so a process
  # whose registers had been rewritten could immediately read one back
  # out of a to-space object and hold it in a register already declared
  # clean. That is the hole Baker's read barrier exists to plug; running
  # the scan first closes it without one.
  # ---------------------------------------------------------------------------

  defp gc_active?(e), do: e.gc != nil

  # A collection begins the moment an allocation would cross the end of
  # the semispace. Nothing stops: the allocation base moves to the other
  # semispace and the bundle proceeds there. From-space stops growing,
  # and the mutator has a whole fresh space to run in while the
  # collection happens around it.
  defp gc_begin(m, eid) do
    e = elem(m.engines, eid)
    to = 1 - e.space

    pending =
      for {slot, p} <- e.procs, p.state != :dead, into: MapSet.new(), do: slot

    # The forwarding map belongs to the COLLECTION, not to one process
    # of it. Graphs are private in the model, where `spawn` copies its
    # arguments — but they are not in the gates, where a spawn STAGES
    # them and parent and child can hold the same pointer. There the
    # forwarding WORD left in from-space makes the second collection
    # find the first one's answer; here the map has to do the same job,
    # or the two sides copy a shared object a different number of times.
    e = %{e | gc: %{from: e.space, pending: pending, fwd: %{}}, space: to, hp: to * m.heap_words}
    %{m | engines: put_elem(m.engines, eid, e)}
  end

  # Collect one process. `extra` is the in-flight execution state of a
  # process being collected mid-bundle — its working window, its pending
  # writes, its staging — which is as much a root as anything in the
  # proc table and is not in it yet.
  defp collect_slot(m, eid, slot, extra) do
    e = elem(m.engines, eid)
    gc = e.gc
    lo = gc.from * m.heap_words

    case Map.get(e.procs, slot) do
      nil ->
        {gc_drop(m, eid, slot), %{}}

      p ->
        roots =
          Enum.filter(extra, &is_integer/1) ++
            Enum.flat_map(p.windows, &Map.values/1) ++
            Map.values(p.out_args) ++
            Enum.map(p.mailbox, fn {w, _h} -> w end)

        # the scan starts where THIS process's copies start; everything
        # below it belongs to somebody else and has been scanned already
        scan_from = e.hp
        st = %{heap: e.heap, hp: e.hp, fwd: gc.fwd, lo: lo, hi: lo + m.heap_words}

        st = Enum.reduce(roots, st, fn w, st -> elem(evacuate(w, st), 1) end)
        st = cheney_scan(scan_from, st)

        e = %{e
          | heap: st.heap,
            hp: st.hp,
            gc: %{gc | fwd: st.fwd},
            procs: Map.put(e.procs, slot, rewrite_proc(p, st.fwd))}

        m = %{m | engines: put_elem(m.engines, eid, e)}
        {gc_drop(m, eid, slot), st.fwd}
    end
  end

  defp gc_drop(m, eid, slot) do
    e = elem(m.engines, eid)
    pending = MapSet.delete(e.gc.pending, slot)

    if MapSet.size(pending) == 0 do
      gc_finish(m, eid)
    else
      %{m | engines: put_elem(m.engines, eid, %{e | gc: %{e.gc | pending: pending}})}
    end
  end

  # Every live process has been collected, so from-space is dead. Drop
  # it rather than leaving it readable: a pointer that should have been
  # rewritten and was not now raises out of `Map.fetch!` instead of
  # returning plausible garbage, which is the difference between a test
  # that fails and a test that passes wrongly.
  defp gc_finish(m, eid) do
    e = elem(m.engines, eid)
    lo = e.gc.from * m.heap_words
    hi = lo + m.heap_words
    heap = Map.filter(e.heap, fn {a, _} -> a < lo or a >= hi end)
    live = e.hp - e.space * m.heap_words

    e = %{e | heap: heap, gc: nil}

    %{m
      | engines: put_elem(m.engines, eid, e),
        stats: Map.update!(m.stats, :gc, &[{m.cycle, eid, live} | &1])}
  end

  # A process may not allocate into to-space until it has been collected.
  # Otherwise it would write from-space pointers into a fresh to-space
  # object, its own root scan would see a to-space pointer and leave that
  # object alone, and the pointers inside it would never be found.
  #
  # `:any` is the message-import path, where the allocation happens on
  # behalf of a receiver the caller has not named. Collecting everything
  # still pending is a safe over-approximation: it only ever collects
  # sooner than it had to.
  defp gc_gate(m, eid, owner, extra) do
    e = elem(m.engines, eid)

    cond do
      not gc_active?(e) ->
        {m, %{}}

      owner == :any ->
        Enum.reduce(MapSet.to_list(e.gc.pending), {m, %{}}, fn slot, {m, fwd} ->
          e2 = elem(m.engines, eid)

          if gc_active?(e2) and MapSet.member?(e2.gc.pending, slot) do
            {m, f} = collect_slot(m, eid, slot, [])
            {m, Map.merge(fwd, f)}
          else
            {m, fwd}
          end
        end)

      MapSet.member?(e.gc.pending, owner) ->
        collect_slot(m, eid, owner, extra)

      true ->
        {m, %{}}
    end
  end

  # The heap allocates whole CELLS and an object of odd word count leaves
  # a pad word behind. It has to be WRITTEN, not merely skipped over.
  #
  # In the model, an unwritten pad is a hole, and Cheney's scan walks
  # to-space word by word — so the first even-arity tuple to survive a
  # collection took `Map.fetch!` through the floor. In the RTL it is
  # worse and quieter: the collector copies whole cells, so the pad comes
  # across carrying whatever the previous occupant of that word left
  # there, and if that happens to look like a pointer the collector
  # keeps a dead object alive. A leak rather than a crash, which is the
  # harder of the two to ever notice.
  #
  # `nil` because it is a tag the scan will not follow, and because a
  # defined value is the whole point.
  defp pad_cell(words) do
    if rem(length(words), 2) == 1, do: words ++ [Term.nil_word()], else: words
  end

  # Copy one object if the word is a pointer; children are copied verbatim
  # (still pointing into from-space) and fixed by the scan pass.
  # The pointer tags. `notes/42` added `fun`, and it belongs here rather
  # than at three separate `in [:cons, :tuple]` tests, which is exactly
  # the shape `notes/40` found in the RTL collector and named.
  @boxed [:cons, :tuple, :fun, :map, :bin]

  # A word the far end can read without a heap of ours behind it.
  # Defined HERE and not beside `put_engine/3`, because a module
  # attribute is `nil` above its own definition and the failure is a
  # protocol error two hundred lines away (`notes/26`, the same shape as
  # `@maps_prelude`).
  defp immediate?(w) when is_integer(w), do: Term.tag_name(w) not in @boxed
  defp immediate?(_), do: true

  defp from_space?(a, st), do: a >= st.lo and a < st.hi

  defp evacuate(word, st) when is_integer(word) do
    tag = Term.tag_name(word)
    a = if tag in @boxed, do: Term.word_of(word), else: -1

    # A pointer is only ours to move if it is in FROM-space. One already
    # in to-space is either a copy this collection made or an object
    # allocated since it began; following it would copy live data as if
    # it were garbage. `RTL.Collector` asks the same question with one
    # comparator (`notes/46`).
    if tag in @boxed and from_space?(a, st) do
      case Map.fetch(st.fwd, a) do
        {:ok, na} ->
          {Term.make(tag, Term.cell_of(na)), st}

        :error ->
          size =
            case tag do
              :cons -> 2
              # a fun is laid out exactly like a tuple, header included,
              # which is the whole reason it was given that shape
              t when t in [:tuple, :fun, :map, :bin] ->
                1 + Term.payload(Map.fetch!(st.heap, a))
            end

          na = st.hp

          # copy whole CELLS, pad included: to-space must have no holes
          # for the scan to walk, and the pad is a defined `nil` because
          # `alloc/3` wrote one
          heap =
            Enum.reduce(0..(Term.cell_round(size) - 1), st.heap, fn i, h ->
              Map.put(h, na + i, Map.get(st.heap, a + i, Term.nil_word()))
            end)

          # to-space stays cell-aligned too, or the copy would re-seat
          # objects mid-cell and every pointer into them would be unnameable
          st = %{st | heap: heap, hp: na + Term.cell_round(size), fwd: Map.put(st.fwd, a, na)}
          {Term.make(tag, Term.cell_of(na)), st}
      end
    else
      {word, st}
    end
  end

  defp evacuate(word, st), do: {word, st}

  defp cheney_scan(p, st) when p >= 0 do
    if p >= st.hp do
      st
    else
      w = Map.fetch!(st.heap, p)

      {w2, st} =
        if is_integer(w) and Term.tag_name(w) in @boxed do
          evacuate(w, st)
        else
          {w, st}
        end

      cheney_scan(p + 1, %{st | heap: Map.put(st.heap, p, w2)})
    end
  end

  defp rewrite_word(word, fwd) when is_integer(word) do
    tag = Term.tag_name(word)

    # `Map.fetch` and not `Map.fetch!`: a process being collected can be
    # holding pointers this collection is not moving — objects it
    # allocated in to-space since the collection began. Leaving them
    # alone is the correct answer, not a missing entry (`notes/46`).
    if tag in @boxed do
      case Map.fetch(fwd, Term.word_of(word)) do
        {:ok, na} -> Term.make(tag, Term.cell_of(na))
        :error -> word
      end
    else
      word
    end
  end

  defp rewrite_word(word, _fwd), do: word

  defp rewrite_proc(p, fwd) do
    %{p
      | windows: Enum.map(p.windows, fn w -> Map.new(w, fn {r, v} -> {r, rewrite_word(v, fwd)} end) end),
        out_args: Map.new(p.out_args, fn {i, v} -> {i, rewrite_word(v, fwd)} end),
        mailbox: Enum.map(p.mailbox, fn {w, h} -> {rewrite_word(w, fwd), h} end)}
  end

  # Allocation from INSIDE a bundle: the in-flight execution state (working
  # window, pending writes, staging) joins the root set, and on a collection
  # every piece of it — plus the local copy of the process — is rewritten
  # before execution continues. This is the model's version of the
  # mutator/collector interface contract.
  defp alloc_exec(m, eid, p, ctx, words) do
    slot = Term.pid_slot(p.pid)
    n = Term.cell_round(length(words))
    e = elem(m.engines, eid)

    m =
      if e.hp + n > (e.space + 1) * m.heap_words and not gc_active?(e) do
        gc_begin(m, eid)
      else
        m
      end

    # The in-flight execution state is as much a root as anything in the
    # proc table, and is not in it yet: the working window, the writes
    # this bundle has not retired, and the staging bank.
    extra =
      (words ++ Map.values(ctx.window) ++ Map.values(ctx.writes) ++ Map.values(ctx.staged))
      |> Enum.filter(&is_integer/1)

    {m, fwd} = gc_gate(m, eid, slot, extra)

    {p, ctx, words} =
      if map_size(fwd) == 0 do
        {p, ctx, words}
      else
        ctx = %{
          ctx
          | window: Map.new(ctx.window, fn {r, v} -> {r, rewrite_word(v, fwd)} end),
            writes: Map.new(ctx.writes, fn {r, v} -> {r, rewrite_word(v, fwd)} end),
            staged: Map.new(ctx.staged, fn {i, v} -> {i, rewrite_word(v, fwd)} end)
        }

        {rewrite_proc(p, fwd), ctx, Enum.map(words, &rewrite_word(&1, fwd))}
      end

    {m, addr} = alloc(m, eid, words, slot)
    {m, p, ctx, addr}
  end

  defp heap_at(m, eid, addr), do: Map.fetch!(elem(m.engines, eid).heap, addr)

  defp heap_put(m, eid, addr, word) do
    e = elem(m.engines, eid)
    %{m | engines: put_elem(m.engines, eid, %{e | heap: Map.put(e.heap, addr, word)})}
  end

  defp cons_addr!(m, w) do
    if Term.is?(w, :cons), do: Term.word_of(w), else: throw({:fault, m, :bad_tag})
  end

  defp tuple_addr!(m, w) do
    if Term.is?(w, :tuple), do: Term.word_of(w), else: throw({:fault, m, :bad_tag})
  end

  # `tset` is the "fill the freshly made object" idiom and a closure is
  # filled the same way, so it accepts a fun pointer too (`notes/42`).
  # `tget` and `tarity` do NOT: a fun is opaque to `element/2`, which is
  # what BEAM guarantees, and the tag is the whole reason a fun is not
  # simply a tuple.
  # `tset` fills any boxed object at a LITERAL index — a tuple, a
  # closure, a map, a binary. What it refuses is a cons and an immediate,
  # which is the check that matters; `tget` is the one that has to be
  # narrow, because `element/2` is a thing programs say.
  defp fillable_addr!(m, w) do
    if Term.is?(w, :tuple) or Term.is?(w, :fun) or Term.is?(w, :map) or Term.is?(w, :bin),
      do: Term.word_of(w),
      else: throw({:fault, m, :bad_tag})
  end

  defp map_addr!(m, w) do
    if Term.is?(w, :map), do: Term.word_of(w), else: throw({:fault, m, :badmap})
  end

  defp bin_addr!(m, w) do
    if Term.is?(w, :bin), do: Term.word_of(w), else: throw({:fault, m, :badmap})
  end

  # `mset` fills a map OR a binary: the two objects whose index a program
  # computes rather than knows (`notes/43`)
  defp settable_addr!(m, w) do
    if Term.is?(w, :map) or Term.is?(w, :bin),
      do: Term.word_of(w),
      else: throw({:fault, m, :badmap})
  end

  defp fun_addr!(m, w) do
    if Term.is?(w, :fun), do: Term.word_of(w), else: throw({:fault, m, :badfun})
  end

  defp check_tuple_index!(m, eid, addr, i) do
    arity = Term.payload(heap_at(m, eid, addr))
    unless i < arity, do: throw({:fault, m, :badarg})
  end

  # ---------------------------------------------------------------------------
  # Term export/import — the serializer/deserializer pair. An exported term
  # is the wire form; its word count is the flit count.
  # ---------------------------------------------------------------------------

  def export_term(m, eid, word) do
    case Term.tag_name(word) do
      :cons ->
        a = Term.word_of(word)
        {:cons, export_term(m, eid, heap_at(m, eid, a)), export_term(m, eid, heap_at(m, eid, a + 1))}

      :tuple ->
        a = Term.word_of(word)
        arity = Term.payload(heap_at(m, eid, a))
        {:tuple, Enum.map(0..(arity - 1)//1, fn i -> export_term(m, eid, heap_at(m, eid, a + 1 + i)) end)}

      _immediate ->
        {:imm, word}
    end
  end

  def import_term(m, eid, wire_form) do
    case wire_form do
      {:imm, word} ->
        {m, word, 0}

      {:cons, h, t} ->
        {m, hw, n1} = import_term(m, eid, h)
        {m, tw, n2} = import_term(m, eid, t)
        {m, addr} = alloc(m, eid, [hw, tw])
        {m, Term.cons(addr), n1 + n2 + 2}

      {:tuple, elems} ->
        {m, words, n} =
          Enum.reduce(elems, {m, [], 0}, fn e, {m, ws, n} ->
            {m, w, k} = import_term(m, eid, e)
            {m, [w | ws], n + k}
          end)

        arity = length(elems)
        {m, addr} = alloc(m, eid, [Term.hdr(arity) | Enum.reverse(words)])
        {m, Term.tuple(addr), n + 1 + arity}
    end
  end

  def flits(wire_form) do
    case wire_form do
      {:imm, _} -> 1
      {:cons, h, t} -> 1 + flits(h) + flits(t)
      {:tuple, es} -> 1 + Enum.reduce(es, 0, &(flits(&1) + &2))
    end
  end

  # ---------------------------------------------------------------------------
  # The ring
  # ---------------------------------------------------------------------------

  defp hops(m, from, to), do: rem(to - from + m.n_engines, m.n_engines)

  defp wire(m, from_eid, dest_pid_word, payload) do
    fl =
      case payload do
        {:message, wf} -> flits(wf)
        {:exit_signal, _, wf} -> 1 + flits(wf)
        {:down_signal, _, _, wf} -> 2 + flits(wf)
        {:link_req, _} -> 2
        {:unlink_req, _} -> 2
        {:monitor_req, _, _} -> 3
      end

    latency = @wire_base + hops(m, from_eid, Term.pid_engine(dest_pid_word)) + fl

    entry = %{
      due: m.cycle + latency,
      seq: m.wire_seq,
      dest: dest_pid_word,
      payload: payload,
      latency: latency
    }

    %{m | wires: [entry | m.wires], wire_seq: m.wire_seq + 1,
        stats: Map.update!(m.stats, :wire_latencies, &[latency | &1])}
  end

  defp deliver_due(m) do
    {due, later} = Enum.split_with(m.wires, &(&1.due <= m.cycle))
    due = Enum.sort_by(due, &{&1.due, &1.seq})
    Enum.reduce(due, %{m | wires: later}, &deliver/2)
  end

  defp deliver(entry, m) do
    eid = Term.pid_engine(entry.dest)

    if eid == 15 do
      %{m | host_out: m.host_out ++ [{entry.dest, entry.payload}]}
    else
      deliver_engine(entry, m, eid)
    end
  end

  defp deliver_engine(entry, m, eid) do
    slot = Term.pid_slot(entry.dest)
    e = elem(m.engines, eid)

    case Map.get(e.procs, slot) do
      %{pid: pid, state: state} = p when pid == entry.dest and state != :dead ->
        deliver_to(m, eid, p, entry.payload)

      _ ->
        # Dead letter: wrong serial, freed slot, or dead. Messages and
        # signals drop; REGISTRATION requests answer back on the ring with
        # Erlang's :noproc semantics.
        case entry.payload do
          {:link_req, from} ->
            {m, noproc} = atom_word(m, :noproc)
            wire(m, eid, from, {:exit_signal, entry.dest, {:imm, noproc}})

          {:monitor_req, refw, from} ->
            {m, noproc} = atom_word(m, :noproc)
            wire(m, eid, from, {:down_signal, refw, entry.dest, {:imm, noproc}})

          _ ->
            m
        end
    end
  end

  # Every alloc on the delivery path can collect, so the process is
  # re-fetched from the table (where it is a GC root) after each one.
  defp deliver_to(m, eid, p, {:message, wf}) do
    {m, word, _} = import_term(m, eid, wf)
    mailbox_in(m, eid, refetch(m, p), word)
  end

  defp deliver_to(m, eid, p, {:exit_signal, from_pid, reason_wf}) do
    {m, reason_word, _} = import_term(m, eid, reason_wf)
    p = refetch(m, p)
    {m, kill_word} = atom_word(m, :kill)
    {m, normal_word} = atom_word(m, :normal)

    cond do
      reason_word == kill_word ->
        {m, killed} = atom_word(m, :killed)
        die(m, eid, p, {:word, killed})

      p.trap_exit ->
        {m, exit_atom} = atom_word(m, :EXIT)
        {m, addr} = alloc(m, eid, [Term.hdr(3), exit_atom, from_pid, reason_word])
        mailbox_in(m, eid, refetch(m, p), Term.tuple(addr))

      reason_word == normal_word ->
        m

      true ->
        die(m, eid, p, {:word, reason_word})
    end
  end

  defp deliver_to(m, eid, p, {:down_signal, ref_word, from_pid, reason_wf}) do
    {m, reason_word, _} = import_term(m, eid, reason_wf)
    {m, down_atom} = atom_word(m, :DOWN)
    {m, addr} = alloc(m, eid, [Term.hdr(4), down_atom, ref_word, from_pid, reason_word])
    mailbox_in(m, eid, refetch(m, p), Term.tuple(addr))
  end

  defp deliver_to(m, eid, p, {:link_req, from}) do
    put_proc(m, eid, %{p | links: MapSet.put(p.links, from)})
  end

  defp deliver_to(m, eid, p, {:unlink_req, from}) do
    put_proc(m, eid, %{p | links: MapSet.delete(p.links, from)})
  end

  defp deliver_to(m, eid, p, {:monitor_req, refw, from}) do
    put_proc(m, eid, %{p | watchers: [{refw, from} | p.watchers]})
  end

  defp refetch(m, p), do: fetch_remote(m, p.pid) || p

  # The mailbox writer FSM: hash the shape at enqueue (free — it happens as
  # the flits land), enforce the bounded depth, wake waiters. A full mailbox
  # is the receiver's failure to keep up, answered the Erlang way (same
  # reasoning as Q7's :heap_full): the receiver exits :mailbox_full and
  # supervision takes it from there. Backpressure on the SENDER would leak
  # one process's slowness into another's WCET.
  defp mailbox_in(m, eid, p, word) do
    case p.state do
      {:recv, rd} ->
        window = Map.put(hd(p.windows), rd, word)
        wake(m, eid, %{p | state: :run, windows: [window | tl(p.windows)]})

      _ when length(p.mailbox) >= m.mailbox_depth ->
        die(m, eid, p, :mailbox_full)

      {:wait_msg, seen, resume_pc, _timeout} ->
        {m, h} = shape_hash_of_word(m, eid, word)
        p = %{p | mailbox: p.mailbox ++ [{word, h}]}

        if length(p.mailbox) > seen do
          wake(m, eid, %{p | state: :run, pc: resume_pc})
        else
          put_proc(m, eid, p)
        end

      _ ->
        {m, h} = shape_hash_of_word(m, eid, word)
        put_proc(m, eid, %{p | mailbox: p.mailbox ++ [{word, h}]})
    end
  end

  # ---------------------------------------------------------------------------
  # Shape hashing (notes/03): tag, arity, and the first element if it is an
  # atom — 8 bits, computed once at enqueue, letting receive reject
  # non-matching messages without reading their contents.
  # ---------------------------------------------------------------------------

  defp shape_hash_of_word(m, eid, word) do
    shape =
      case Term.tag_name(word) do
        :tuple ->
          a = Term.word_of(word)
          arity = Term.payload(heap_at(m, eid, a))
          first = heap_at(m, eid, a + 1)

          if arity >= 1 and is_integer(first) and Term.is?(first, :atom) do
            {:tuple, arity, Term.payload(first)}
          else
            {:tuple, arity, nil}
          end

        :atom ->
          {:atom, Term.payload(word)}

        :cons ->
          {:cons}

        other ->
          {:imm, other}
      end

    {m, :erlang.phash2(shape, 256)}
  end

  defp shape_hash_of_spec(m, spec) do
    case spec do
      {:tuple, arity, first_atom} when is_atom(first_atom) ->
        {m, idx} = intern(m, first_atom)
        {m, :erlang.phash2({:tuple, arity, idx}, 256)}

      {:tuple, arity, nil} ->
        {m, :erlang.phash2({:tuple, arity, nil}, 256)}

      {:atom, a} when is_atom(a) ->
        {m, idx} = intern(m, a)
        {m, :erlang.phash2({:atom, idx}, 256)}

      :cons ->
        {m, :erlang.phash2({:cons}, 256)}
    end
  end

  # ---------------------------------------------------------------------------
  # Processes: spawn, links, monitors, death
  # ---------------------------------------------------------------------------

  defp spawn_proc(m, eid, fun, literal_args) do
    {m, args} =
      Enum.reduce(literal_args, {m, []}, fn
        v, {m, acc} when is_integer(v) ->
          {m, [{:imm, Term.int(v)} | acc]}

        a, {m, acc} when is_atom(a) ->
          {m, w} = atom_word(m, a)
          {m, [{:imm, w} | acc]}
      end)

    spawn_serialized(m, eid, fun, Enum.reverse(args))
  end

  defp spawn_serialized(m, eid, fun, wire_args) do
    e = elem(m.engines, eid)
    slot = free_slot(e)

    # The 6-bit PID slot field IS the proc-table size: 64 processes per
    # engine is an architectural limit, and hitting it is :system_limit on
    # the spawner. (M9's hibernation tier is what raises the practical
    # ceiling, not a wider table.)
    if slot == nil, do: throw({:fault, m, :system_limit})

    serial = (Map.get(e.serials, slot, 0) + 1) &&& 0x3FFFFF
    pid = Term.pid(eid, slot, serial)

    {m, args, _} =
      Enum.reduce(wire_args, {m, [], 0}, fn wf, {m, acc, n} ->
        {m, w, k} = import_term(m, eid, wf)
        {m, acc ++ [w], n + k}
      end)

    window = Map.new(Enum.with_index(args), fn {w, i} -> {i, w} end)

    p = %{
      pid: pid,
      pc: {fun, 0},
      windows: [window],
      out_args: %{},
      rstack: [],
      # catch frames, innermost first. BEAM pushes these on the stack;
      # the model keeps them beside it, which is the same thing with the
      # depths written down rather than implied.
      catches: [],
      mailbox: [],
      cursor: 0,
      filter: nil,
      # `notes/42` — the index the next `mset` writes at. Per process,
      # because a fill loop can be swapped out in the middle of one.
      map_idx: 0,
      state: :run,
      trap_exit: false,
      links: MapSet.new(),
      watchers: [],
      budget_left: m.budget
    }

    e = elem(m.engines, eid)
    e = %{
      e
      | procs: Map.put(e.procs, slot, p),
        serials: Map.put(e.serials, slot, serial)
    }

    # take a free seat if one exists (paying swap-in), else join the queue
    e =
      case free_seat(e, m.t_contexts) do
        nil ->
          %{e | run_queue: e.run_queue ++ [slot]}

        seat ->
          %{e
            | seats: put_elem(e.seats, seat, slot),
              seat_ready: put_elem(e.seat_ready, seat, m.cycle + m.swap_cost)}
      end

    {%{m | engines: put_elem(m.engines, eid, e)}, pid}
  end

  defp free_seat(e, t) do
    Enum.find(0..(t - 1), fn i -> elem(e.seats, i) == nil end)
  end

  defp free_slot(e) do
    Enum.find(0..63, fn s -> not Map.has_key?(e.procs, s) end)
  end

  defp seated?(e, slot, t) do
    Enum.any?(0..(t - 1), fn i -> elem(e.seats, i) == slot end)
  end

  # A process that becomes runnable while unseated joins the run queue.
  defp wake(m, eid, p) do
    m = put_proc(m, eid, p)
    e = elem(m.engines, eid)
    slot = Term.pid_slot(p.pid)

    if seated?(e, slot, m.t_contexts) or slot in e.run_queue do
      m
    else
      e = %{e | run_queue: e.run_queue ++ [slot]}
      %{m | engines: put_elem(m.engines, eid, e)}
    end
  end

  defp fetch_remote(m, pid_word) do
    e = elem(m.engines, Term.pid_engine(pid_word))

    case Map.get(e.procs, Term.pid_slot(pid_word)) do
      %{pid: ^pid_word, state: state} = p when state != :dead -> p
      _ -> nil
    end
  end

  # A raise looks for a catch frame before it looks for a grave. This is
  # the whole of `try`/`catch`: unwind to the depths the frame recorded,
  # land on its handler, and hand the handler the class and the reason.
  #
  # Class is `:error` for everything the machine raises on its own —
  # badarith, bad_tag, overflow. `throw` and `exit` would carry their
  # own classes, and the front end does not emit them yet.
  defp die(m, eid, %{catches: [frame | rest]} = p, reason) do
    {m, reason_word} =
      case reason do
        {:word, w} -> {m, w}
        a when is_atom(a) -> atom_word(m, a)
      end

    {m, class_word} = atom_word(m, :error)

    windows = Enum.drop(p.windows, length(p.windows) - frame.ws)
    rstack = Enum.drop(p.rstack, length(p.rstack) - frame.rs)

    window =
      windows
      |> hd()
      |> Map.put(frame.rd, class_word)
      |> Map.put(frame.rd + 1, reason_word)

    p = %{
      p
      | catches: rest,
        windows: [window | tl(windows)],
        rstack: rstack,
        out_args: %{},
        pc: {frame.fun, frame.idx}
    }

    put_proc(m, eid, p)
  end

  defp die(m, eid, p, reason) do
    {m, reason_word} =
      case reason do
        {:word, w} -> {m, w}
        a when is_atom(a) -> atom_word(m, a)
      end

    reason_wf = export_term(m, eid, reason_word)
    m = reap(m, eid, p, reason_word)

    # exit signals to links, DOWN to watchers — all on the ring
    m =
      Enum.reduce(p.links, m, fn linked, m ->
        wire(m, eid, linked, {:exit_signal, p.pid, reason_wf})
      end)

    Enum.reduce(p.watchers, m, fn {refw, watcher}, m ->
      wire(m, eid, watcher, {:down_signal, refw, p.pid, reason_wf})
    end)
  end

  # `erlang:halt/0` stops the VM. It is NOT an exit: BEAM runs no exit
  # handler, sends no signal, and a `try` around it does not catch —
  # which is why the caller is reaped here rather than sent through
  # `die/4`, whose first clause would hand it to a catch frame.
  #
  # Everyone else stays exactly where they are. The engine freezes on a
  # sticky `vm_halt` rather than resetting (`notes/33`), so the model
  # holding the population and the netlist holding the population are
  # the same statement, and `deaths` means the same number on both.
  defp do_halt(m, eid, p, ctx) do
    p = %{p | pc: ctx.next_pc}
    m = put_proc(m, eid, p)
    {m, normal} = atom_word(m, :normal)
    # `keep: true` — the corpse stays readable. On the netlist the
    # register windows are still sitting in the RAM after a halt, and
    # every `Machine` test that inspects the root process's registers
    # after `run/2` is asking the same question of the model. A dead
    # process nobody can look at is a worse oracle, not a purer one.
    m = reap(m, eid, p, normal, true)
    %{m | halted: true}
  end

  # free the seat, mark dead, record it. The half of a death that every
  # death does, whatever it does afterwards.
  defp reap(m, eid, p, reason_word, keep \\ false) do
    slot = Term.pid_slot(p.pid)
    e = elem(m.engines, eid)
    seat = Enum.find(0..(m.t_contexts - 1), fn i -> elem(e.seats, i) == slot end)
    seats = if seat, do: put_elem(e.seats, seat, nil), else: e.seats

    dead =
      if keep,
        do: %{p | state: :dead},
        else: %{p | state: :dead, mailbox: [], windows: [%{}]}

    # a dying process's registered name is released — BEAM's
    # auto-unregister, and the reason a name-table hit implies alive
    m = %{m | names: for({n, pid} <- m.names, pid != p.pid, into: %{}, do: {n, pid})}

    e = %{e
      | seats: seats,
        procs: Map.put(e.procs, slot, dead),
        run_queue: List.delete(e.run_queue, slot)}

    m = %{m | engines: put_elem(m.engines, eid, e)}

    reason_name = if Term.is?(reason_word, :atom), do: atom_name(m, reason_word), else: :term
    %{m | stats: Map.update!(m.stats, :deaths, &[{p.pid, reason_name} | &1])}
  end

  # ---------------------------------------------------------------------------
  # Test/debug helpers
  # ---------------------------------------------------------------------------

  @doc "Decode a term word from an engine's heap into an Elixir value."
  def decode(m, eid, word) do
    case Term.tag_name(word) do
      :int -> Term.int_value(word)
      :atom -> atom_name(m, word)
      :nil -> []
      :pid -> {:pid, Term.pid_engine(word), Term.pid_slot(word), Term.pid_serial(word)}
      :ref -> {:ref, Term.payload(word)}
      :cons ->
        a = Term.word_of(word)
        [decode(m, eid, heap_at(m, eid, a)) | decode(m, eid, heap_at(m, eid, a + 1))]

      :tuple ->
        a = Term.word_of(word)
        arity = Term.payload(heap_at(m, eid, a))
        List.to_tuple(Enum.map(0..(arity - 1)//1, fn i -> decode(m, eid, heap_at(m, eid, a + 1 + i)) end))

      other ->
        {other, Term.payload(word)}
    end
  end

  def deaths(m), do: Enum.reverse(m.stats.deaths)
end
