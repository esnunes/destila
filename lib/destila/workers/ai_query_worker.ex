defmodule Destila.Workers.AiQueryWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Destila.{Messages, WorkflowSessions}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "phase" => phase,
          "query" => query
        }
      }) do
    ws = WorkflowSessions.get_workflow_session!(workflow_session_id)
    session_opts = Destila.AI.Session.session_opts_for_workflow(ws, phase)

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

  defp handle_skip_phase(workflow_session_id, current_phase) do
    next_phase = current_phase + 1
    workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)
    total = Destila.Workflows.total_steps(workflow_session.workflow_type)

    if next_phase > total do
      # Can't skip past the last phase — ignore the marker
      WorkflowSessions.update_workflow_session(workflow_session_id, %{
        phase_status: :conversing
      })
    else
      {action, _} =
        Destila.Workflows.session_strategy(workflow_session.workflow_type, next_phase)

      update_attrs = %{steps_completed: next_phase, phase_status: :generating}

      update_attrs =
        if action == :new do
          Destila.AI.Session.stop_for_workflow_session(workflow_session_id)
          Map.put(update_attrs, :ai_session_id, nil)
        else
          update_attrs
        end

      WorkflowSessions.update_workflow_session(workflow_session_id, update_attrs)
      workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)
      workflow_module = Destila.Workflows.workflow_module(workflow_session.workflow_type)
      phase_prompt = workflow_module.system_prompt(next_phase, workflow_session)

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
