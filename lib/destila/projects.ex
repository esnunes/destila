defmodule Destila.Projects do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Projects.Project

  def list_projects do
    Repo.all(from(p in Project, order_by: p.name))
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
    linked? =
      Repo.exists?(
        from(p in Destila.Prompts.Prompt,
          where: p.project_id == ^project.id
        )
      )

    if linked? do
      {:error, :has_linked_prompts}
    else
      case Repo.delete(project) do
        {:ok, project} ->
          Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {:project_deleted, project})
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end

  defp broadcast({:ok, entity}, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {event, entity})
    {:ok, entity}
  end

  defp broadcast({:error, _} = error, _event), do: error
end
