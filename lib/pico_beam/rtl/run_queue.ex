defmodule PicoBEAM.RTL.RunQueue do
  @moduledoc """
  M3 pass 2 — the run queue: a 32-deep FIFO of proc-table slot ids.

  `notes/12`: "the only scheduling policy in the machine." Runnable-but-
  unseated processes wait here in arrival order; seats fill from the
  head as the rotation visits them (lazy, per the model), descheduled
  and woken processes join the tail. Nothing else. The rotation itself
  makes no decisions, so this FIFO is the entire policy surface.

  Ring buffer in LUT-RAM (32 × 5 async read → DPR16X4 class), head/
  tail counters, and a count register for empty/full — the RegFIFO16
  idiom at different dimensions. Push and pop may land on the same
  cycle (seat-in while a deschedule enqueues): both are honored; count
  nets to unchanged. Push to a FULL queue cannot happen by
  construction — the queue is as deep as the proc table, and only
  allocated slots enqueue — but the `full` output exists so the engine
  can assert on it rather than trust the argument.

  `q_head` presents the head entry combinationally whenever non-empty;
  `pop` consumes it on the edge. The engine reads-then-pops in one
  cycle (async RAM), the same read-old discipline as everything else.
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  input :push, 1
  input :push_data, 5
  input :pop, 1

  output :q_head, 5
  output :empty, 1
  output :full, 1
  output :count, 6

  memory :q, width: 5, depth: 32

  wire :head, 5, init: 0
  wire :tail, 5, init: 0
  wire :cnt, 6, init: 0

  comb do
    q_head = q[head]
    empty = cnt == 0
    full = cnt == 32
    count = cnt
  end

  on :clk do
    if rst == 1 do
      head = 0
      tail = 0
      cnt = 0
    else
      if push == 1 do
        q[tail] = push_data
        tail = tail + 1
      end

      if pop == 1 do
        head = head + 1
      end

      # same-cycle push+pop nets to no change
      if band(push, bnot(pop)) == 1 do
        cnt = cnt + 1
      end

      if band(pop, bnot(push)) == 1 do
        cnt = cnt - 1
      end
    end
  end
end
