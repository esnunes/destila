defmodule Destila.Workers.PrepareWorkflowSession do
  use Oban.Worker, queue: :setup, max_attempts: 3

  alias Destila.{AI, Git, Workflows}
  alias Destila.Sessions.SessionProcess

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id}}) do
    workflow_session = Workflows.get_workflow_session!(workflow_session_id)
    project = Destila.Projects.get_project(workflow_session.project_id)

    with :ok <- sync_repo(project),
         {:ok, worktree_path} <- create_worktree(workflow_session, project) do
      AI.get_or_create_ai_session(workflow_session.id, %{worktree_path: worktree_path})

      SessionProcess.cast(workflow_session.id, :worktree_ready)

      :ok
    end
  end

  defp sync_repo(nil), do: :ok

  defp sync_repo(project) do
    cond do
      project.local_folder && project.local_folder != "" ->
        case Git.pull(project.local_folder) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      project.git_repo_url && project.git_repo_url != "" ->
        with {:ok, path} <- Git.effective_local_folder(project),
             {:ok, _} <- Git.pull(path) do
          :ok
        end

      true ->
        :ok
    end
  end

  defp create_worktree(_workflow_session, nil), do: {:ok, nil}

  defp create_worktree(workflow_session, project) do
    case Git.effective_local_folder(project) do
      {:ok, local_folder} ->
        worktree_path = Path.join([local_folder, ".claude", "worktrees", workflow_session.id])

        if Git.worktree_exists?(worktree_path) do
          {:ok, worktree_path}
        else
          case Git.worktree_add(local_folder, worktree_path, workflow_session.id) do
            {:ok, _} -> {:ok, worktree_path}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
