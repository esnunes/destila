defmodule Destila.AI.SessionConfig do
  @moduledoc """
  Resolves ClaudeCode session options for a workflow session and phase.

  Reads phase definitions and AI session records to build the option keyword
  list passed to `ClaudeSession.start_link/1`.
  """

  @doc """
  Builds ClaudeCode session options for a workflow session and phase.

  Resolves the session strategy from the workflow module, adds `:resume`
  and `:cwd` from the AI session record, and merges any phase-provided options.

  Additional base options (e.g. `timeout_ms`) can be passed and will be included.
  """
  def session_opts_for_workflow(workflow_session, phase, base_opts \\ []) do
    phase_def = Enum.at(Destila.Workflows.phases(workflow_session.workflow_type), phase - 1)

    strategy_opts =
      case phase_def do
        %Destila.Workflows.Phase{session_strategy: {_action, opts}} -> opts
        _ -> []
      end

    ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)

    opts = base_opts

    opts =
      if ai_session do
        Keyword.put(opts, :ai_session_id, ai_session.id)
      else
        opts
      end

    opts =
      if ai_session && ai_session.claude_session_id do
        Keyword.put(opts, :resume, ai_session.claude_session_id)
      else
        opts
      end

    opts =
      if ai_session && ai_session.worktree_path do
        Keyword.put(opts, :cwd, ai_session.worktree_path)
      else
        opts
      end

    # Forward allowed_tools from phase definition if present
    opts =
      case phase_def do
        %Destila.Workflows.Phase{allowed_tools: tools} when tools != [] ->
          Keyword.put(opts, :allowed_tools, tools)

        _ ->
          opts
      end

    merge_phase_opts(opts, strategy_opts)
  end

  @doc """
  Merges phase-provided ClaudeCode options with base session options.
  MCP servers are map-merged; all other options use standard keyword merge.
  """
  def merge_phase_opts(base_opts, phase_opts) do
    {phase_mcp, phase_rest} = Keyword.pop(phase_opts, :mcp_servers, %{})
    {base_mcp, base_rest} = Keyword.pop(base_opts, :mcp_servers, %{})

    merged = Keyword.merge(base_rest, phase_rest)

    merged_mcp = Map.merge(base_mcp, phase_mcp)

    if merged_mcp == %{} do
      merged
    else
      Keyword.put(merged, :mcp_servers, merged_mcp)
    end
  end
end
