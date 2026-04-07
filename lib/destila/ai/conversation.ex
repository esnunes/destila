defmodule Destila.AI.Conversation do
  @moduledoc """
  Handles all AI conversation mechanics -- phase starts, user messages,
  AI results, and AI errors.

  The Engine calls this module directly instead of delegating to workflow
  modules. Workflow modules remain purely declarative.
  """

  alias Destila.{AI, Workflows}

  @doc """
  Starts a phase by reading the system prompt, handling session strategy,
  ensuring an AI session exists, and enqueuing the AI worker.

  Returns `:processing` or `:awaiting_input`.
  """
  def phase_start(ws) do
    phase_number = ws.current_phase
    %{system_prompt: prompt_fn} = get_phase(ws, phase_number)

    handle_session_strategy(ws, phase_number)
    ensure_ai_session(ws)
    query = prompt_fn.(ws)
    enqueue_ai_worker(ws, phase_number, query)
    :processing
  end

  @doc """
  Processes a phase update (user message, AI result, AI error, or unknown).

  Returns `:processing`, `:awaiting_input`, `:phase_complete`, or `:suggest_phase_complete`.
  """
  def phase_update(ws, %{message: message}) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      AI.create_message(ai_session.id, %{
        role: :user,
        content: message,
        phase: phase_number,
        workflow_session_id: ws.id
      })

      enqueue_ai_worker(ws, phase_number, message)
      :processing
    else
      :awaiting_input
    end
  end

  def phase_update(ws, %{ai_result: result}) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      response_text = AI.response_text(result)
      session_action = AI.extract_session_action(result)

      content =
        case session_action do
          %{message: msg} when is_binary(msg) and msg != "" -> msg
          _ -> response_text
        end

      AI.create_message(ai_session.id, %{
        role: :system,
        content: content,
        raw_response: result,
        phase: phase_number,
        workflow_session_id: ws.id
      })

      if result[:session_id] do
        AI.update_ai_session(ai_session, %{claude_session_id: result[:session_id]})
      end

      # Call optional workflow hook
      workflow_module = Workflows.workflow_module(ws.workflow_type)
      workflow_module.handle_response(ws, phase_number, response_text)

      case session_action do
        %{action: "phase_complete"} -> :phase_complete
        %{action: "suggest_phase_complete"} -> :suggest_phase_complete
        _ -> :awaiting_input
      end
    else
      :awaiting_input
    end
  end

  def phase_update(ws, %{ai_error: _reason}) do
    phase_number = ws.current_phase
    ai_session = AI.get_ai_session_for_workflow(ws.id)

    if ai_session do
      AI.create_message(ai_session.id, %{
        role: :system,
        content: "Something went wrong. Please try sending your message again.",
        phase: phase_number,
        workflow_session_id: ws.id
      })
    end

    :awaiting_input
  end

  def phase_update(_ws, _params), do: :awaiting_input

  @doc """
  Handles session strategy for a given phase.

  For `:new` -- stops the existing ClaudeSession and creates a fresh AI session.
  For `:resume` -- no-op.

  This is also used by `Engine.handle_retry/1` to apply the phase's strategy
  before restarting.
  """
  def handle_session_strategy(ws, phase_number) do
    case get_phase(ws, phase_number) do
      %{session_strategy: :new} ->
        AI.ClaudeSession.stop_for_workflow_session(ws.id)

        metadata = Workflows.get_metadata(ws.id)
        worktree_path = get_in(metadata, ["worktree", "worktree_path"])

        AI.create_ai_session(%{
          workflow_session_id: ws.id,
          worktree_path: worktree_path
        })

      _ ->
        :ok
    end
  end

  # --- Private ---

  defp get_phase(ws, phase_number) do
    Enum.at(Workflows.phases(ws.workflow_type), phase_number - 1)
  end

  defp ensure_ai_session(ws) do
    metadata = Workflows.get_metadata(ws.id)
    worktree_path = get_in(metadata, ["worktree", "worktree_path"])
    {:ok, session} = AI.get_or_create_ai_session(ws.id, %{worktree_path: worktree_path})
    session
  end

  defp enqueue_ai_worker(ws, phase, query) do
    %{"workflow_session_id" => ws.id, "phase" => phase, "query" => query}
    |> Destila.Workers.AiQueryWorker.new()
    |> Oban.insert()
  end
end
