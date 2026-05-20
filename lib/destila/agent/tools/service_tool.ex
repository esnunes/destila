defmodule Destila.Agent.Tools.ServiceTool do
  @moduledoc """
  Service tool stub for the agent path.

  The chat-path `Destila.Services.ServiceManager.execute/3` expects a
  workflow-session-shaped struct. Wiring the agent path to that helper
  requires either a refactor of `ServiceManager` to accept agent sessions
  or a new `execute_for_agent_session/3` entry point — both larger than the
  scope of this commit. Until then this handler returns a typed error so
  the agent gets a clear signal instead of a runtime crash.
  """

  alias Destila.Agent.Sessions

  @valid_actions ~w(start stop restart status)

  def execute(args, state) do
    action = Map.get(args, "action")

    {:ok, _event} =
      Sessions.record_event(state.session, "service.#{action || "unknown"}", %{
        tool_input: args,
        tool_result: %{"status" => "not_implemented"}
      })

    cond do
      action not in @valid_actions ->
        {{:ok,
          %{
            "content" => [
              %{"type" => "text", "text" => "Unknown service action: #{inspect(action)}"}
            ],
            "isError" => true
          }}, state}

      is_nil(state.session.project_id) ->
        {{:ok,
          %{
            "content" => [
              %{"type" => "text", "text" => "Agent session has no attached project."}
            ],
            "isError" => true
          }}, state}

      true ->
        {{:ok,
          %{
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  "service.#{action} is not yet wired for MCP-driven sessions. " <>
                    "Use the existing chat-path workflow runner for service management."
              }
            ],
            "isError" => true
          }}, state}
    end
  end
end
