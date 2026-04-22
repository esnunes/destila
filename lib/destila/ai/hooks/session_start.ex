defmodule Destila.AI.Hooks.SessionStart do
  @moduledoc """
  Claude Code `SessionStart` hook that re-injects the current phase's
  initial prompt after a compaction (`source: "compact"`).

  The hook looks up the workflow session from the Claude session id,
  recomputes the phase's initial prompt, and returns it as
  `additional_context` wrapped in `<initial-prompt>...</initial-prompt>`
  tags so the agent still sees its kickoff instructions once compaction
  has collapsed the conversation history.

  Any other `SessionStart` source (`"startup"`, `"resume"`, `"clear"`)
  and any resolution failure (unknown session, missing workflow session,
  out-of-range phase, raise from the prompt function) falls through to
  `:ok` so session startup is never blocked.
  """

  @behaviour ClaudeCode.Hook

  require Logger

  alias Destila.{AI, Workflows}

  @reference_line "In the `<initial-prompt>` you can find the initial user prompt for reference."

  @impl true
  def call(%{hook_event_name: "SessionStart", source: "compact"} = input, _tool_use_id) do
    session_id = Map.get(input, :session_id)

    with ai_session when not is_nil(ai_session) <-
           AI.get_ai_session_by_claude_session_id(session_id),
         ws when not is_nil(ws) <-
           Workflows.get_workflow_session(ai_session.workflow_session_id),
         phase when not is_nil(phase) <- get_phase(ws) do
      {:ok, additional_context: build_context(phase.initial_prompt.(ws))}
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("SessionStart hook failed: #{Exception.message(e)}")
      :ok
  end

  def call(_input, _tool_use_id), do: :ok

  defp get_phase(%{workflow_type: workflow_type, current_phase: phase_number})
       when is_integer(phase_number) and phase_number > 0 do
    workflow_type
    |> Workflows.phases()
    |> Enum.at(phase_number - 1)
  end

  defp get_phase(_), do: nil

  defp build_context(phase_prompt) do
    """
    The conversation was just compacted. Treat the block below as the \
    active phase's original kickoff instructions:

    <initial-prompt>
    #{phase_prompt}
    </initial-prompt>

    #{@reference_line}
    """
  end
end
