defmodule DestilaWeb.MCP.AuthPlug do
  @moduledoc """
  Validates the `Authorization: Bearer <token>` header against the configured
  MCP token. Halts with 401 on missing/wrong token before any body parsing.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    token = Application.fetch_env!(:destila, :mcp_token)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> ^token] -> conn
      _ -> deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
