defmodule Destila.WorkflowSessions do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.WorkflowSessions.WorkflowSession

  def list_workflow_sessions do
    from(ws in WorkflowSession, order_by: ws.position)
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
      workflow_session.column == :done -> :done
      workflow_session.phase_status == :setup -> :setup
      workflow_session.phase_status in [:generating, :conversing, :advance_suggested] -> :waiting
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

  defdelegate broadcast(result, event), to: Destila.PubSubHelper
end
