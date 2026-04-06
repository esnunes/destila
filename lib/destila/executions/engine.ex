defmodule Destila.Executions.Engine do
  @moduledoc """
  Central orchestration engine for workflow phase transitions.

  The Engine is responsible for:
  - Advancing workflows to the next phase
  - Routing phase updates to `AI.Conversation` and acting on the result
  - Updating phase execution and workflow session status
  - Broadcasting state changes via PubSub

  AI conversation mechanics (enqueuing workers, saving messages, parsing
  AI responses) are handled by `Destila.AI.Conversation`.

  The Engine writes to both `phase_executions` (for execution history) and
  `workflow_sessions.phase_status` (for classification and UI rendering).
  """

  alias Destila.{AI, Executions, Workflows}

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
  Kicks off the first phase of a newly created workflow session.

  Unlike `advance_to_next/1`, which transitions *from* a completed phase,
  this starts the session's `current_phase` in place — creating the phase
  execution and calling `AI.Conversation.phase_start/1` so workers get enqueued.
  """
  def start_session(ws) do
    phase = ws.current_phase
    {:ok, pe} = Executions.ensure_phase_execution(ws, phase)
    AI.Conversation.phase_start(ws)

    # Reload to check if an inline worker already advanced past this phase.
    reloaded = Workflows.get_workflow_session!(ws.id)

    if reloaded.current_phase == phase do
      Executions.start_phase(pe, :processing)
      Workflows.update_workflow_session(reloaded, %{phase_status: :processing})
    end
  end

  @doc """
  Retries the current phase by re-running `AI.Conversation.phase_start/1`.

  Follows the phase's session strategy:
  - `:resume` — stops the running ClaudeSession (prompt may be re-sent by the worker)
  - `:new` — stops the ClaudeSession and creates a fresh AI session

  Updates both phase execution and workflow session status.
  Returns `{:ok, ws}` on success, or `:noop` if the phase is already processing.
  """
  def phase_retry(workflow_session_id) when is_binary(workflow_session_id) do
    ws = Workflows.get_workflow_session!(workflow_session_id)
    phase_retry(ws)
  end

  def phase_retry(ws) do
    if ws.phase_status == :processing do
      :noop
    else
      handle_retry(ws)
    end
  end

  @doc """
  Routes a phase update to `AI.Conversation` and acts on the result.

  Called by `AiQueryWorker` after an AI response, or by `WorkflowRunnerLive`
  when the user sends a message. `AI.Conversation.phase_update/2` processes
  the params and returns a status the Engine uses to update state.
  """
  def phase_update(workflow_session_id, _phase, %{setup_step_completed: _} = params) do
    ws = Workflows.get_workflow_session!(workflow_session_id)

    case Destila.Workflows.Setup.update(ws, params) do
      :setup_complete ->
        {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: nil})
        start_session(ws)

      :processing ->
        Workflows.update_workflow_session(ws, %{phase_status: :setup})
    end
  end

  def phase_update(workflow_session_id, phase, params) do
    ws = Workflows.get_workflow_session!(workflow_session_id)

    case AI.Conversation.phase_update(%{ws | current_phase: phase}, params) do
      :processing ->
        case Executions.get_current_phase_execution(ws.id) do
          nil ->
            :ok

          pe when pe.status in [:awaiting_input, :awaiting_confirmation] ->
            Executions.process_phase(pe)

          _pe ->
            :ok
        end

        Workflows.update_workflow_session(ws, %{phase_status: :processing})

      :awaiting_input ->
        handle_awaiting_input(ws)

      :phase_complete ->
        advance_to_next(ws)

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

  defp handle_suggest_advance(ws) do
    # Update phase execution to awaiting_confirmation
    case Executions.get_current_phase_execution(ws.id) do
      nil -> :ok
      pe -> Executions.await_confirmation(pe, nil)
    end

    # Write to both old and new state
    Workflows.update_workflow_session(ws, %{phase_status: :advance_suggested})
  end

  defp handle_awaiting_input(ws) do
    # Update phase execution status
    case Executions.get_current_phase_execution(ws.id) do
      nil ->
        :ok

      pe when pe.status == :processing ->
        Executions.await_input(pe)

      _pe ->
        :ok
    end

    Workflows.update_workflow_session(ws, %{phase_status: :awaiting_input})
  end

  defp transition_to_phase(ws, next_phase) do
    # Get or create phase execution for the new phase (idempotent to handle concurrent calls)
    {:ok, pe} = Executions.ensure_phase_execution(ws, next_phase)

    # Update current_phase BEFORE starting the phase so that any inline
    # worker execution (Oban testing mode) sees the correct state.
    {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next_phase})

    # Delegate phase startup to the workflow. In test/inline mode, this may
    # trigger a full worker execution chain (including nested transitions).
    AI.Conversation.phase_start(ws)

    # Reload to check if a nested transition (from an inline worker auto-advancing)
    # has already moved past this phase. If so, skip the status update.
    reloaded = Workflows.get_workflow_session!(ws.id)

    if reloaded.current_phase == next_phase do
      Executions.start_phase(pe, :processing)
      Workflows.update_workflow_session(reloaded, %{phase_status: :processing})
    end
  end

  defp handle_retry(ws) do
    phase = ws.current_phase

    # Stop the running ClaudeSession for all strategies
    AI.ClaudeSession.stop_for_workflow_session(ws.id)

    # Apply the phase's session strategy (create fresh AI session if :new)
    AI.Conversation.handle_session_strategy(ws, phase)

    # Reload from DB to get fresh state after stopping the session
    ws = Workflows.get_workflow_session!(ws.id)
    AI.Conversation.phase_start(ws)

    case Executions.get_current_phase_execution(ws.id) do
      nil ->
        :ok

      pe when pe.status in [:completed, :skipped, :processing] ->
        :ok

      pe when pe.status == :awaiting_confirmation ->
        {:ok, pe} = Executions.reject_completion(pe)
        Executions.process_phase(pe)

      pe ->
        Executions.process_phase(pe)
    end

    Workflows.update_workflow_session(ws, %{phase_status: :processing})
  end

  defp complete_current_phase_execution(ws) do
    case Executions.get_current_phase_execution(ws.id) do
      nil ->
        :ok

      pe when pe.status in [:completed, :skipped] ->
        :ok

      pe when pe.status == :pending ->
        {:ok, pe} = Executions.start_phase(pe)
        Executions.complete_phase(pe)

      pe when pe.status in [:awaiting_input, :failed] ->
        {:ok, pe} = Executions.process_phase(pe)
        Executions.complete_phase(pe)

      pe ->
        # processing, awaiting_confirmation — both can transition directly to completed
        Executions.complete_phase(pe)
    end
  end
end
