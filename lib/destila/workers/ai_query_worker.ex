defmodule Destila.Workers.AiQueryWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Destila.{Messages, WorkflowSessions}
  alias Destila.Workflows.ChoreTaskPhases

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "phase" => phase,
          "query" => query
        }
      }) do
    ws = WorkflowSessions.get_workflow_session!(workflow_session_id)
    session_opts = build_session_opts(ws)

    case Destila.AI.Session.for_workflow_session(workflow_session_id, session_opts) do
      {:ok, session} ->
        handle_query(workflow_session_id, phase, session, query)

      {:error, reason} ->
        Messages.create_message(workflow_session_id, %{
          role: :system,
          content: "Something went wrong. Please try sending your message again.",
          phase: phase
        })

        WorkflowSessions.update_workflow_session(workflow_session_id, %{
          phase_status: :conversing
        })

        {:error, reason}
    end
  end

  defp handle_query(workflow_session_id, phase, session, query) do
    case Destila.AI.Session.query(session, query) do
      {:ok, result} ->
        response_text = Messages.response_text(result)
        new_phase_status = Messages.derive_phase_status(response_text)

        Messages.create_message(workflow_session_id, %{
          role: :system,
          content: response_text,
          raw_response: result,
          phase: phase
        })

        if String.contains?(response_text, "<<SKIP_PHASE>>") do
          handle_skip_phase(workflow_session_id, phase)
        else
          update_attrs = %{phase_status: new_phase_status}

          update_attrs =
            if result[:session_id],
              do: Map.put(update_attrs, :ai_session_id, result[:session_id]),
              else: update_attrs

          WorkflowSessions.update_workflow_session(workflow_session_id, update_attrs)
        end

        :ok

      {:error, _} ->
        Messages.create_message(workflow_session_id, %{
          role: :system,
          content: "Something went wrong. Please try sending your message again.",
          phase: phase
        })

        WorkflowSessions.update_workflow_session(workflow_session_id, %{
          phase_status: :conversing
        })

        :ok
    end
  end

  defp build_session_opts(ws) do
    opts = []

    opts =
      if ws.ai_session_id,
        do: Keyword.put(opts, :resume, ws.ai_session_id),
        else: opts

    if ws.worktree_path,
      do: Keyword.put(opts, :cwd, ws.worktree_path),
      else: opts
  end

  defp handle_skip_phase(workflow_session_id, current_phase) do
    next_phase = current_phase + 1

    WorkflowSessions.update_workflow_session(workflow_session_id, %{
      steps_completed: next_phase,
      phase_status: :generating
    })

    workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)
    phase_prompt = ChoreTaskPhases.system_prompt(next_phase, workflow_session)

    %{
      "workflow_session_id" => workflow_session_id,
      "phase" => next_phase,
      "query" => phase_prompt
    }
    |> __MODULE__.new()
    |> Oban.insert()
  end
end
