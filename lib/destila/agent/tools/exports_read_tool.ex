defmodule Destila.Agent.Tools.ExportsReadTool do
  @moduledoc """
  Returns all exports recorded in this agent session, including ones from
  earlier phases. Lets a freshly-started post-handoff agent recover prior
  context without inheriting conversational state.
  """

  alias Destila.Agent.Sessions

  def execute(_args, state) do
    exports = Sessions.list_exports(state.session.id)

    payload =
      Enum.map(exports, fn meta ->
        value = meta.value || %{}

        %{
          "phase_name" => meta.phase_name,
          "phase_index" => meta.phase_index,
          "key" => meta.key,
          "value" => Map.get(value, "value", value),
          "type" => Map.get(value, "type", "text")
        }
      end)

    {:ok, _event} =
      Sessions.record_event(state.session, "exports_read", %{
        tool_input: %{},
        tool_result: %{"count" => length(payload)}
      })

    {{:ok,
      %{
        "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
        "isError" => false,
        "exports" => payload
      }}, state}
  end
end
