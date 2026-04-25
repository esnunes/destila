defmodule Destila.Workers.ProjectServicePullRestartWorker do
  @moduledoc """
  Periodic + on-demand "pull latest, restart service" funnel for project-level
  services.

  Two invocation modes:

    * **Cron mode** — `args == %{}` (or missing `:project_id`). Enumerates all
      non-archived projects whose `service_state["status"]` is `"running"` or
      `"starting"` and runs `Destila.Services.ProjectServices.pull_and_restart/1`
      for each, inline.
    * **Targeted mode** — `args == %{"project_id" => id}`. Runs the funnel
      against that single project. Used by the manual "Pull latest & restart"
      button and by the session lifecycle hooks (archive / mark-done).

  Oban `unique` collapses concurrent enqueues from cron + manual + hooks into
  one job per project per minute.
  """

  use Oban.Worker,
    queue: :project_services,
    max_attempts: 1,
    unique: [period: 60, fields: [:args]]

  require Logger

  alias Destila.Projects
  alias Destila.Services.ProjectServices

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id}}) when is_binary(project_id) do
    run_one(project_id)
  end

  def perform(%Oban.Job{args: _}) do
    Projects.list_projects_by_service_status(["running", "starting"])
    |> Enum.each(fn project -> run_one(project.id) end)

    :ok
  end

  defp run_one(project_id) do
    try do
      _ = ProjectServices.pull_and_restart(project_id)
    rescue
      e ->
        Logger.error(
          "ProjectServicePullRestartWorker crashed for #{project_id}: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )
    end

    :ok
  end
end
