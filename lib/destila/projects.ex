defmodule Destila.Projects do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Projects.Project

  def list_projects do
    Repo.all(from(p in Project, where: is_nil(p.archived_at), order_by: p.name))
  end

  def list_archived_projects do
    Repo.all(
      from(p in Project, where: not is_nil(p.archived_at), order_by: [desc: p.archived_at])
    )
  end

  def get_project(id) do
    Repo.get(Project, id)
  end

  def get_project!(id) do
    Repo.get!(Project, id)
  end

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:project_created)
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
    |> broadcast(:project_updated)
  end

  def delete_project(%Project{} = project) do
    if Destila.Workflows.count_by_project(project.id) > 0 do
      {:error, :has_linked_sessions}
    else
      case Repo.delete(project) do
        {:ok, project} ->
          Destila.PubSubHelper.broadcast_event(:project_deleted, project)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  def archive_project(%Project{} = project) do
    project
    |> Project.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update()
    |> broadcast(:project_updated)
  end

  def unarchive_project(%Project{} = project) do
    project
    |> Project.changeset(%{archived_at: nil})
    |> Repo.update()
    |> broadcast(:project_updated)
  end

  defdelegate broadcast(result, event), to: Destila.PubSubHelper

  @doc """
  Returns true when the project's local folder canonicalizes to the BEAM's
  current working directory — i.e. Destila is itself the running app.

  Returns false when `local_folder` is nil/blank or does not match cwd.
  """
  def self_hosted?(%Project{local_folder: nil}), do: false
  def self_hosted?(%Project{local_folder: ""}), do: false

  def self_hosted?(%Project{local_folder: local_folder}) when is_binary(local_folder) do
    normalize_path(local_folder) == normalize_path(File.cwd!())
  end

  def self_hosted?(_), do: false

  defp normalize_path(path) do
    path |> Path.expand() |> String.downcase()
  end

  @doc """
  Persists `service_state` on the project and broadcasts `:project_updated`.
  """
  def update_project_service_state(%Project{} = project, service_state) do
    project
    |> Project.changeset(%{service_state: service_state})
    |> Repo.update()
    |> broadcast(:project_updated)
  end

  @doc """
  Lists non-archived projects. Callers further filter by `Project.webservice?/1`
  to surface only those eligible for the services index.
  """
  def list_projects_with_service_state do
    Repo.all(
      from(p in Project,
        where: is_nil(p.archived_at),
        order_by: p.name
      )
    )
  end

  @doc """
  Lists projects whose persisted `service_state["status"]` is in `statuses`
  and which are not archived.
  """
  def list_projects_by_service_status(statuses) when is_list(statuses) do
    Repo.all(
      from(p in Project,
        where: is_nil(p.archived_at),
        where: not is_nil(p.service_state),
        where: fragment("json_extract(?, '$.status')", p.service_state) in ^statuses
      )
    )
  end
end
