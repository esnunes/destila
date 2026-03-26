defmodule Destila.Workers.SetupWorker do
  use Oban.Worker, queue: :setup, max_attempts: 3

  alias Destila.{Git, WorkflowSessions}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id}}) do
    workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)

    project =
      if workflow_session.project_id,
        do: Destila.Projects.get_project(workflow_session.project_id)

    with :ok <- sync_repo(workflow_session, project),
         :ok <- create_worktree(workflow_session, project) do
      Destila.Workflows.SetupCoordinator.maybe_advance_setup(workflow_session_id)
      :ok
    end
  end

  defp sync_repo(_workflow_session, nil), do: :ok

  defp sync_repo(workflow_session, project) do
    cond do
      project.local_folder && project.local_folder != "" ->
        update_setup_step(workflow_session.id, "repo_sync", "in_progress")

        case Git.pull(project.local_folder) do
          {:ok, _} ->
            update_setup_step(workflow_session.id, "repo_sync", "completed")
            :ok

          {:error, reason} ->
            update_setup_step(workflow_session.id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      project.git_repo_url && project.git_repo_url != "" ->
        update_setup_step(workflow_session.id, "repo_sync", "in_progress")

        with {:ok, path} <- Git.effective_local_folder(project),
             {:ok, _} <- Git.pull(path) do
          update_setup_step(workflow_session.id, "repo_sync", "completed")
          :ok
        else
          {:error, reason} ->
            update_setup_step(workflow_session.id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      true ->
        :ok
    end
  end

  defp create_worktree(_workflow_session, nil), do: :ok

  defp create_worktree(workflow_session, project) do
    case Git.effective_local_folder(project) do
      {:ok, local_folder} ->
        worktree_path = Path.join([local_folder, ".claude", "worktrees", workflow_session.id])

        if Git.worktree_exists?(worktree_path) do
          update_setup_step(workflow_session.id, "worktree", "completed", nil, %{
            "worktree_path" => worktree_path
          })

          :ok
        else
          update_setup_step(workflow_session.id, "worktree", "in_progress")

          case Git.worktree_add(local_folder, worktree_path, workflow_session.id) do
            {:ok, _} ->
              update_setup_step(workflow_session.id, "worktree", "completed", nil, %{
                "worktree_path" => worktree_path
              })

              :ok

            {:error, reason} ->
              update_setup_step(workflow_session.id, "worktree", "failed", reason)
              {:error, reason}
          end
        end

      {:error, reason} ->
        update_setup_step(workflow_session.id, "worktree", "failed", reason)
        {:error, reason}
    end
  end

  defp update_setup_step(workflow_session_id, step, status, error \\ nil, extra \\ %{}) do
    ws = WorkflowSessions.get_workflow_session!(workflow_session_id)

    step_value =
      %{"status" => status}
      |> then(fn v -> if error, do: Map.put(v, "error", sanitize_error(error)), else: v end)
      |> Map.merge(extra)

    setup_steps = Map.put(ws.setup_steps || %{}, step, step_value)

    WorkflowSessions.update_workflow_session(ws, %{setup_steps: setup_steps})
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
