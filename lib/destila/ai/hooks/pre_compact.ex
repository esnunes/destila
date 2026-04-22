defmodule Destila.AI.Hooks.PreCompact do
  @moduledoc """
  Claude Code `PreCompact` hook that re-injects the current phase's initial
  prompt into the post-compaction context.

  Before compaction fires, we look up the workflow session from the Claude
  session id, recompute the phase's initial prompt, and return it as
  `custom_instructions` wrapped in `<initial-prompt>...</initial-prompt>`
  tags. The compaction summarizer is instructed to preserve the block
  verbatim so the agent still sees the original kickoff instructions after
  the conversation is summarized.

  Any resolution failure (unknown session, missing workflow session, phase
  out of range, prompt function raise) is swallowed to `:ok` so compaction
  proceeds unchanged.
  """

  @behaviour ClaudeCode.Hook

  require Logger

  alias Destila.{AI, Workflows}

  @reference_line "In the `<initial-prompt>` you can find the initial user prompt for reference."

  @impl true
  def call(%{hook_event_name: "PreCompact"} = input, _tool_use_id) do
    session_id = Map.get(input, :session_id)
    incoming = Map.get(input, :custom_instructions)

    with ai_session when not is_nil(ai_session) <-
           AI.get_ai_session_by_claude_session_id(session_id),
         ws when not is_nil(ws) <-
           Workflows.get_workflow_session(ai_session.workflow_session_id),
         phase when not is_nil(phase) <- get_phase(ws),
         %{initial_prompt: prompt_fn} when is_function(prompt_fn, 1) <- phase do
      {:ok, custom_instructions: build_instructions(prompt_fn.(ws), incoming)}
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("PreCompact hook failed: #{Exception.message(e)}")
      :ok
  end

  # Catch-all for non-PreCompact events or malformed input — hooks are shared
  # infrastructure and must never block compaction, so we no-op instead of
  # raising on unexpected shapes.
  def call(_input, _tool_use_id), do: :ok

  defp get_phase(%{workflow_type: workflow_type, current_phase: phase_number})
       when is_integer(phase_number) and phase_number > 0 do
    workflow_type
    |> Workflows.phases()
    |> Enum.at(phase_number - 1)
  end

  defp get_phase(_), do: nil

  defp build_instructions(phase_prompt, incoming) do
    base = """
    Preserve the following block verbatim in the compacted context so the \
    agent can still see the original phase instructions after compaction:

    <initial-prompt>
    #{phase_prompt}
    </initial-prompt>

    After the compaction summary, include this reminder line for the agent: \
    "#{@reference_line}"
    """

    case incoming do
      str when is_binary(str) and str != "" -> str <> "\n\n" <> base
      _ -> base
    end
  end
end
