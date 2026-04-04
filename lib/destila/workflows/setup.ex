defmodule Destila.Workflows.Setup do
  @moduledoc """
  Shared logic for the setup phase across workflows.
  """

  @setup_keys ~w(title_gen repo_sync worktree)

  @doc """
  Enqueues setup workers (title generation, repo sync/worktree).
  Called from workflow `phase_start_action`.
  """
  def start(ws) do
    metadata = Destila.Workflows.get_metadata(ws.id)

    if ws.title_generating do
      idea = get_in(metadata, ["idea", "text"]) || get_in(metadata, ["prompt", "text"]) || ""

      %{"workflow_session_id" => ws.id, "idea" => idea}
      |> Destila.Workers.TitleGenerationWorker.new()
      |> Oban.insert()
    end

    if ws.project_id do
      %{"workflow_session_id" => ws.id}
      |> Destila.Workers.PrepareWorkflowSession.new()
      |> Oban.insert()
    end

    :processing
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
