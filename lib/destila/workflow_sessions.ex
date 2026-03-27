defmodule Destila.WorkflowSessions do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.WorkflowSessions.{WorkflowSession, WorkflowSessionMetadata}

  def list_workflow_sessions do
    from(ws in WorkflowSession,
      where: is_nil(ws.archived_at),
      order_by: ws.position
    )
    |> preload(:project)
    |> Repo.all()
  end

  def list_archived_workflow_sessions do
    from(ws in WorkflowSession,
      where: not is_nil(ws.archived_at),
      order_by: [desc: ws.archived_at]
    )
    |> preload(:project)
    |> Repo.all()
  end

  def get_workflow_session(id) do
    Repo.get(WorkflowSession, id)
  end

  def get_workflow_session!(id) do
    Repo.get!(WorkflowSession, id)
  end

  def create_workflow_session(attrs) do
    attrs = Map.put_new_lazy(attrs, :position, fn -> System.unique_integer([:positive]) end)

    %WorkflowSession{}
    |> WorkflowSession.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:workflow_session_created)
  end

  def update_workflow_session(%WorkflowSession{} = workflow_session, attrs) do
    workflow_session
    |> WorkflowSession.changeset(attrs)
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  def update_workflow_session(id, attrs) when is_binary(id) do
    get_workflow_session!(id) |> update_workflow_session(attrs)
  end

  def classify(%WorkflowSession{} = workflow_session) do
    cond do
      WorkflowSession.done?(workflow_session) -> :done
      workflow_session.phase_status == :setup -> :setup
      workflow_session.phase_status in [:conversing, :advance_suggested] -> :waiting_for_user
      workflow_session.phase_status == :generating -> :ai_processing
      true -> :in_progress
    end
  end

  def count_by_project(project_id) do
    Repo.aggregate(
      from(ws in WorkflowSession, where: ws.project_id == ^project_id),
      :count
    )
  end

  def count_by_projects do
    Repo.all(
      from(ws in WorkflowSession,
        where: not is_nil(ws.project_id),
        group_by: ws.project_id,
        select: {ws.project_id, count(ws.id)}
      )
    )
    |> Map.new()
  end

  def archive_workflow_session(%WorkflowSession{} = ws) do
    Destila.AI.ClaudeSession.stop_for_workflow_session(ws.id)

    ws
    |> WorkflowSession.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  def unarchive_workflow_session(%WorkflowSession{} = ws) do
    # If the session was archived mid-generation, reset to :conversing
    # so the user can retry instead of seeing a stuck typing indicator.
    attrs =
      if ws.phase_status == :generating,
        do: %{archived_at: nil, phase_status: :conversing},
        else: %{archived_at: nil}

    ws
    |> WorkflowSession.changeset(attrs)
    |> Repo.update()
    |> broadcast(:workflow_session_updated)
  end

  # --- Metadata ---

  def upsert_metadata(workflow_session_id, phase_name, key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %WorkflowSessionMetadata{}
    |> WorkflowSessionMetadata.changeset(%{
      workflow_session_id: workflow_session_id,
      phase_name: phase_name,
      key: key,
      value: value
    })
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:workflow_session_id, :phase_name, :key],
      set: [updated_at: now]
    )
    |> case do
      {:ok, metadata} ->
        Destila.PubSubHelper.broadcast_event(:metadata_updated, workflow_session_id)
        {:ok, metadata}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def get_metadata(workflow_session_id) do
    from(m in WorkflowSessionMetadata,
      where: m.workflow_session_id == ^workflow_session_id,
      order_by: m.phase_name
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn m, acc -> Map.put(acc, m.key, m.value) end)
  end

  defdelegate broadcast(result, event), to: Destila.PubSubHelper
end
