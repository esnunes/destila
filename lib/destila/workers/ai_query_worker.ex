defmodule Destila.Workers.AiQueryWorker do
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      keys: [:workflow_session_id, :phase],
      period: 30,
      states: [:available, :scheduled, :executing]
    ]

  alias Destila.{AI, Executions, Workflows}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "phase" => phase,
          "query" => query
        }
      }) do
    ws = Workflows.get_workflow_session!(workflow_session_id)
    ai_session_record = AI.get_ai_session_for_workflow(workflow_session_id)

    unless ai_session_record do
      raise "No AI session record found for workflow session #{workflow_session_id}"
    end

    # Ensure phase execution exists for tracking
    {:ok, _pe} = Executions.ensure_phase_execution(ws, phase)

    session_opts = Destila.AI.ClaudeSession.session_opts_for_workflow(ws, phase)

    case Destila.AI.ClaudeSession.for_workflow_session(workflow_session_id, session_opts) do
      {:ok, session} ->
        handle_query(ws, ai_session_record, phase, session, query)

      {:error, reason} ->
        AI.create_message(ai_session_record.id, %{
          role: :system,
          content: "Something went wrong. Please try sending your message again.",
          phase: phase
        })

        Workflows.update_workflow_session(workflow_session_id, %{
          phase_status: :conversing
        })

        {:error, reason}
    end
  end

  defp handle_query(ws, ai_session_record, phase, session, query) do
    case Destila.AI.ClaudeSession.query(session, query) do
      {:ok, result} ->
        response_text = AI.response_text(result)
        session_action = AI.extract_session_action(result)

        # Use session tool message as content when present, fallback to response text
        content =
          case session_action do
            %{message: msg} when is_binary(msg) and msg != "" -> msg
            _ -> response_text
          end

        AI.create_message(ai_session_record.id, %{
          role: :system,
          content: content,
          raw_response: result,
          phase: phase
        })

        # If this phase produces a generated prompt, save it as metadata
        # so other workflows can discover it via the prompt_generated key.
        phase_opts = get_phase_opts(ws, phase)

        if Keyword.get(phase_opts, :message_type) == :generated_prompt do
          phase_name = Workflows.phase_name(ws.workflow_type, phase)

          Workflows.upsert_metadata(ws.id, phase_name, "prompt_generated", %{
            "text" => String.trim(response_text)
          })
        end

        # Save claude_session_id on the AI session record
        if result[:session_id] do
          AI.update_ai_session(ai_session_record, %{
            claude_session_id: result[:session_id]
          })
        end

        Destila.Executions.Engine.handle_phase_result(ws.id, phase, session_action)

        :ok

      {:error, _} ->
        AI.create_message(ai_session_record.id, %{
          role: :system,
          content: "Something went wrong. Please try sending your message again.",
          phase: phase
        })

        Workflows.update_workflow_session(ws.id, %{
          phase_status: :conversing
        })

        :ok
    end
  end

  defp get_phase_opts(ws, phase) do
    case Enum.at(Workflows.phases(ws.workflow_type), phase - 1) do
      {_mod, opts} -> opts
      nil -> []
    end
  end
end
