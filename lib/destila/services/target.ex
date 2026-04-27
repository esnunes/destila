defmodule Destila.Services.Target do
  @moduledoc """
  Describes a service target — either a workflow session's per-session
  service, or a project-level service that runs against the project's
  primary checkout on the default branch.

  `ServiceManager` operates on `Target` exclusively; callers construct
  the right kind of target at the boundary.
  """

  alias Destila.PubSubHelper
  alias Destila.Projects.Project
  alias Destila.Terminal.Tmux
  alias Destila.Workflows.Session

  @type kind :: :session | :project

  @type t :: %__MODULE__{
          kind: kind(),
          id: String.t(),
          cwd: String.t() | nil,
          tmux_session_name: String.t(),
          tmux_window: non_neg_integer(),
          log_key: String.t(),
          pubsub_topic: String.t(),
          run_command: String.t() | nil,
          setup_command: String.t() | nil,
          service_env_var: String.t() | nil,
          project: term() | nil,
          workflow_session: term() | nil
        }

  @enforce_keys [
    :kind,
    :id,
    :cwd,
    :tmux_session_name,
    :tmux_window,
    :log_key,
    :pubsub_topic,
    :run_command,
    :setup_command,
    :service_env_var
  ]
  defstruct [
    :kind,
    :id,
    :cwd,
    :tmux_session_name,
    :tmux_window,
    :log_key,
    :pubsub_topic,
    :run_command,
    :setup_command,
    :service_env_var,
    :project,
    :workflow_session
  ]

  @session_window 9
  @project_window 0

  @doc """
  Builds a target for a workflow session's per-session service.

  Requires `:worktree_path` in `opts` since the cwd is the session's
  isolated worktree, not the project's primary checkout.

  Sessions on the self-hosted Destila project share the project-level
  log naming `project-destila-<branch>` (branch read from the worktree)
  so each in-progress branch has a single canonical log file regardless
  of whether it is being run as a session or as the live BEAM.
  """
  def for_session(%Session{} = ws, opts) do
    project = Keyword.fetch!(opts, :project)
    worktree_path = Keyword.fetch!(opts, :worktree_path)

    %__MODULE__{
      kind: :session,
      id: ws.id,
      cwd: worktree_path,
      tmux_session_name: Tmux.session_name(ws),
      tmux_window: @session_window,
      log_key: session_log_key(ws, project, worktree_path),
      pubsub_topic: PubSubHelper.service_topic(ws.id),
      run_command: project.run_command,
      setup_command: project.setup_command,
      service_env_var: project.service_env_var,
      project: project,
      workflow_session: ws
    }
  end

  defp session_log_key(ws, project, worktree_path) do
    if project && Destila.Projects.self_hosted?(project) do
      "project-destila-" <> sanitize_branch(current_branch(worktree_path))
    else
      "session-" <> ws.id
    end
  end

  @doc """
  Builds a target for a project-level service.

  Uses `Destila.Git.effective_local_folder/1` so that clone-only projects
  (no `local_folder`) still resolve to a working directory.

  The `log_key` follows `project-<project-id>` for ordinary projects and
  `project-destila-<current-branch>` for the self-hosted Destila project,
  so multiple Destila instances running on different branches get
  distinct log files.
  """
  def for_project(%Project{} = project) do
    cwd =
      case Destila.Git.effective_local_folder(project) do
        {:ok, folder} -> folder
        {:error, _} -> nil
      end

    %__MODULE__{
      kind: :project,
      id: project.id,
      cwd: cwd,
      tmux_session_name: "destila-service-project-" <> project.id,
      tmux_window: @project_window,
      log_key: project_log_key(project, cwd),
      pubsub_topic: PubSubHelper.project_service_topic(project.id),
      run_command: project.run_command,
      setup_command: project.setup_command,
      service_env_var: project.service_env_var,
      project: project,
      workflow_session: nil
    }
  end

  defp project_log_key(%Project{} = project, cwd) do
    if Destila.Projects.self_hosted?(project) do
      "project-destila-" <> sanitize_branch(current_branch(cwd))
    else
      "project-" <> project.id
    end
  end

  defp current_branch(cwd) when is_binary(cwd) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      _ -> "unknown"
    end
  end

  defp current_branch(_), do: "unknown"

  defp sanitize_branch(branch) do
    branch
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  @doc """
  Returns the tmux address (`session:window`) used for `send-keys`,
  `kill-window`, and `pipe-pane`.
  """
  def tmux_address(%__MODULE__{tmux_session_name: name, tmux_window: window}) do
    "#{name}:#{window}"
  end
end
