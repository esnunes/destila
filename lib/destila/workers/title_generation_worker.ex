defmodule Destila.Workers.TitleGenerationWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Destila.{Messages, Prompts}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"prompt_id" => prompt_id, "workflow_type" => workflow_type, "idea" => idea}
      }) do
    workflow_type = String.to_existing_atom(workflow_type)

    Messages.create_message(prompt_id, %{
      role: :system,
      content: "Generating title...",
      raw_response: %{"setup_step" => "title_generation", "status" => "in_progress"},
      phase: 0
    })

    case Destila.AI.generate_title(workflow_type, idea) do
      {:ok, title} ->
        Prompts.update_prompt(prompt_id, %{title: title, title_generating: false})

        Messages.create_message(prompt_id, %{
          role: :system,
          content: title,
          raw_response: %{
            "setup_step" => "title_generation",
            "status" => "completed",
            "result" => title
          },
          phase: 0
        })

        :ok

      {:error, _reason} ->
        title = default_title(workflow_type)
        Prompts.update_prompt(prompt_id, %{title: title, title_generating: false})

        Messages.create_message(prompt_id, %{
          role: :system,
          content: title,
          raw_response: %{
            "setup_step" => "title_generation",
            "status" => "completed",
            "result" => title
          },
          phase: 0
        })

        :ok
    end
  end

  defp default_title(:feature_request), do: "New Feature Request"
  defp default_title(:project), do: "New Project"
  defp default_title(:chore_task), do: "New Chore/Task"
end
