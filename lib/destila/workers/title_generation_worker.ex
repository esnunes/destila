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

    WorkflowSessions.upsert_metadata(workflow_session_id, "setup", "title_gen", %{
      "status" => "in_progress"
    })

    title =
      case Destila.AI.generate_title(workflow_type, idea) do
        {:ok, title} -> title
        {:error, _reason} -> Destila.Workflows.default_title(workflow_type)
      end

    WorkflowSessions.update_workflow_session(workflow_session_id, %{
      title: title,
      title_generating: false
    })

    WorkflowSessions.upsert_metadata(workflow_session_id, "setup", "title_gen", %{
      "status" => "completed"
    })

    :ok
  end
end
