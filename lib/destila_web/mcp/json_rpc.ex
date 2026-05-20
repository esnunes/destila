defmodule DestilaWeb.MCP.JsonRPC do
  @moduledoc """
  Tiny helpers for encoding/decoding JSON-RPC 2.0 envelopes.
  """

  @parse_error -32700
  @invalid_request -32600

  def parse_error_response(id \\ nil) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => @parse_error, "message" => "Parse error"}
    }
  end

  def invalid_request_response(id \\ nil) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => @invalid_request, "message" => "Invalid Request"}
    }
  end

  def valid_request?(%{"jsonrpc" => "2.0", "method" => method}) when is_binary(method), do: true
  def valid_request?(_), do: false
end
