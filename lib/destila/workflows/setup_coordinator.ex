defmodule Destila.Workflows.SetupCoordinator do
  @moduledoc """
  Coordinates parallel setup workers. Called by each worker after completing.
  Uses atomic CAS to advance current_phase when all required steps are done.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.WorkflowSessions.WorkflowSession

  def maybe_advance_setup(workflow_session_id) do
    ws = Destila.WorkflowSessions.get_workflow_session!(workflow_session_id)

    if all_steps_completed?(ws) do
      advance_phase(workflow_session_id)
    end
  end

  defp all_steps_completed?(ws) do
    steps = ws.setup_steps || %{}

    required_steps = required_steps_for(ws)

    Enum.all?(required_steps, fn step ->
      case steps[step] do
        %{"status" => "completed"} -> true
        _ -> false
      end
    end)
  end

  defp required_steps_for(ws) do
    base = ["title_gen"]

    if ws.project_id do
      base ++ ["repo_sync", "worktree"]
    else
      base
    end
  end

  defp advance_phase(workflow_session_id) do
    # Atomic CAS: only advance if still in phase 2 with :setup status
    {count, _} =
      from(ws in WorkflowSession,
        where: ws.id == ^workflow_session_id,
        where: ws.current_phase == 2,
        where: ws.phase_status == :setup
      )
      |> Repo.update_all(set: [current_phase: 3, phase_status: nil])

    if count > 0 do
      ws = Destila.WorkflowSessions.get_workflow_session!(workflow_session_id)
      Destila.PubSubHelper.broadcast_event(:workflow_session_updated, ws)
    end
  end
end
