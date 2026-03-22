defmodule Destila.Messages do
  import Ecto.Query

  alias Destila.Repo
  alias Destila.Messages.Message

  def list_messages(prompt_id) do
    Repo.all(from(m in Message, where: m.prompt_id == ^prompt_id, order_by: m.inserted_at))
  end

  def create_message(prompt_id, attrs) do
    attrs =
      attrs
      |> Map.put(:prompt_id, prompt_id)

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:message_added)
  end

  defp broadcast({:ok, entity}, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {event, entity})
    {:ok, entity}
  end

  defp broadcast({:error, _} = error, _event), do: error
end
