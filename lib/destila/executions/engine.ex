defmodule Destila.Executions.Engine do
  @moduledoc """
  Central orchestration engine for workflow phase transitions.

  The Engine is responsible for:
  - Advancing workflows to the next phase
  - Routing phase updates to `AI.Conversation` and acting on the result
  - Updating phase execution status
  - Broadcasting state changes via PubSub

  AI conversation mechanics (enqueuing workers, saving messages, parsing
  AI responses) are handled by `Destila.AI.Conversation`.
  """

  alias Destila.{AI, Executions, Workflows}
  alias Destila.Workflows.Session

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

    if pe = Executions.get_current_phase_execution(ws.id) do
      Executions.complete_phase(pe)
    end

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
    {:ok, _pe} = Executions.ensure_phase_execution(ws, phase)
    AI.Conversation.phase_start(ws)

    # Reload to check if an inline worker already advanced past this phase.
    reloaded = Workflows.get_workflow_session!(ws.id)

    if reloaded.current_phase == phase do
      Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
    end
  end

  @doc """
  Retries the current phase by re-running `AI.Conversation.phase_start/1`.

  Follows the phase's session strategy:
  - `:resume` — stops the running ClaudeSession (prompt may be re-sent by the worker)
  - `:new` — stops the ClaudeSession and creates a fresh AI session

  Updates phase execution status.
  Returns `{:ok, ws}` on success, or `:noop` if the phase is already processing.
  """
  def phase_retry(workflow_session_id) when is_binary(workflow_session_id) do
    ws = Workflows.get_workflow_session!(workflow_session_id)
    phase_retry(ws)
  end

  def phase_retry(ws) do
    if Session.phase_status(ws) == :processing do
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
  @setup_keys ~w(repo_sync worktree)

  def phase_update(workflow_session_id, _phase, %{setup_step_completed: _} = _params) do
    ws = Workflows.get_workflow_session!(workflow_session_id)
    metadata = Workflows.get_metadata(ws.id)

    setup_keys =
      metadata
      |> Map.keys()
      |> Enum.filter(&(&1 in @setup_keys))

    if setup_keys == [] ||
         Enum.all?(setup_keys, &(get_in(metadata, [&1, "status"]) == "completed")) do
      start_session(ws)
    else
      # Setup status is derived from no PE existing — no write needed.
      # Broadcast so the LiveView refreshes setup step progress.
      Workflows.broadcast({:ok, ws}, :workflow_session_updated)
    end
  end

  def phase_update(workflow_session_id, phase, params) do
    ws = Workflows.get_workflow_session!(workflow_session_id)

    case AI.Conversation.phase_update(%{ws | current_phase: phase}, params) do
      :processing ->
        if pe = Executions.get_current_phase_execution(ws.id) do
          Executions.process_phase(pe)
        end

        Workflows.broadcast({:ok, ws}, :workflow_session_updated)

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
    Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})
  end

  defp handle_suggest_advance(ws) do
    if pe = Executions.get_current_phase_execution(ws.id) do
      Executions.await_confirmation(pe, nil)
    end

    Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end

  defp handle_awaiting_input(ws) do
    if pe = Executions.get_current_phase_execution(ws.id) do
      Executions.await_input(pe)
    end

    Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end

  defp transition_to_phase(ws, next_phase) do
    {:ok, _pe} = Executions.ensure_phase_execution(ws, next_phase)
    {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next_phase})

    AI.Conversation.phase_start(ws)

    reloaded = Workflows.get_workflow_session!(ws.id)

    if reloaded.current_phase == next_phase do
      Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
    end
  end

  defp handle_retry(ws) do
    phase = ws.current_phase

    AI.ClaudeSession.stop_for_workflow_session(ws.id)
    AI.Conversation.handle_session_strategy(ws, phase)

    ws = Workflows.get_workflow_session!(ws.id)
    AI.Conversation.phase_start(ws)

    case Executions.get_current_phase_execution(ws.id) do
      nil ->
        :ok

      pe when pe.status == :awaiting_confirmation ->
        {:ok, pe} = Executions.reject_completion(pe)
        Executions.process_phase(pe)

      pe ->
        Executions.process_phase(pe)
    end

    Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end
end
