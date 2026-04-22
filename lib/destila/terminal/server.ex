defmodule Destila.Terminal.Server do
  use GenServer

  alias Destila.Terminal.{PTY, Tmux}

  defstruct [:pty, :topic, :cols, :rows]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def write(server, data), do: GenServer.cast(server, {:write, data})
  def resize(server, cols, rows), do: GenServer.cast(server, {:resize, cols, rows})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cwd = Keyword.fetch!(opts, :cwd)
    topic = Keyword.fetch!(opts, :topic)
    session_name = Keyword.get(opts, :session_name, "destila")
    claude_session_id = Keyword.get(opts, :claude_session_id)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)

    Tmux.ensure_session(session_name, cwd)
    setup_claude_window(session_name, cwd, claude_session_id)

    attach_cmd = "tmux attach -t #{Tmux.escape_shell(session_name)}"

    {:ok, pty} =
      PTY.spawn(self(),
        cmd: "/usr/bin/env",
        args: ["TERM=xterm-256color", "COLORTERM=truecolor", "/bin/sh", "-c", attach_cmd],
        cwd: cwd,
        cols: cols,
        rows: rows
      )

    {:ok, %__MODULE__{pty: pty, topic: topic, cols: cols, rows: rows}}
  end

  @impl true
  def handle_cast({:write, data}, state) do
    PTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    PTY.resize(state.pty, cols, rows)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:pty_output, pty, data}, %{pty: pty} = state) do
    Phoenix.PubSub.broadcast(Destila.PubSub, state.topic, {:terminal_output, data})
    {:noreply, state}
  end

  def handle_info({:pty_exit, pty, _reason}, %{pty: pty} = state) do
    Phoenix.PubSub.broadcast(Destila.PubSub, state.topic, :terminal_exited)
    {:noreply, state}
  end

  def handle_info({:EXIT, pty, _reason}, %{pty: pty} = state) do
    {:stop, :normal, %{state | pty: nil}}
  end

  def handle_info({:EXIT, _other, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.pty, do: PTY.kill(state.pty, 15)
    :ok
  end

  defp setup_claude_window(_session_name, _cwd, nil), do: :ok

  defp setup_claude_window(session_name, cwd, claude_session_id) do
    window = "#{session_name}:claude-code"

    unless Tmux.window_exists?(window) do
      claude_cmd = build_claude_resume_cmd(claude_session_id)

      cmd =
        "clear && echo '# run the following command to resume the claude code session:' && " <>
          "echo '# #{claude_cmd}' && exec $SHELL"

      Tmux.new_window(session_name, name: "claude-code", cwd: cwd)
      Tmux.send_keys(window, cmd)

      System.cmd("tmux", ["select-window", "-t", "#{session_name}:1"], stderr_to_stdout: true)
    end
  end

  defp build_claude_resume_cmd(session_id) do
    parts = ["claude --resume #{session_id}"]

    parts =
      case ClaudeCode.Plugin.list() do
        {:ok, plugins} ->
          plugins
          |> Enum.filter(&(&1.enabled && &1.install_path))
          |> Enum.reduce(parts, fn plugin, acc ->
            acc ++ ["--plugin-dir #{plugin.install_path}"]
          end)

        _ ->
          parts
      end

    parts = parts ++ ["--setting-sources user,project"]

    Enum.join(parts, " ")
  end
end
