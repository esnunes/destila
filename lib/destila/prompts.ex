defmodule Destila.Prompts do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Prompts.Prompt

  def list_prompts do
    from(p in Prompt, order_by: p.position)
    |> preload(:project)
    |> Repo.all()
  end

  def get_prompt(id) do
    Repo.get(Prompt, id)
  end

  def get_prompt!(id) do
    Repo.get!(Prompt, id)
  end

  def create_prompt(attrs) do
    attrs = Map.put_new_lazy(attrs, :position, fn -> System.unique_integer([:positive]) end)

    %Prompt{}
    |> Prompt.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:prompt_created)
  end

  def update_prompt(%Prompt{} = prompt, attrs) do
    prompt
    |> Prompt.changeset(attrs)
    |> Repo.update()
    |> broadcast(:prompt_updated)
  end

  def update_prompt(id, attrs) when is_binary(id) do
    get_prompt!(id) |> update_prompt(attrs)
  end

  def classify(%Prompt{} = prompt) do
    cond do
      prompt.column == :done -> :done
      prompt.phase_status == :setup -> :setup
      prompt.phase_status in [:generating, :conversing, :advance_suggested] -> :waiting
      true -> :in_progress
    end
  end

  def count_by_project(project_id) do
    Repo.aggregate(from(p in Prompt, where: p.project_id == ^project_id), :count)
  end

  def count_by_projects do
    Repo.all(
      from(p in Prompt,
        where: not is_nil(p.project_id),
        group_by: p.project_id,
        select: {p.project_id, count(p.id)}
      )
    )
    |> Map.new()
  end

  defdelegate broadcast(result, event), to: Destila.PubSubHelper
end
