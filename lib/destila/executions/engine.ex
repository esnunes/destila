defmodule Destila.Executions.Engine do
  @moduledoc """
  Central orchestration engine for workflow phase transitions.

  Consolidates transition logic that was previously scattered across
  `WorkflowRunnerLive`, `AiConversationPhase`, and `AiQueryWorker`
  into a single, testable module.

  The Engine is responsible for:
  - Advancing workflows to the next phase
  - Handling phase completion results (from AI or user)
  - Updating phase execution and workflow session status
  - Broadcasting state changes via PubSub

  Phase startup logic (e.g. enqueuing workers, creating AI sessions) is
  delegated to the workflow module via `phase_start_action/2`.

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
    current_phase = ws.current_phase
    next_phase = current_phase + 1
    total = ws.total_phases

    # Complete current phase execution if it exists
    complete_current_phase_execution(ws)

    if next_phase > total do
      complete_workflow(ws)
    else
      transition_to_phase(ws, next_phase)
    end
  end

  @doc """
  Handles the result from an AI query for a phase.

  Called by `AiQueryWorker` after processing an AI response.
  Determines the next action based on the session action in the response.
  """
  def handle_phase_result(workflow_session_id, phase, session_action) do
    ws = Workflows.get_workflow_session!(workflow_session_id)

    case session_action do
      %{action: "phase_complete"} ->
        handle_auto_advance(ws, phase)

      %{action: "suggest_phase_complete"} ->
        handle_suggest_advance(ws, phase)

      _ ->
        handle_continue_conversation(ws)
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

  defp handle_suggest_advance(ws, _phase) do
    # Update phase execution to awaiting_confirmation
    case Executions.get_current_phase_execution(ws.id) do
      nil -> :ok
      pe -> Executions.stage_completion(pe, nil)
    end

    # Write to both old and new state
    Workflows.update_workflow_session(ws, %{phase_status: :advance_suggested})
  end

  defp handle_continue_conversation(ws) do
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
          Workflows.update_workflow_session(reloaded, %{phase_status: :generating})

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
