defmodule Destila.Agent.Tools.SessionTool do
  @moduledoc """
  Handles the `session` tool — phase transitions and exports.
  """

  alias Destila.Agent.Sessions

  require Logger

  def execute(args, state) do
    case Map.get(args, "action") do
      "phase_complete" -> phase_complete(args, state)
      "suggest_phase_complete" -> suggest_phase_complete(args, state)
      "export" -> export(args, state)
      other -> {{:error, "unknown action: #{inspect(other)}"}, state}
    end
  end

  defp phase_complete(args, state) do
    message = Map.get(args, "message")

    safe_record_event(state.session, "session.phase_complete", %{
      tool_input: args,
      tool_result: %{"message" => message}
    })

    case Sessions.advance_phase(state.session) do
      {:ok, session} ->
        Sessions.broadcast_session(session.id, {:phase_advanced, session.current_phase_index})

        {{:ok, ack("Phase complete acknowledged.")}, %{state | session: session}}

      {:error, changeset} ->
        Logger.warning("Sessions.advance_phase failed: #{inspect(changeset.errors)}")

        {{:ok,
          %{
            "content" => [
              %{"type" => "text", "text" => "Phase advance failed; please retry."}
            ],
            "isError" => true
          }}, state}
    end
  end

  defp suggest_phase_complete(args, state) do
    message = Map.get(args, "message", "")

    safe_record_event(state.session, "session.suggest_phase_complete", %{
      tool_input: args,
      tool_result: %{"message" => message}
    })

    Sessions.broadcast_session(
      state.session.id,
      {:suggest_phase_complete, message}
    )

    {{:ok, ack("Suggestion sent to user.")}, state}
  end

  defp export(args, state) do
    key = Map.get(args, "key")
    value = Map.get(args, "value")
    type = Map.get(args, "type", "text")

    cond do
      is_nil(key) or key == "" ->
        {{:error, "export requires a key"}, state}

      is_nil(value) ->
        {{:error, "export requires a value"}, state}

      true ->
        phase_name = phase_name_for(state)

        case Sessions.record_export(state.session, %{
               phase_name: phase_name,
               key: key,
               value: %{"value" => value, "type" => type}
             }) do
          {:ok, _meta} ->
            safe_record_event(state.session, "session.export", %{
              tool_input: args,
              tool_result: %{"key" => key, "type" => type}
            })

            {{:ok, ack("Export #{key} recorded.")}, state}

          {:error, changeset} ->
            {{:error, "export failed: #{inspect(changeset.errors)}"}, state}
        end
    end
  end

  defp phase_name_for(state), do: "phase-#{state.session.current_phase_index}"

  defp safe_record_event(session, name, attrs) do
    case Sessions.record_event(session, name, attrs) do
      {:ok, event} ->
        {:ok, event}

      {:error, changeset} ->
        Logger.warning("Sessions.record_event(#{name}) failed: #{inspect(changeset.errors)}")

        :error
    end
  end

  defp ack(text) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
  end
end
