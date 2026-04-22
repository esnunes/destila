defmodule Destila.AI.SessionConfig do
  @moduledoc """
  Resolves ClaudeCode session options for a workflow session and phase.

  The phase's `AISessionGroup` contributes its assembled `skills` and its
  `allowed_tools` descriptions as `:append_system_prompt` (appended to Claude
  Code's built-in system prompt), and its `allowed_tools` list as
  `:allowed_tools`. The AI session record contributes `:resume` and `:cwd`.

  Every session also registers `Destila.AI.Hooks.SessionStart` on the
  `SessionStart` event so the current phase's initial prompt is re-injected
  into the agent's context after a compaction (`source: "compact"`).
  """

  alias Destila.AI.{Hooks, Tools}
  alias Destila.Workflows
  alias Destila.Workflows.Skills

  @doc """
  Builds ClaudeCode session options for a workflow session and phase.

  Adds `:append_system_prompt` (assembled group skills + tool descriptions) and
  `:allowed_tools` (group's tools) from the phase's AI session group, plus
  `:ai_session_id`, `:resume`, and `:cwd` from the AI session record. Always
  registers the `SessionStart` hook.

  Additional base options (e.g. `timeout_ms`) can be passed and will be included.
  """
  def session_opts_for_workflow(workflow_session, phase, base_opts \\ []) do
    group = Workflows.group_for_phase(workflow_session.workflow_type, phase)
    ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)

    base_opts
    |> put_append_system_prompt(group)
    |> put_allowed_tools(group)
    |> put_ai_session(ai_session)
    |> put_resume(ai_session)
    |> put_cwd(ai_session)
    |> put_hooks()
  end

  defp put_append_system_prompt(opts, %{skills: skills, allowed_tools: tools}) do
    sections =
      [Skills.assemble_skills(skills), Tools.tool_descriptions(tools)]
      |> Enum.reject(&(&1 == ""))

    case sections do
      [] -> opts
      parts -> Keyword.put(opts, :append_system_prompt, Enum.join(parts, "\n\n"))
    end
  end

  defp put_append_system_prompt(opts, _), do: opts

  defp put_allowed_tools(opts, %{allowed_tools: [_ | _] = tools}),
    do: Keyword.put(opts, :allowed_tools, tools)

  defp put_allowed_tools(opts, _), do: opts

  defp put_ai_session(opts, %{id: id}), do: Keyword.put(opts, :ai_session_id, id)
  defp put_ai_session(opts, _), do: opts

  defp put_resume(opts, %{claude_session_id: id}) when is_binary(id),
    do: Keyword.put(opts, :resume, id)

  defp put_resume(opts, _), do: opts

  defp put_cwd(opts, %{worktree_path: path}) when is_binary(path),
    do: Keyword.put(opts, :cwd, path)

  defp put_cwd(opts, _), do: opts

  defp put_hooks(opts),
    do: Keyword.put(opts, :hooks, %{SessionStart: [Hooks.SessionStart]})
end
