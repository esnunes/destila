defmodule Destila.Workers.SetupWorker do
  use Oban.Worker, queue: :setup, max_attempts: 3

  alias Destila.{Git, Workflows}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id}}) do
    workflow_session = Workflows.get_workflow_session!(workflow_session_id)

    project =
      if workflow_session.project_id,
        do: Destila.Projects.get_project(workflow_session.project_id)

    with :ok <- sync_repo(workflow_session, project),
         :ok <- create_worktree(workflow_session, project) do
      :ok
    end
  end

  defp sync_repo(_workflow_session, nil), do: :ok

  defp sync_repo(workflow_session, project) do
    ws_id = workflow_session.id

    cond do
      project.local_folder && project.local_folder != "" ->
        upsert_step(ws_id, "repo_sync", "in_progress")

        case Git.pull(project.local_folder) do
          {:ok, _} ->
            upsert_step(ws_id, "repo_sync", "completed")
            :ok

          {:error, reason} ->
            upsert_step(ws_id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      project.git_repo_url && project.git_repo_url != "" ->
        upsert_step(ws_id, "repo_sync", "in_progress")

        with {:ok, path} <- Git.effective_local_folder(project),
             {:ok, _} <- Git.pull(path) do
          upsert_step(ws_id, "repo_sync", "completed")
          :ok
        else
          {:error, reason} ->
            upsert_step(ws_id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      true ->
        :ok
    end
  end

  defp create_worktree(_workflow_session, nil), do: :ok

  defp create_worktree(workflow_session, project) do
    ws_id = workflow_session.id

    case Git.effective_local_folder(project) do
      {:ok, local_folder} ->
        worktree_path = Path.join([local_folder, ".claude", "worktrees", ws_id])

        if Git.worktree_exists?(worktree_path) do
          upsert_step(ws_id, "worktree", "completed", nil, %{
            "worktree_path" => worktree_path
          })

          :ok
        else
          upsert_step(ws_id, "worktree", "in_progress")

          case Git.worktree_add(local_folder, worktree_path, ws_id) do
            {:ok, _} ->
              upsert_step(ws_id, "worktree", "completed", nil, %{
                "worktree_path" => worktree_path
              })

              :ok

            {:error, reason} ->
              upsert_step(ws_id, "worktree", "failed", reason)
              {:error, reason}
          end
        end

      {:error, reason} ->
        upsert_step(ws_id, "worktree", "failed", reason)
        {:error, reason}
    end
  end

  defp upsert_step(workflow_session_id, step, status, error \\ nil, extra \\ %{}) do
    value =
      %{"status" => status}
      |> then(fn v -> if error, do: Map.put(v, "error", sanitize_error(error)), else: v end)
      |> Map.merge(extra)

    Workflows.upsert_metadata(workflow_session_id, "setup", step, value)
  end

  defp sanitize_error(message) when is_binary(message) do
    message
    |> String.split("\n")
    |> List.first()
    |> String.replace(~r{/[^\s]+}, "[path]")
    |> String.slice(0, 200)
  end

  defp sanitize_error(other), do: inspect(other) |> String.slice(0, 200)
end
