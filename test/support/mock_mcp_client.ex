defmodule Destila.Test.MockMCPClient do
  @moduledoc """
  Test helper that drives the agent session pipeline without going through
  HTTP+SSE. Calls `Destila.Agent.EventRouter.handle_rpc/2` directly — the
  rest of the pipeline (SessionServer, ToolHandlers, Sessions) runs for real.

  Used by LiveView tests for the new agent path.
  """

  alias Destila.Agent.{EventRouter, SessionServer, Sessions}

  @doc "Subscribes the calling test process to the session's PubSub topic."
  def subscribe(session_id), do: Sessions.subscribe(session_id)

  @doc "Simulates the bridge opening the SSE channel."
  def simulate_connect(session_id) do
    {:ok, _pid} = SessionServer.ensure_started(session_id)
    SessionServer.sse_connected(session_id)
  end

  @doc "Simulates the bridge closing the SSE channel."
  def simulate_disconnect(session_id) do
    SessionServer.sse_closed(session_id)
  end

  @doc """
  Simulates a JSON-RPC tools/call frame arriving from the bridge.
  Returns the JSON-RPC reply envelope.
  """
  def simulate_tool_call(session_id, tool_name, arguments) do
    {:ok, _pid} = SessionServer.ensure_started(session_id)

    reply =
      EventRouter.handle_rpc(session_id, %{
        "jsonrpc" => "2.0",
        "id" => :erlang.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => tool_name, "arguments" => arguments}
      })

    case reply do
      %{"error" => _} = err -> {:error, err}
      %{"result" => _} -> {:ok, reply}
      :noreply -> {:ok, :noreply}
    end
  end

  def simulate_export(session_id, key, value, opts \\ []) do
    type = Keyword.get(opts, :type, "text")

    simulate_tool_call(session_id, "session", %{
      "action" => "export",
      "key" => key,
      "value" => value,
      "type" => type
    })
  end

  def simulate_phase_complete(session_id, message \\ nil) do
    simulate_tool_call(session_id, "session", %{
      "action" => "phase_complete",
      "message" => message
    })
  end

  def simulate_suggest_phase_complete(session_id, message) do
    simulate_tool_call(session_id, "session", %{
      "action" => "suggest_phase_complete",
      "message" => message
    })
  end

  def simulate_question(session_id, _question, options) do
    questions = [
      %{
        "title" => "Q",
        "question" => "Pick one",
        "multi_select" => false,
        "options" => Enum.map(options, fn opt -> %{"label" => opt, "description" => opt} end)
      }
    ]

    reply = simulate_tool_call(session_id, "ask_user_question", %{"questions" => questions})
    reply
  end
end
