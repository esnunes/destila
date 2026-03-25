defmodule Destila.Workers.SetupWorker do
  use Oban.Worker, queue: :setup, max_attempts: 3

  alias Destila.{Git, Messages, WorkflowSessions}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id}}) do
    workflow_session = WorkflowSessions.get_workflow_session!(workflow_session_id)

    project =
      if workflow_session.project_id,
        do: Destila.Projects.get_project(workflow_session.project_id)

    with :ok <- sync_repo(workflow_session, project),
         :ok <- create_worktree(workflow_session, project),
         :ok <- start_ai_session_and_trigger(workflow_session) do
      :ok
    end
  end

  defp sync_repo(_workflow_session, nil), do: :ok

  defp sync_repo(workflow_session, project) do
    cond do
      project.local_folder && project.local_folder != "" ->
        broadcast_step(
          workflow_session.id,
          "repo_sync",
          "in_progress",
          "Pulling latest changes..."
        )

        case Git.pull(project.local_folder) do
          {:ok, _} ->
            broadcast_step(workflow_session.id, "repo_sync", "completed", "Repository up to date")
            :ok

          {:error, reason} ->
            broadcast_step(workflow_session.id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      project.git_repo_url && project.git_repo_url != "" ->
        broadcast_step(workflow_session.id, "repo_sync", "in_progress", "Syncing repository...")

        with {:ok, path} <- Git.effective_local_folder(project),
             {:ok, _} <- Git.pull(path) do
          broadcast_step(workflow_session.id, "repo_sync", "completed", "Repository up to date")
          :ok
        else
          {:error, reason} ->
            broadcast_step(workflow_session.id, "repo_sync", "failed", reason)
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
          WorkflowSessions.update_workflow_session(workflow_session.id, %{
            worktree_path: worktree_path
          })

          broadcast_step(workflow_session.id, "worktree", "completed", "Worktree ready")
          :ok
        else
          broadcast_step(workflow_session.id, "worktree", "in_progress", "Creating worktree...")

          case Git.worktree_add(local_folder, worktree_path, workflow_session.id) do
            {:ok, _} ->
              WorkflowSessions.update_workflow_session(workflow_session.id, %{
                worktree_path: worktree_path
              })

              broadcast_step(workflow_session.id, "worktree", "completed", "Worktree ready")
              :ok

            {:error, reason} ->
              broadcast_step(workflow_session.id, "worktree", "failed", reason)
              {:error, reason}
          end
        end

      {:error, reason} ->
        broadcast_step(workflow_session.id, "worktree", "failed", reason)
        {:error, reason}
    end
  end

  defp start_ai_session_and_trigger(workflow_session) do
    broadcast_step(workflow_session.id, "ai_session", "in_progress", "Starting AI session...")

    workflow_session = WorkflowSessions.get_workflow_session!(workflow_session.id)

    {_action, phase_opts} =
      Destila.Workflows.session_strategy(
        workflow_session.workflow_type,
        workflow_session.steps_completed
      )

    session_opts = build_session_opts(workflow_session, phase_opts)

    case Destila.AI.Session.for_workflow_session(workflow_session.id, session_opts) do
      {:ok, _session} ->
        broadcast_step(workflow_session.id, "ai_session", "completed", "AI session ready")

        Destila.Setup.maybe_finish_phase0(workflow_session.id)
        :ok

      {:error, reason} ->
        broadcast_step(workflow_session.id, "ai_session", "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp build_session_opts(workflow_session, phase_opts) do
    opts = [timeout_ms: :timer.minutes(15)]

    opts =
      if workflow_session.ai_session_id do
        Keyword.put(opts, :resume, workflow_session.ai_session_id)
      else
        opts
      end

    opts =
      if workflow_session.worktree_path do
        Keyword.put(opts, :cwd, workflow_session.worktree_path)
      else
        opts
      end

    Destila.AI.Session.merge_phase_opts(opts, phase_opts)
  end

  defp broadcast_step(workflow_session_id, step, status, content) do
    content =
      if status == "failed" do
        sanitize_error(content)
      else
        content
      end

    Messages.create_message(workflow_session_id, %{
      role: :system,
      content: content,
      raw_response: %{"setup_step" => step, "status" => status},
      phase: 0
    })
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
