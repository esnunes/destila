defmodule Destila.Agent.ExternalHost do
  @moduledoc """
  External host mode: the user runs `claude` on their own machine. Destila
  has no stdin channel, so kickoff prompts and `ask_user_question` answers
  are surfaced for the user to paste.

  This module is intentionally side-effect-light — it computes connection
  info and emits PubSub events for the LiveView to render.
  """

  alias Destila.Agent.Sessions

  @doc """
  Returns connection info the user needs to wire up an external `claude` CLI:
  bridge binary path, global token, server URL, and the session id env var name.
  """
  def connection_info(session_id) do
    %{
      bridge_path: Application.get_env(:destila, :mcp_bridge_path, "destila-mcp"),
      token: Application.fetch_env!(:destila, :mcp_token),
      mcp_url:
        System.get_env("DESTILA_MCP_URL") ||
          "http://127.0.0.1:#{port_from_env()}/mcp",
      session_id: session_id,
      session_env_var: "DESTILA_SESSION_ID"
    }
  end

  @doc """
  Surface a kickoff prompt for paste by broadcasting a `:paste_target` PubSub
  event to the session topic.
  """
  def queue_kickoff(session_id, kickoff_prompt) do
    Sessions.broadcast_session(
      session_id,
      {:paste_target, %{kind: :kickoff, value: kickoff_prompt}}
    )

    :ok
  end

  def queue_answer(session_id, value) do
    Sessions.broadcast_session(
      session_id,
      {:paste_target, %{kind: :answer, value: value}}
    )

    :ok
  end

  defp port_from_env do
    case Application.get_env(:destila, DestilaWeb.Endpoint) do
      nil -> "4000"
      endpoint -> endpoint |> Keyword.get(:http, []) |> Keyword.get(:port, 4000) |> to_string()
    end
  end
end
