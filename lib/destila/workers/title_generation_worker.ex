defmodule Destila.Workers.TitleGenerationWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Destila.Workflows

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "idea" => idea
        }
      }) do
    workflow_session = Workflows.get_workflow_session!(workflow_session_id)
    workflow_type = workflow_session.workflow_type

    title =
      try do
        case Destila.AI.generate_title(workflow_type, idea) do
          {:ok, title} ->
            title

          {:error, reason} ->
            Logger.warning(
              "Title generation returned error for workflow_session #{workflow_session_id}: " <>
                inspect(reason)
            )

            Workflows.default_title(workflow_type)
        end
      catch
        kind, reason ->
          Logger.warning(
            "Title generation crashed for workflow_session #{workflow_session_id}: " <>
              "#{inspect(kind)} #{inspect(reason)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          Workflows.default_title(workflow_type)
      end

    Workflows.update_workflow_session(workflow_session_id, %{
      title: title,
      title_generating: false
    })

    :ok
  end
end
