defmodule Destila.PubSubHelper do
  @topic "store:updates"

  def broadcast({:ok, entity}, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, @topic, {event, entity})
    {:ok, entity}
  end

  def broadcast({:error, _} = error, _event), do: error

  def broadcast_event(event, data) do
    Phoenix.PubSub.broadcast(Destila.PubSub, @topic, {event, data})
  end

  def ai_stream_topic(workflow_session_id) do
    "ai_stream:#{workflow_session_id}"
  end
end
