defmodule Destila.Workers.PrepareWorkflowSession do
  use Oban.Worker, queue: :setup, max_attempts: 3

  require Logger

  alias Destila.{AI, Git, Workflows}
  alias Destila.Sessions.SessionProcess
  import Destila.StringHelper, only: [blank?: 1]

  @service_window 9

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id}}) do
    workflow_session = Workflows.get_workflow_session!(workflow_session_id)
    project = Destila.Projects.get_project(workflow_session.project_id)

    with :ok <- sync_repo(project),
         {:ok, worktree_path} <- create_worktree(workflow_session, project) do
      AI.get_or_create_ai_session(workflow_session.id, %{worktree_path: worktree_path})

      run_post_worktree_setup(project, worktree_path, workflow_session)

      SessionProcess.worktree_ready(workflow_session.id)

      :ok
    end
  end

  @doc false
  def run_post_worktree_setup(nil, _worktree_path, _ws), do: :ok

  def run_post_worktree_setup(project, worktree_path, ws) do
    if blank?(project.setup_command) do
      :ok
    else
      try do
        tmux = tmux_impl()
        session = tmux.session_name(ws)
        target = "#{session}:#{@service_window}"

        tmux.ensure_session(session, worktree_path)
        tmux.kill_window(target)
        tmux.new_window(target, cwd: worktree_path)
        tmux.send_keys(target, project.setup_command)
        :ok
      rescue
        e ->
          Logger.warning(
            "Post-worktree setup failed for session #{ws.id}: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          :ok
      end
    end
  end

  defp tmux_impl, do: Application.get_env(:destila, :tmux, Destila.Terminal.Tmux)

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
