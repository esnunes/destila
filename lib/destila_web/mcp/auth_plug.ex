defmodule DestilaWeb.MCP.AuthPlug do
  @moduledoc """
  Validates the `Authorization: Bearer <token>` header against the configured
  MCP token. Halts with 401 on missing/wrong token before any body parsing.

  The token comparison uses `Plug.Crypto.secure_compare/2` so the success path
  does not leak token bytes via response-time differences. Bearer prefix
  matching is case-insensitive per RFC 7235.
  """

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:destila, :mcp_token) do
      nil ->
        Logger.error("MCP token not configured; rejecting request")
        deny(conn)

      configured when is_binary(configured) ->
        case extract_bearer(conn) do
          {:ok, presented} ->
            if Plug.Crypto.secure_compare(presented, configured), do: conn, else: deny(conn)

          :error ->
            deny(conn)
        end
    end
  end

  defp extract_bearer(conn) do
    with [value | _] <- get_req_header(conn, "authorization"),
         trimmed = String.trim_leading(value),
         {bearer_part, token_part} <- String.split_at(trimmed, 7),
         true <- String.downcase(bearer_part) == "bearer ",
         token = String.trim_leading(token_part),
         true <- token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"error":"unauthorized"}))
    |> halt()
  end
end
