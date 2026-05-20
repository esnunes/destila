defmodule Destila.Agent.EventRouter do
  @moduledoc """
  Receives JSON-RPC tool calls from the HTTP transport layer and forwards
  them to the right `SessionServer`. The single dispatch point between the
  HTTP+SSE controllers and the per-session orchestrators.
  """

  alias Destila.Agent.SessionServer

  @doc """
  Handle a parsed JSON-RPC request. `payload` must be a decoded map with the
  standard `"method"`, `"params"`, and `"id"` fields. Returns the JSON-RPC
  response envelope to send back over HTTP.
  """
  def handle_rpc(session_id, %{"method" => method} = payload) do
    request_id = Map.get(payload, "id")
    params = Map.get(payload, "params") || %{}

    case dispatch(session_id, method, params) do
      {:ok, result} ->
        if is_nil(request_id) do
          # Notifications produce no reply
          :noreply
        else
          %{"jsonrpc" => "2.0", "id" => request_id, "result" => result}
        end

      {:error, code, message} ->
        if is_nil(request_id) do
          # Per JSON-RPC 2.0 §4.1, notifications MUST NOT receive a response,
          # even on error.
          :noreply
        else
          %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "error" => %{"code" => code, "message" => message}
          }
        end
    end
  end

  def handle_rpc(_session_id, _bad) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32600, "message" => "Invalid Request"}
    }
  end

  defp dispatch(_session_id, "initialize", _params) do
    {:ok,
     %{
       "protocolVersion" => "2024-11-05",
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => "destila", "version" => destila_version()}
     }}
  end

  defp dispatch(_session_id, "notifications/initialized", _params), do: {:ok, %{}}
  defp dispatch(_session_id, "notifications/cancelled", _params), do: {:ok, %{}}
  defp dispatch(_session_id, "ping", _params), do: {:ok, %{}}

  defp dispatch(_session_id, "tools/list", _params) do
    {:ok, %{"tools" => Destila.Agent.ToolHandlers.schemas()}}
  end

  defp dispatch(session_id, "tools/call", %{"name" => name} = params) do
    arguments = Map.get(params, "arguments") || %{}

    case SessionServer.handle_tool_call(session_id, name, arguments) do
      {:ok, result} -> {:ok, result}
      {:error, :unknown_tool} -> {:error, -32601, "Method not found: #{name}"}
      {:error, reason} -> {:error, -32603, "Internal error: #{inspect(reason)}"}
    end
  end

  defp dispatch(_session_id, method, _params) do
    {:error, -32601, "Method not found: #{method}"}
  end

  defp destila_version do
    case Application.spec(:destila, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
