defmodule Destila.Workers.TitleGenerationWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Destila.WorkflowSessions

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "idea" => idea
        }
      }) do
    workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)
    workflow_type = workflow_session.workflow_type

    update_setup_step(workflow_session_id, "title_gen", "in_progress")

    title =
      case Destila.AI.generate_title(workflow_type, idea) do
        {:ok, title} -> title
        {:error, _reason} -> Destila.Workflows.default_title(workflow_type)
      end

    WorkflowSessions.update_workflow_session(workflow_session_id, %{
      title: title,
      title_generating: false
    })

    update_setup_step(workflow_session_id, "title_gen", "completed")

    Destila.Workflows.SetupCoordinator.maybe_advance_setup(workflow_session_id)

    :ok
  end

  defp update_setup_step(workflow_session_id, step, status) do
    ws = WorkflowSessions.get_workflow_session!(workflow_session_id)
    setup_steps = Map.put(ws.setup_steps || %{}, step, %{"status" => status})
    WorkflowSessions.update_workflow_session(ws, %{setup_steps: setup_steps})
  end
end
