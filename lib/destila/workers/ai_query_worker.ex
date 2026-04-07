defmodule Destila.Workers.AiQueryWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      keys: [:workflow_session_id, :phase],
      period: 30,
      states: [:available, :scheduled, :executing]
    ]

  alias Destila.{AI, Workflows}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "phase" => phase,
          "query" => query
        }
      }) do
    ws = Workflows.get_workflow_session!(workflow_session_id)
    session_opts = AI.SessionConfig.session_opts_for_workflow(ws, phase)

    case AI.ClaudeSession.for_workflow_session(workflow_session_id, session_opts) do
      {:ok, session} ->
        stream_topic = Destila.PubSubHelper.ai_stream_topic(workflow_session_id)

        case AI.ClaudeSession.query_streaming(session, query, stream_topic: stream_topic) do
          {:ok, result} ->
            Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_result: result})
            :ok

          {:error, reason} ->
            Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_error: reason})
            :ok
        end

      {:error, reason} ->
        Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_error: reason})
        {:error, reason}
    end
  end
end
