defmodule Destila.Terminal.PTY do
  @moduledoc """
  Internal wrapper over a PTY backend (currently `expty`).

  Gives the rest of the app a narrow, backend-agnostic contract so the
  underlying library can be swapped without touching callers. Also
  normalizes callback-based libraries (expty) and message-based ones
  (erlexec) into a single message shape delivered to the `owner`:

      {:pty_output, handle, iodata}
      {:pty_exit, handle, {:status, integer} | {:signal, atom_or_integer, boolean}}

  The `handle` is opaque. Only this module inspects it. The `owner`
  process is also linked to the underlying PTY process: if the PTY
  dies, the owner receives the usual `{:EXIT, handle, reason}` and can
  stop itself as before.

  Public arity uses `(cols, rows)` to match xterm.js and the current
  call sites. Backends that want `(rows, cols)` (e.g. erlexec's
  `:exec.winsz/3`) flip the arguments internally.
  """

  @type handle :: pid() | {pid(), pos_integer()}
  @type spawn_opts :: [
          cmd: String.t(),
          args: [String.t()],
          cwd: String.t(),
          cols: pos_integer(),
          rows: pos_integer()
        ]

  @spec spawn(pid(), spawn_opts()) :: {:ok, handle()} | {:error, term()}
  def spawn(owner, opts) when is_pid(owner) do
    cmd = Keyword.fetch!(opts, :cmd)
    args = Keyword.fetch!(opts, :args)
    cwd = Keyword.fetch!(opts, :cwd)
    cols = Keyword.fetch!(opts, :cols)
    rows = Keyword.fetch!(opts, :rows)

    case ExPTY.spawn(cmd, args, cwd: cwd, cols: cols, rows: rows, closeFDs: true) do
      {:ok, pty} ->
        Process.link(pty)

        ExPTY.on_data(pty, fn _pty, _pid, data ->
          send(owner, {:pty_output, pty, data})
        end)

        ExPTY.on_exit(pty, fn _pty, _pid, exit_code, signal ->
          reason =
            if signal == 0 do
              {:status, exit_code}
            else
              {:signal, signal, false}
            end

          send(owner, {:pty_exit, pty, reason})
        end)

        {:ok, pty}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec write(handle(), iodata()) :: :ok
  def write(handle, data), do: ExPTY.write(handle, data)

  @spec resize(handle(), pos_integer(), pos_integer()) :: :ok
  def resize(handle, cols, rows), do: ExPTY.resize(handle, cols, rows)

  @spec kill(handle(), integer()) :: :ok
  def kill(handle, signal), do: ExPTY.kill(handle, signal)
end
