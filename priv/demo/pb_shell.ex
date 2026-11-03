defmodule PbShell do
  # The resident half of the picoBEAM shell (`PicoBEAM.ShellLine`, the
  # fabfarm `Pb.Shell`). Boot with `main/0` on engine 0.
  #
  # The host compiles each line into a function `run(bindings)` that
  # returns `{value, new_bindings}`, links it into code memory while the
  # machine runs, and rewrites the first bundle of `line/1` below into a
  # `jmp` to it. Then it sends `{:eval, host_pid, id}` and the evaluator
  # runs the line. The bindings live HERE, in the evaluator's loop
  # state, so a pid or a list bound on one line is the real term on the
  # next; only the value crosses the wire.
  #
  # `main/0` traps exits and restarts the evaluator when it dies (a
  # fault in a line that `try` cannot catch), telling the host both
  # times, so the host always knows which pid evaluates.

  def main do
    Process.flag(:trap_exit, true)
    start()
  end

  def start do
    pid = spawn_link(PbShell, :eval, [{:pb_b}])
    send(:erlang.host(), {:pb_shell, pid})
    watch(pid)
  end

  def watch(pid) do
    receive do
      {:EXIT, ^pid, reason} ->
        send(:erlang.host(), {:pb_down, reason})
        start()
    end
  end

  def eval(b) do
    receive do
      {:eval, from, id} ->
        b2 = run_line(from, id, b)
        eval(b2)
    end
  end

  def run_line(from, id, b) do
    try do
      {r, b2} = line(b)
      send(from, {:pb_ok, id, r})
      b2
    catch
      kind, reason ->
        send(from, {:pb_error, id, kind, reason})
        b
    end
  end

  # Rewritten by the host before every `:eval`; never run as written.
  def line(b), do: {:no_line, b}
end
