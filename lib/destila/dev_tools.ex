defmodule Destila.DevTools do
  @doc """
  Opens a Ghostty terminal with a tmux session at the given path.

  When a Claude session ID is provided, the shell prints a comment with
  the resume command. Reattaches to the existing tmux session if one with
  the same name already exists.

  Returns `:ok` or `{:error, reason}`.
  """
  def open_terminal(name, path, claude_session_id \\ nil) do
    session = escape_shell(name)
    dir = escape_shell(path)

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

    script = "tmux has-session -t #{session} 2>/dev/null && #{attach} || #{create}"
    shell = System.get_env("SHELL", "/bin/sh")
    tmux_cmd = "#{shell} -c #{escape_shell(script)}"

    case System.cmd("open", ["-na", "Ghostty.app", "--args", "--command=" <> tmux_cmd],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
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

  defp escape_shell(str), do: "'" <> String.replace(str, "'", "'\\''") <> "'"
end
