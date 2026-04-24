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

  def claude_session_topic, do: "claude_sessions"

  def service_topic(workflow_session_id) do
    "service:#{workflow_session_id}"
  end

  def broadcast_service_status(workflow_session_id, state) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      service_topic(workflow_session_id),
      {:service_status, state}
    )
  end

  def broadcast_service_log(workflow_session_id, chunk) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      service_topic(workflow_session_id),
      {:service_log, chunk}
    )
  end

  def broadcast_service_logs_cleared(workflow_session_id) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      service_topic(workflow_session_id),
      {:service_logs_cleared, workflow_session_id}
    )
  end
end
