defmodule Destila.Agent.Sessions do
  @moduledoc """
  Context module for the new MCP-driven agent sessions path.

  All persistence, querying, and PubSub broadcasting for `agent_sessions`
  and `agent_session_events` lives here. Mirrors the chat-path `Destila.Workflows`
  context shape.
  """

  import Ecto.Query

  alias Destila.Repo
  alias Destila.Agent.{Session, SessionEvent}
  alias Destila.Workflows.SessionMetadata

  # --- Session queries ---

  def list_sessions(opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    include_archived? = Keyword.get(opts, :include_archived, false)

    Session
    |> where([s], is_nil(s.deleted_at))
    |> maybe_filter_project(project_id)
    |> maybe_filter_archived(include_archived?)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, id), do: where(query, [s], s.project_id == ^id)

  defp maybe_filter_archived(query, true), do: query
  defp maybe_filter_archived(query, false), do: where(query, [s], is_nil(s.archived_at))

  def get_session(id), do: Repo.get(Session, id)
  def get_session!(id), do: Repo.get!(Session, id)

  def create_session(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:agent_session_created)
  end

  def update_session(%Session{} = session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
    |> broadcast(:agent_session_updated)
  end

  @doc """
  Transitions session status. Acceptable statuses are listed on the schema.
  Broadcasts `:agent_session_updated` on success.
  """
  def transition_status(%Session{} = session, status) when is_atom(status) do
    update_session(session, %{status: status})
  end

  def mark_connected(%Session{} = session) do
    update_session(session, %{
      status: :active,
      connected_at: DateTime.utc_now() |> DateTime.truncate(:second),
      disconnected_at: nil
    })
  end

  def mark_disconnected(%Session{} = session) do
    update_session(session, %{
      status: :disconnected,
      disconnected_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc """
  Increments the phase index. Returns the updated session or `{:error, :no_more_phases}`.
  """
  def advance_phase(%Session{} = session) do
    next = session.current_phase_index + 1

    cond do
      next >= session.total_phases ->
        update_session(session, %{status: :done, current_phase_index: next - 1})

      true ->
        update_session(session, %{current_phase_index: next})
    end
  end

  # --- Event queries ---

  def list_events(session_id) do
    SessionEvent
    |> where([e], e.agent_session_id == ^session_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  def record_event(%Session{} = session, tool_name, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:agent_session_id, session.id)
      |> Map.put(:tool_name, tool_name)
      |> Map.put_new(:phase_index, session.current_phase_index)
      |> Map.put_new_lazy(:inserted_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    result =
      %SessionEvent{}
      |> SessionEvent.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, event} ->
        broadcast_session(session.id, {:tool_call_event, event})
        {:ok, event}

      err ->
        err
    end
  end

  # --- Exports ---

  def list_exports(session_id) do
    SessionMetadata
    |> where([m], m.agent_session_id == ^session_id and m.exported == true)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  def record_export(%Session{} = session, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:agent_session_id, session.id)
      |> Map.put_new(:exported, true)
      |> Map.put_new(:phase_index, session.current_phase_index)

    case %SessionMetadata{} |> SessionMetadata.changeset(attrs) |> Repo.insert() do
      {:ok, meta} ->
        broadcast_session(session.id, {:export_added, meta})
        {:ok, meta}

      err ->
        err
    end
  end

  # --- PubSub helpers ---

  def topic(session_id), do: "agent_session:#{session_id}"
  def outbound_topic(session_id), do: "agent_session_outbound:#{session_id}"

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Destila.PubSub, topic(session_id))
  end

  def broadcast_session(session_id, msg) do
    Phoenix.PubSub.broadcast(Destila.PubSub, topic(session_id), msg)
  end

  defp broadcast({:ok, session} = result, event) do
    Phoenix.PubSub.broadcast(Destila.PubSub, "store:updates", {event, session})

    if Map.has_key?(session, :id) do
      Phoenix.PubSub.broadcast(Destila.PubSub, topic(session.id), {event, session})
    end

    result
  end

  defp broadcast({:error, _} = err, _event), do: err
end
