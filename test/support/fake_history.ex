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
  Registers a canned response for a session id.

  `response` is returned verbatim from `get_messages/2`.
  """
  def stub(session_id, response) when is_binary(session_id) do
    ensure_started()
    :ets.insert(@table, {session_id, response})
    :ok
  end

  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  def get_messages(session_id, _opts \\ []) do
    ensure_started()

    case :ets.lookup(@table, session_id) do
      [{^session_id, response}] -> response
      [] -> {:ok, []}
    end
  end
end
