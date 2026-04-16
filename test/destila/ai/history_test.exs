defmodule Destila.AI.BadHistory do
  @moduledoc false
  def get_messages(_id, _opts), do: raise("boom")
end

defmodule Destila.AI.HistoryTest do
  use ExUnit.Case, async: false

  alias ClaudeCode.History.SessionMessage
  alias Destila.AI.{BadHistory, FakeHistory, History}

  setup do
    FakeHistory.reset()
    :ok
  end

  test "returns stubbed messages for a known session id" do
    session_id = Ecto.UUID.generate()
    msg = %SessionMessage{type: :assistant, uuid: "u1", session_id: session_id, message: %{}}
    FakeHistory.stub(session_id, {:ok, [msg]})

    assert {:ok, [^msg]} = History.get_messages(session_id)
  end

  test "returns ok empty when no stub is registered" do
    assert {:ok, []} = History.get_messages(Ecto.UUID.generate())
  end

  test "propagates error tuples from the underlying implementation" do
    session_id = Ecto.UUID.generate()
    FakeHistory.stub(session_id, {:error, :enoent})

    assert {:error, :enoent} = History.get_messages(session_id)
  end

  test "rescues exceptions from the underlying implementation" do
    previous = Application.get_env(:destila, :ai_history_module)
    Application.put_env(:destila, :ai_history_module, BadHistory)

    on_exit(fn ->
      if previous do
        Application.put_env(:destila, :ai_history_module, previous)
      else
        Application.delete_env(:destila, :ai_history_module)
      end
    end)

    assert {:error, {:exception, _}} = History.get_messages("abc")
  end
end
