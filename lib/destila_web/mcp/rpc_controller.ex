defmodule DestilaWeb.MCP.RpcController do
  @moduledoc """
  POST /mcp/:session_id/rpc — JSON-RPC 2.0 entry point.

  Decodes the request, validates the optional `X-Destila-Session-Id` header
  matches the path segment, and dispatches via `Destila.Agent.EventRouter`.
  """

  use DestilaWeb, :controller

  alias Destila.Agent.EventRouter
  alias DestilaWeb.MCP.JsonRPC

  def dispatch(conn, %{"session_id" => session_id}) do
    case validate_session_header(conn, session_id) do
      :ok ->
        body = conn.body_params

        cond do
          not is_map(body) ->
            json(conn, JsonRPC.parse_error_response())

          not JsonRPC.valid_request?(body) ->
            json(conn, JsonRPC.invalid_request_response(Map.get(body, "id")))

          true ->
            case EventRouter.handle_rpc(session_id, body) do
              :noreply -> send_resp(conn, 204, "")
              %{} = reply -> json(conn, reply)
            end
        end

      :session_mismatch ->
        conn
        |> put_status(400)
        |> json(%{"error" => "session id header does not match path segment"})
    end
  end

  defp validate_session_header(conn, session_id) do
    case Plug.Conn.get_req_header(conn, "x-destila-session-id") do
      [] -> :ok
      [^session_id] -> :ok
      _ -> :session_mismatch
    end
  end
end
