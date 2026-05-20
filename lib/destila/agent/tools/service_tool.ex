defmodule Destila.Agent.Tools.ServiceTool do
  @moduledoc """
  Delegates the `service` tool to `Destila.Services.ServiceManager`, scoped
  to the agent session's associated project (when set).
  """

  alias Destila.Agent.Sessions

  def execute(args, state) do
    action = Map.get(args, "action")

    {:ok, _event} =
      Sessions.record_event(state.session, "service.#{action}", %{
        tool_input: args,
        tool_result: %{}
      })

    case execute_action(action, state) do
      {:ok, payload} ->
        {{:ok,
          %{
            "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
            "isError" => false
          }}, state}

      {:error, reason} ->
        {{:ok,
          %{
            "content" => [%{"type" => "text", "text" => "Service error: #{inspect(reason)}"}],
            "isError" => true
          }}, state}
    end
  end

  defp execute_action(nil, _state), do: {:error, :missing_action}

  defp execute_action(action, state) when action in ["start", "stop", "restart", "status"] do
    case Sessions.get_session(state.session.id) do
      %{project_id: nil} ->
        {:error, "no project attached to agent session"}

      %{project_id: project_id} ->
        case Destila.Projects.get_project(project_id) do
          nil ->
            {:error, "project not found"}

          project ->
            try do
              case Destila.Services.ServiceManager.execute(project, String.to_atom(action), []) do
                {:ok, state_payload} -> {:ok, state_payload}
                {:error, _} = err -> err
                other -> {:ok, other}
              end
            rescue
              e -> {:error, Exception.message(e)}
            end
        end
    end
  end

  defp execute_action(action, _state), do: {:error, "unknown action: #{inspect(action)}"}
end
