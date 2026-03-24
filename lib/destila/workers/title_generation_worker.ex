defmodule Destila.Workers.TitleGenerationWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Destila.{Messages, WorkflowSessions}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "workflow_type" => workflow_type,
          "idea" => idea
        }
      }) do
    workflow_type = String.to_existing_atom(workflow_type)

    Messages.create_message(workflow_session_id, %{
      role: :system,
      content: "Generating title...",
      raw_response: %{"setup_step" => "title_generation", "status" => "in_progress"},
      phase: 0
    })

    title =
      case Destila.AI.generate_title(workflow_type, idea) do
        {:ok, title} -> title
        {:error, _reason} -> default_title(workflow_type)
      end

    WorkflowSessions.update_workflow_session(workflow_session_id, %{
      title: title,
      title_generating: false
    })

    Messages.create_message(workflow_session_id, %{
      role: :system,
      content: title,
      raw_response: %{
        "setup_step" => "title_generation",
        "status" => "completed",
        "result" => title
      },
      phase: 0
    })

    Destila.Setup.maybe_finish_phase0(workflow_session_id)

    :ok
  end

  defp default_title(:prompt_new_project), do: "New Project"
  defp default_title(:prompt_chore_task), do: "New Chore/Task"
  defp default_title(:implement_generic_prompt), do: "New Session"
end
