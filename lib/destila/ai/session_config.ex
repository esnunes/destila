defmodule Destila.AI.SessionConfig do
  @moduledoc """
  Resolves ClaudeCode session options for a workflow session and phase.

  The phase's `AISessionGroup` contributes its assembled `skills` and its
  `allowed_tools` descriptions as `:append_system_prompt` (appended to Claude
  Code's built-in system prompt), and its `allowed_tools` list as
  `:allowed_tools`. When the group does not declare `allowed_tools`, the
  module-level `@default_allowed_tools` list is used for both, so the
  documented usage stays in sync with the tools the agent can actually call.
  The AI session record contributes `:resume` and `:cwd`.

  Every session also registers `Destila.AI.Hooks.SessionStart` on the
  `SessionStart` event so the current phase's initial prompt is re-injected
  into the agent's context after a compaction (`source: "compact"`).

  Every session also defaults to `--effort xhigh` (passed via `:extra_args`
  since the SDK's typed `:effort` option doesn't yet expose the `xhigh` tier
  the CLI supports). Callers can override by passing their own
  `extra_args: %{"--effort" => "..."}`.

  Every session also defaults to the `claude-opus-4-7` model. Callers can
  override by passing their own `model: "..."`.
  """

  alias Destila.AI.{Hooks, Tools}
  alias Destila.Workflows
  alias Destila.Workflows.Skills

  @default_allowed_tools [
    "Read",
    "Grep",
    "Glob",
    "WebFetch",
    "Skill",
    "Bash(git log:*)",
    "Bash(git show:*)",
    "mcp__destila__ask_user_question",
    "mcp__destila__session",
    "mcp__destila__service"
  ]

  # Built-in AskUserQuestion duplicates `mcp__destila__ask_user_question`; denying
  # it forces the agent to use the Destila tool, which is the one wired into the UI.
  @default_disallowed_tools ["AskUserQuestion"]

  # Routed through :extra_args because the SDK's typed :effort option (v0.36)
  # only accepts :low/:medium/:high/:max, while the CLI also accepts "xhigh".
  @default_effort "xhigh"
  @default_model "claude-opus-4-7"

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
    |> put_allowed_tools(group)
    |> put_disallowed_tools()
    |> put_append_system_prompt(group)
    |> put_ai_session(ai_session)
    |> put_resume(ai_session)
    |> put_cwd(ai_session)
    |> put_hooks()
    |> put_effort()
    |> put_model()
  end

  defp put_effort(opts) do
    extra_args =
      opts
      |> Keyword.get(:extra_args, %{})
      |> Map.put_new("--effort", @default_effort)

    Keyword.put(opts, :extra_args, extra_args)
  end

  defp put_model(opts), do: Keyword.put_new(opts, :model, @default_model)

  defp put_disallowed_tools(opts),
    do: Keyword.put_new(opts, :disallowed_tools, @default_disallowed_tools)

  defp put_append_system_prompt(opts, %{skills: skills}) do
    sections =
      [Skills.assemble_skills(skills), Tools.tool_descriptions(opts[:allowed_tools] || [])]
      |> Enum.reject(&(&1 == ""))

    case sections do
      [] -> opts
      parts -> Keyword.put(opts, :append_system_prompt, Enum.join(parts, "\n\n"))
    end
  end

  defp put_append_system_prompt(opts, _), do: opts

  defp put_allowed_tools(opts, %{allowed_tools: [_ | _] = tools}),
    do: Keyword.put_new(opts, :allowed_tools, tools)

  defp put_allowed_tools(opts, _),
    do: Keyword.put_new(opts, :allowed_tools, @default_allowed_tools)

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
