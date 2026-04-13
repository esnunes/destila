defmodule Destila.Terminal.Server do
  use GenServer

  defstruct [:pty, :topic, :cols, :rows]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def write(server, data), do: GenServer.cast(server, {:write, data})
  def resize(server, cols, rows), do: GenServer.cast(server, {:resize, cols, rows})

  require Logger

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cwd = Keyword.fetch!(opts, :cwd)
    topic = Keyword.fetch!(opts, :topic)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)

    script = build_tmux_command(opts)

    Logger.info(
      "Terminal starting: /usr/bin/env TERM=xterm-256color COLORTERM=truecolor /bin/sh -c #{inspect(script)}"
    )

    {:ok, pty} =
      ExPTY.spawn(
        "/usr/bin/env",
        [
          "TERM=xterm-256color",
          "COLORTERM=truecolor",
          "/bin/sh",
          "-c",
          script
        ],
        cwd: cwd,
        cols: cols,
        rows: rows,
        closeFDs: true
      )

    # ExPTY uses GenServer.start (not start_link), so link manually to ensure
    # the PTY process is cleaned up if Terminal.Server is killed without terminate/2
    Process.link(pty)

    ExPTY.on_data(pty, fn _pty, _pid, data ->
      Phoenix.PubSub.broadcast(Destila.PubSub, topic, {:terminal_output, data})
    end)

    ExPTY.on_exit(pty, fn _pty, _pid, _exit_code, _signal ->
      Phoenix.PubSub.broadcast(Destila.PubSub, topic, :terminal_exited)
    end)

    {:ok, %__MODULE__{pty: pty, topic: topic, cols: cols, rows: rows}}
  end

  @impl true
  def handle_cast({:write, data}, state) do
    ExPTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    ExPTY.resize(state.pty, cols, rows)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:EXIT, pty, _reason}, %{pty: pty} = state) do
    {:stop, :normal, %{state | pty: nil}}
  end

  def handle_info({:EXIT, _other, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.pty, do: ExPTY.kill(state.pty, 15)
    :ok
  end

  defp build_tmux_command(opts) do
    session_name = Keyword.get(opts, :session_name, "destila")
    cwd = Keyword.fetch!(opts, :cwd)
    claude_session_id = Keyword.get(opts, :claude_session_id)

    session = escape_shell(session_name)
    dir = escape_shell(cwd)

    attach = "tmux attach -t #{session}"

    create =
      if claude_session_id do
        claude_cmd = build_claude_resume_cmd(claude_session_id)

        claude_window_cmd =
          "clear && echo '# run the following command to resume the claude code session:' && " <>
            "echo '# #{claude_cmd}' && exec $SHELL"

        "tmux new-session -s #{session} -n shell -c #{dir} \\; " <>
          "new-window -n 'claude code' -c #{dir} #{escape_shell(claude_window_cmd)} \\; " <>
          "select-window -t 1"
      else
        "tmux new-session -s #{session} -n shell -c #{dir}"
      end

    "tmux has-session -t #{session} 2>/dev/null && #{attach} || #{create}"
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

  defp escape_shell(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
