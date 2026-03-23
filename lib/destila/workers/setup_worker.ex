defmodule Destila.Workers.SetupWorker do
  use Oban.Worker, queue: :setup, max_attempts: 3

  alias Destila.{Git, Messages, Prompts}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"prompt_id" => prompt_id}}) do
    prompt = Prompts.get_prompt!(prompt_id)

    project =
      if prompt.project_id,
        do: Destila.Projects.get_project(prompt.project_id)

    with :ok <- maybe_sync_repo(prompt, project),
         :ok <- maybe_create_worktree(prompt, project),
         :ok <- start_ai_session_and_trigger(prompt) do
      :ok
    end
  end

  defp maybe_sync_repo(_prompt, nil), do: :ok

  defp maybe_sync_repo(prompt, project) do
    sync_repo(prompt, project)
  end

  defp sync_repo(prompt, project) do
    cond do
      project.local_folder && project.local_folder != "" ->
        broadcast_step(prompt.id, "repo_sync", "in_progress", "Pulling latest changes...")

        case Git.pull(project.local_folder) do
          {:ok, _} ->
            broadcast_step(prompt.id, "repo_sync", "completed", "Repository up to date")
            :ok

          {:error, reason} ->
            broadcast_step(prompt.id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      project.git_repo_url && project.git_repo_url != "" ->
        broadcast_step(prompt.id, "repo_sync", "in_progress", "Cloning repository...")

        case Git.effective_local_folder(project) do
          {:ok, _path} ->
            broadcast_step(prompt.id, "repo_sync", "completed", "Repository cloned")
            :ok

          {:error, reason} ->
            broadcast_step(prompt.id, "repo_sync", "failed", reason)
            {:error, reason}
        end

      true ->
        :ok
    end
  end

  defp maybe_create_worktree(_prompt, nil), do: :ok

  defp maybe_create_worktree(prompt, project) do
    create_worktree(prompt, project)
  end

  defp create_worktree(prompt, project) do
    case Git.effective_local_folder(project) do
      {:ok, local_folder} ->
        worktree_path = Path.join([local_folder, ".claude", "worktrees", prompt.id])

        if Git.worktree_exists?(worktree_path) do
          Prompts.update_prompt(prompt.id, %{worktree_path: worktree_path})
          broadcast_step(prompt.id, "worktree", "completed", "Worktree ready")
          :ok
        else
          broadcast_step(prompt.id, "worktree", "in_progress", "Creating worktree...")

          case Git.worktree_add(local_folder, worktree_path, prompt.id) do
            {:ok, _} ->
              Prompts.update_prompt(prompt.id, %{worktree_path: worktree_path})
              broadcast_step(prompt.id, "worktree", "completed", "Worktree ready")
              :ok

            {:error, reason} ->
              broadcast_step(prompt.id, "worktree", "failed", reason)
              {:error, reason}
          end
        end

      {:error, reason} ->
        broadcast_step(prompt.id, "worktree", "failed", reason)
        {:error, reason}
    end
  end

  defp start_ai_session_and_trigger(prompt) do
    broadcast_step(prompt.id, "ai_session", "in_progress", "Starting AI session...")

    prompt = Prompts.get_prompt!(prompt.id)
    session_opts = build_session_opts(prompt)

    case Destila.AI.Session.for_prompt(prompt.id, session_opts) do
      {:ok, _session} ->
        broadcast_step(prompt.id, "ai_session", "completed", "AI session ready")

        # Check if title generation is also done; if so, transition to Phase 1
        Destila.Setup.maybe_finish_phase0(prompt.id)
        :ok

      {:error, reason} ->
        broadcast_step(prompt.id, "ai_session", "failed", inspect(reason))
        {:error, reason}
    end
  end

  defp build_session_opts(prompt) do
    opts = [timeout_ms: :timer.minutes(15)]

    opts =
      if prompt.session_id do
        Keyword.put(opts, :resume, prompt.session_id)
      else
        opts
      end

    if prompt.worktree_path do
      Keyword.put(opts, :cwd, prompt.worktree_path)
    else
      opts
    end
  end

  defp broadcast_step(prompt_id, step, status, content) do
    content =
      if status == "failed" do
        sanitize_error(content)
      else
        content
      end

    Messages.create_message(prompt_id, %{
      role: :system,
      content: content,
      raw_response: %{"setup_step" => step, "status" => status},
      phase: 0
    })
  end

  defp sanitize_error(message) when is_binary(message) do
    # Remove filesystem paths and keep only the meaningful error
    message
    |> String.split("\n")
    |> List.first()
    |> String.replace(~r{/[^\s]+}, "[path]")
    |> String.slice(0, 200)
  end

  defp sanitize_error(other), do: inspect(other) |> String.slice(0, 200)
end
