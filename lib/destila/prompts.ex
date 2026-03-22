defmodule Destila.Prompts do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Prompts.Prompt

  def list_prompts do
    Repo.all(from(p in Prompt, order_by: p.position))
  end

  def list_prompts(board) do
    Repo.all(from(p in Prompt, where: p.board == ^board, order_by: p.position))
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

  def move_card(%Prompt{} = prompt, new_column, new_position) do
    update_prompt(prompt, %{column: new_column, position: new_position})
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

  defp broadcast({:ok, entity}, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {event, entity})
    {:ok, entity}
  end

  defp broadcast({:error, _} = error, _event), do: error
end
