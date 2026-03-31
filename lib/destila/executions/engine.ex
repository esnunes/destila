defmodule Destila.Executions.Engine do
  @moduledoc """
  Central orchestration engine for workflow phase transitions.

  The Engine is responsible for:
  - Advancing workflows to the next phase
  - Routing phase updates to the workflow and acting on the result
  - Updating phase execution and workflow session status
  - Broadcasting state changes via PubSub

  Phase-specific logic (e.g. enqueuing workers, saving messages, parsing
  AI responses) is delegated to the workflow module via callbacks.

  During the migration period, the Engine writes to both `phase_executions`
  AND `workflow_sessions.phase_status` to maintain backwards compatibility.
  """

  alias Destila.{Executions, Workflows}

  @doc """
  Advances the workflow to the next phase after the current phase completes.

  Handles:
  - Completing the workflow if all phases are done
  - Creating phase execution records
  - Delegating phase startup to the workflow
  """
  def advance_to_next(workflow_session_id) when is_binary(workflow_session_id) do
    ws = Workflows.get_workflow_session!(workflow_session_id)
    advance_to_next(ws)
  end

  def advance_to_next(ws) do
    next_phase = ws.current_phase + 1

    # Complete current phase execution if it exists
    complete_current_phase_execution(ws)

    if next_phase > ws.total_phases do
      complete_workflow(ws)
    else
      transition_to_phase(ws, next_phase)
    end
  end

  @doc """
  Routes a phase update to the workflow and acts on the result.

  Called by `AiQueryWorker` after an AI response, or by `AiConversationPhase`
  when the user sends a message. The workflow's `phase_update_action/3`
  processes the params and returns a status the Engine uses to update state.
  """
  def phase_update(workflow_session_id, phase, params) do
    ws = Workflows.get_workflow_session!(workflow_session_id)

    case Workflows.phase_update_action(%{ws | current_phase: phase}, params) do
      :processing ->
        Workflows.update_workflow_session(ws, %{phase_status: :processing})

      :awaiting_input ->
        handle_awaiting_input(ws)

      :phase_complete ->
        handle_auto_advance(ws, phase)

      :suggest_phase_complete ->
        handle_suggest_advance(ws)
    end
  end

  # --- Private ---

  defp complete_workflow(ws) do
    Workflows.update_workflow_session(ws, %{
      done_at: DateTime.utc_now(),
      phase_status: nil
    })
  end

  defp handle_auto_advance(ws, current_phase) do
    next_phase = current_phase + 1

    # Complete current phase execution
    complete_current_phase_execution(ws)

    if next_phase > ws.total_phases do
      complete_workflow(ws)
    else
      transition_to_phase(ws, next_phase)
    end
  end

  defp handle_suggest_advance(ws) do
    # Update phase execution to awaiting_confirmation
    case Executions.get_current_phase_execution(ws.id) do
      nil -> :ok
      pe -> Executions.stage_completion(pe, nil)
    end

    # Write to both old and new state
    Workflows.update_workflow_session(ws, %{phase_status: :advance_suggested})
  end

  defp handle_awaiting_input(ws) do
    # Update phase execution status
    case Executions.get_current_phase_execution(ws.id) do
      nil ->
        :ok

      pe when pe.status == "processing" ->
        Executions.update_phase_execution_status(pe, "awaiting_input")

      _pe ->
        :ok
    end

    Workflows.update_workflow_session(ws, %{phase_status: :conversing})
  end

  defp transition_to_phase(ws, next_phase) do
    # Get or create phase execution for the new phase (idempotent to handle concurrent calls)
    {:ok, pe} = Executions.ensure_phase_execution(ws, next_phase)

    # Update current_phase BEFORE starting the phase so that any inline
    # worker execution (Oban testing mode) sees the correct state.
    {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next_phase})

    # Delegate phase startup to the workflow. In test/inline mode, this may
    # trigger a full worker execution chain (including nested transitions).
    status = Workflows.phase_start_action(ws)

    # Reload to check if a nested transition (from an inline worker auto-advancing)
    # has already moved past this phase. If so, skip the status update.
    reloaded = Workflows.get_workflow_session!(ws.id)

    if reloaded.current_phase == next_phase do
      case status do
        :processing ->
          Executions.start_phase(pe, "processing")
          Workflows.update_workflow_session(reloaded, %{phase_status: :processing})

        :awaiting_input ->
          Executions.start_phase(pe, "awaiting_input")
      end
    end
  end

  defp complete_current_phase_execution(ws) do
    case Executions.get_current_phase_execution(ws.id) do
      nil -> :ok
      pe when pe.status in ["completed", "skipped"] -> :ok
      pe -> Executions.complete_phase(pe)
    end
  end
end
