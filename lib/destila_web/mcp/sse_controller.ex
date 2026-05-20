defmodule DestilaWeb.MCP.SseController do
  @moduledoc """
  GET /mcp/:session_id/events — long-lived SSE channel.

  On connect, subscribes the calling process to PubSub topic
  `agent_session_outbound:<session_id>` and chunk-streams any received
  messages as `event:` frames until the client closes.
  """

  use DestilaWeb, :controller

  alias Destila.Agent.{Sessions, SessionServer}

  @keepalive_interval :timer.seconds(15)

  def stream(conn, %{"session_id" => session_id}) do
    Phoenix.PubSub.subscribe(Destila.PubSub, Sessions.outbound_topic(session_id))
    SessionServer.sse_connected(session_id)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, format_event("ok", %{"hello" => true}))

    Process.send_after(self(), :keepalive, @keepalive_interval)
    loop(conn, session_id)
  end

  defp loop(conn, session_id) do
    receive do
      :keepalive ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :keepalive, @keepalive_interval)
            loop(conn, session_id)

          {:error, _} ->
            SessionServer.sse_closed(session_id)
            conn
        end

      {event_name, payload} when is_atom(event_name) ->
        case Plug.Conn.chunk(conn, format_event(Atom.to_string(event_name), payload)) do
          {:ok, conn} -> loop(conn, session_id)
          {:error, _} -> sse_done(conn, session_id)
        end

      _other ->
        loop(conn, session_id)
    after
      :timer.minutes(60) ->
        sse_done(conn, session_id)
    end
  end

  defp sse_done(conn, session_id) do
    SessionServer.sse_closed(session_id)
    conn
  end

  defp format_event(name, payload) do
    "event: #{name}\ndata: #{Jason.encode!(payload)}\n\n"
  end
end
