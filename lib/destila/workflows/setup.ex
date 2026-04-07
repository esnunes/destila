defmodule Destila.Workflows.Setup do
  @moduledoc """
  Shared logic for the setup phase across workflows.
  """

  @setup_keys ~w(repo_sync worktree)

  @doc """
  Enqueues setup workers (repo sync/worktree).
  Returns `:setup_complete` when no workers are needed (no project).
  """
  def start(ws) do
    if ws.project_id do
      %{"workflow_session_id" => ws.id}
      |> Destila.Workers.PrepareWorkflowSession.new()
      |> Oban.insert()

      :processing
    else
      :setup_complete
    end
  end

  @doc """
  Called by Engine when a setup step completes.
  Returns `:setup_complete` if all steps are done, `:processing` otherwise.
  """
  def update(workflow_session, _params) do
    metadata = Destila.Workflows.get_metadata(workflow_session.id)

    setup_keys =
      metadata
      |> Map.keys()
      |> Enum.filter(&(&1 in @setup_keys))

    if setup_keys != [] &&
         Enum.all?(setup_keys, &(get_in(metadata, [&1, "status"]) == "completed")) do
      :setup_complete
    else
      :processing
    end
  end
end
