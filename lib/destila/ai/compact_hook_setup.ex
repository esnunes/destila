defmodule Destila.AI.CompactHookSetup do
  @moduledoc """
  Installs a Claude Code `SessionStart(compact)` hook inside a workflow
  session's worktree so the current phase prompt is re-injected after
  context compaction.

  On each phase start, `install/2` writes three files under the worktree:

    * `.claude/destila/initial_prompt.txt` — the wrapped phase prompt
    * `.claude/hooks/reinject_initial_prompt.sh` — the shipped hook script
    * `.claude/settings.json` — a SessionStart(compact) hook registration

  The hook script reads the prompt file and prints it followed by a short
  reference sentence. Claude Code appends the script's stdout to the
  post-compact context, restoring the phase instructions that the summary
  may have dropped.
  """

  require Logger

  @prompt_subpath ".claude/destila/initial_prompt.txt"
  @hook_subpath ".claude/hooks/reinject_initial_prompt.sh"
  @settings_subpath ".claude/settings.json"
  @hook_command ".claude/hooks/reinject_initial_prompt.sh"
  @hook_script_name "reinject_initial_prompt.sh"

  @doc """
  Writes the wrapped phase prompt, hook script, and `.claude/settings.json`
  into the given worktree. Safe to call repeatedly — each call overwrites
  the prompt file and re-installs the hook script; settings.json is merged.

  Returns `:ok`. I/O failures are logged but do not raise so a phase start
  is never blocked by hook-setup problems.
  """
  def install(nil, _wrapped_prompt), do: :ok

  def install(worktree_path, wrapped_prompt)
      when is_binary(worktree_path) and is_binary(wrapped_prompt) do
    try do
      write_prompt_file!(worktree_path, wrapped_prompt)
      install_hook_script!(worktree_path)
      install_settings!(worktree_path)
      :ok
    rescue
      error ->
        Logger.warning(
          "CompactHookSetup.install/2 failed for #{inspect(worktree_path)}: " <>
            Exception.message(error)
        )

        :ok
    end
  end

  @doc """
  Pure merge of our `SessionStart(compact)` hook entry into a pre-existing
  settings map. Preserves all other keys and hook events. If our entry is
  already present (same command) it is not duplicated.
  """
  def merge_settings(existing, hook_entry \\ default_hook_entry())

  def merge_settings(existing, hook_entry) when is_map(existing) do
    hooks = Map.get(existing, "hooks", %{})
    session_start = Map.get(hooks, "SessionStart", [])

    session_start =
      if contains_hook_entry?(session_start, hook_entry) do
        session_start
      else
        session_start ++ [hook_entry]
      end

    Map.put(existing, "hooks", Map.put(hooks, "SessionStart", session_start))
  end

  def merge_settings(_non_map, hook_entry), do: default_settings(hook_entry)

  @doc """
  The default settings payload when no prior `settings.json` exists.
  """
  def default_settings(hook_entry \\ default_hook_entry()) do
    %{"hooks" => %{"SessionStart" => [hook_entry]}}
  end

  @doc """
  The `SessionStart(compact)` hook entry registering our shipped script.
  """
  def default_hook_entry do
    %{
      "matcher" => "compact",
      "hooks" => [%{"type" => "command", "command" => @hook_command}]
    }
  end

  # --- Private ---

  defp write_prompt_file!(worktree_path, wrapped_prompt) do
    path = Path.join(worktree_path, @prompt_subpath)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, wrapped_prompt)
  end

  defp install_hook_script!(worktree_path) do
    dest = Path.join(worktree_path, @hook_subpath)
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(source_script_path(), dest)
    File.chmod!(dest, 0o755)
  end

  defp install_settings!(worktree_path) do
    path = Path.join(worktree_path, @settings_subpath)
    File.mkdir_p!(Path.dirname(path))

    merged =
      case File.read(path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, existing} ->
              merge_settings(existing)

            {:error, _} ->
              Logger.warning("CompactHookSetup: overwriting invalid JSON at #{path}")

              default_settings()
          end

        {:error, :enoent} ->
          default_settings()

        {:error, reason} ->
          Logger.warning(
            "CompactHookSetup: failed to read #{path} (#{inspect(reason)}); overwriting"
          )

          default_settings()
      end

    File.write!(path, Jason.encode!(merged, pretty: true))
  end

  defp contains_hook_entry?(session_start, %{"hooks" => [%{"command" => cmd}]}) do
    Enum.any?(session_start, fn
      %{"hooks" => hooks} when is_list(hooks) ->
        Enum.any?(hooks, fn
          %{"command" => ^cmd} -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  defp source_script_path do
    Path.join([:code.priv_dir(:destila), "hooks", @hook_script_name])
  end
end
