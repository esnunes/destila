defmodule Destila.AI.FakeHistory do
  @moduledoc """
  Test stand-in for `ClaudeCode.History`. Tests call `stub/2` to register
  canned responses for a session id, then set the application env so the
  `Destila.AI.History` adapter calls this module.

  Uses ETS for storage so tests can read back what was stubbed without
  owning an Agent process.
  """

  @table :destila_fake_history

  def ensure_started do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _ -> @table
    end
  end

  @doc """
  Registers a canned response for `get_messages/2`.

  `response` is returned verbatim.
  """
  def stub(session_id, response) when is_binary(session_id) do
    ensure_started()
    :ets.insert(@table, {{:messages, session_id}, response})
    :ok
  end

  @doc """
  Registers a canned response for `read_all/2`.
  """
  def stub_raw(session_id, response) when is_binary(session_id) do
    ensure_started()
    :ets.insert(@table, {{:raw, session_id}, response})
    :ok
  end

  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  def get_messages(session_id, opts \\ []) do
    ensure_started()

    response =
      case :ets.lookup(@table, {:messages, session_id}) do
        [{_, response}] -> response
        [] -> {:ok, []}
      end

    apply_offset(response, Keyword.get(opts, :offset, 0))
  end

  def read_all(session_id, _opts \\ []) do
    ensure_started()

    case :ets.lookup(@table, {:raw, session_id}) do
      [{_, response}] ->
        response

      [] ->
        # Fall back to `stub/2` data so tests that only stub messages still work.
        case :ets.lookup(@table, {:messages, session_id}) do
          [{_, response}] -> response
          [] -> {:ok, []}
        end
    end
  end

  defp apply_offset({:ok, messages}, offset) when is_integer(offset) and offset > 0,
    do: {:ok, Enum.drop(messages, offset)}

  defp apply_offset(response, _offset), do: response
end
