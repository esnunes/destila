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

  def project_service_topic(project_id) do
    "service:project-#{project_id}"
  end

  def broadcast_project_service_status(project_id, state) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      project_service_topic(project_id),
      {:service_status, state}
    )
  end

  def broadcast_project_service_log(project_id, chunk) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      project_service_topic(project_id),
      {:service_log, chunk}
    )
  end

  def broadcast_project_service_logs_cleared(project_id) do
    log_key = "project-#{project_id}"

    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      project_service_topic(project_id),
      {:service_logs_cleared, log_key}
    )
  end

  def broadcast_project_service_error(project_id, stage, details) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      project_service_topic(project_id),
      {:project_service_error, stage, details}
    )
  end

  def broadcast_service_proxy_error(%{kind: :session, id: ws_id}, reason) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      service_topic(ws_id),
      {:service_proxy_error, reason}
    )
  end

  def broadcast_service_proxy_error(%{kind: :project, id: project_id}, reason) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      project_service_topic(project_id),
      {:service_proxy_error, reason}
    )
  end

  def claude_auth_login_topic, do: "claude_auth_login"

  def broadcast_claude_auth_login(snapshot) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      claude_auth_login_topic(),
      {:claude_auth_login_state, snapshot}
    )
  end
end
