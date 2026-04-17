defmodule Destila.Terminal.Tmux do
  @moduledoc """
  Low-level tmux operations shared by Terminal.Server and ServiceManager.
  """

  @doc """
  Returns the tmux session name for a workflow session, derived from its id.
  The id is stable across title edits, so the tmux session never drifts
  out of sync with the workflow session.
  """
  def session_name(ws), do: "ws-#{ws.id}"

  @doc """
  Checks whether a tmux session exists.
  """
  def has_session?(name) do
    match?({_, 0}, System.cmd("tmux", ["has-session", "-t", name], stderr_to_stdout: true))
  end

  @doc """
  Creates a tmux session if it doesn't already exist.
  Sets renumber-windows off to preserve fixed window indices.
  """
  def ensure_session(name, cwd) do
    unless has_session?(name) do
      dir = cwd || System.tmp_dir!()

      System.cmd("tmux", [
        "new-session",
        "-d",
        "-s",
        name,
        "-n",
        "shell",
        "-c",
        dir
      ])

      System.cmd("tmux", ["set-option", "-t", name, "renumber-windows", "off"])
    end

    :ok
  end

  @doc """
  Creates a new window at the given target (e.g. "session" or "session:9").
  Options: `:cwd`, `:name`.
  """
  def new_window(target, opts \\ []) do
    name_args = if opts[:name], do: ["-n", opts[:name]], else: []
    cwd_args = if opts[:cwd], do: ["-c", opts[:cwd]], else: []

    System.cmd(
      "tmux",
      ["new-window", "-t", target] ++ name_args ++ cwd_args,
      stderr_to_stdout: true
    )
  end

  @doc """
  Sends a command string to a tmux target followed by Enter.
  """
  def send_keys(target, command) do
    System.cmd("tmux", ["send-keys", "-t", target, command, "Enter"], stderr_to_stdout: true)
  end

  @doc """
  Kills the window at the given target.
  """
  def kill_window(target) do
    System.cmd("tmux", ["kill-window", "-t", target], stderr_to_stdout: true)
  end

  @doc """
  Checks whether a window exists at the given target.
  """
  def window_exists?(target) do
    match?({_, 0}, System.cmd("tmux", ["list-panes", "-t", target], stderr_to_stdout: true))
  end

  @doc """
  Sends SIGTERM to the process group of each pane in the target window.
  """
  def term_panes(target) do
    case System.cmd("tmux", ["list-panes", "-t", target, "-F", ~S"#{pane_pid}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.each(fn pid_str ->
          System.cmd("kill", ["-TERM", "--", "-#{pid_str}"], stderr_to_stdout: true)
        end)

      _ ->
        :ok
    end
  end

  @doc """
  Escapes a string for safe use in shell commands.
  """
  def escape_shell(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
