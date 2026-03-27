defmodule Destila.Workers.AiQueryWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

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
    ai_session_record = AI.get_ai_session_for_workflow(workflow_session_id)

    unless ai_session_record do
      raise "No AI session record found for workflow session #{workflow_session_id}"
    end

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

        # Save claude_session_id on the AI session record
        if result[:session_id] do
          AI.update_ai_session(ai_session_record, %{
            claude_session_id: result[:session_id]
          })
        end

        case session_action do
          %{action: "phase_complete"} ->
            handle_skip_phase(ws.id, phase)

          %{action: "suggest_phase_complete"} ->
            Workflows.update_workflow_session(ws.id, %{phase_status: :advance_suggested})

          _ ->
            Workflows.update_workflow_session(ws.id, %{phase_status: :conversing})
        end

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

  defp handle_skip_phase(workflow_session_id, current_phase) do
    next_phase = current_phase + 1
    ws = Workflows.get_workflow_session!(workflow_session_id)
    total = ws.total_phases

    if next_phase > total do
      Workflows.update_workflow_session(workflow_session_id, %{
        phase_status: :conversing
      })
    else
      {action, _} =
        Destila.Workflows.session_strategy(ws.workflow_type, next_phase)

      update_attrs = %{current_phase: next_phase, phase_status: :generating}

      if action == :new do
        Destila.AI.ClaudeSession.stop_for_workflow_session(workflow_session_id)
      end

      Workflows.update_workflow_session(workflow_session_id, update_attrs)
      ws = Workflows.get_workflow_session!(workflow_session_id)

      phases = Destila.Workflows.phases(ws.workflow_type)
      {_module, opts} = Enum.at(phases, next_phase - 1)
      system_prompt_fn = Keyword.fetch!(opts, :system_prompt)
      phase_prompt = system_prompt_fn.(ws)

      %{
        "workflow_session_id" => workflow_session_id,
        "phase" => next_phase,
        "query" => phase_prompt
      }
      |> __MODULE__.new()
      |> Oban.insert()
    end
  end
end
