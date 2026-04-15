defmodule Destila.AIContextTest do
  @moduledoc """
  Tests for Destila.AI context functions that require database access.
  """
  use DestilaWeb.ConnCase, async: false

  alias Destila.AI
  alias Destila.Workflows

  defp create_workflow_session do
    {:ok, ws} =
      Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    ws
  end

  defp create_ai_session(ws_id, attrs \\ %{}) do
    {:ok, ai_session} =
      AI.create_ai_session(Map.merge(%{workflow_session_id: ws_id}, attrs))

    ai_session
  end

  defp create_message(ai_session_id, workflow_session_id, attrs) do
    {:ok, message} =
      AI.create_message(
        ai_session_id,
        Map.merge(
          %{
            role: :user,
            content: "test message",
            workflow_session_id: workflow_session_id
          },
          attrs
        )
      )

    message
  end

  describe "list_ai_sessions_for_workflow/1" do
    test "returns empty list when no AI sessions exist" do
      ws = create_workflow_session()
      assert AI.list_ai_sessions_for_workflow(ws.id) == []
    end

    test "returns sessions with correct message counts ordered by inserted_at" do
      ws = create_workflow_session()
      ai_session_1 = create_ai_session(ws.id, %{claude_session_id: "sess-1"})
      ai_session_2 = create_ai_session(ws.id, %{claude_session_id: "sess-2"})

      create_message(ai_session_1.id, ws.id, %{content: "msg 1"})
      create_message(ai_session_1.id, ws.id, %{content: "msg 2"})
      create_message(ai_session_1.id, ws.id, %{content: "msg 3"})

      result = AI.list_ai_sessions_for_workflow(ws.id)

      assert length(result) == 2

      first = Enum.find(result, &(&1.id == ai_session_1.id))
      second = Enum.find(result, &(&1.id == ai_session_2.id))

      assert first.message_count == 3
      assert second.message_count == 0

      assert first.claude_session_id == "sess-1"
      assert second.claude_session_id == "sess-2"

      [r1, r2] = result
      assert DateTime.compare(r1.inserted_at, r2.inserted_at) in [:lt, :eq]
    end

    test "does not include sessions from other workflow sessions" do
      ws1 = create_workflow_session()
      ws2 = create_workflow_session()
      create_ai_session(ws1.id)
      create_ai_session(ws2.id)

      result = AI.list_ai_sessions_for_workflow(ws1.id)
      assert length(result) == 1
    end
  end

  describe "get_ai_session/1" do
    test "returns the session when it exists" do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      assert %Destila.AI.Session{} = AI.get_ai_session(ai_session.id)
      assert AI.get_ai_session(ai_session.id).id == ai_session.id
    end

    test "returns nil when session does not exist" do
      assert AI.get_ai_session(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_ai_session!/1" do
    test "returns the session for a known id" do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      result = AI.get_ai_session!(ai_session.id)
      assert result.id == ai_session.id
    end

    test "raises Ecto.NoResultsError for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        AI.get_ai_session!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_messages_for_ai_session/1" do
    test "returns messages in inserted_at ascending order" do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      create_message(ai_session.id, ws.id, %{content: "first"})
      create_message(ai_session.id, ws.id, %{content: "second"})
      create_message(ai_session.id, ws.id, %{content: "third"})

      messages = AI.list_messages_for_ai_session(ai_session.id)
      assert length(messages) == 3
      contents = Enum.map(messages, & &1.content)
      assert contents == ["first", "second", "third"]
    end

    test "returns empty list for a session with no messages" do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      assert AI.list_messages_for_ai_session(ai_session.id) == []
    end
  end

  describe "create_ai_session/1 broadcast" do
    test "broadcasts :ai_session_created on store:updates after successful insert" do
      Phoenix.PubSub.subscribe(Destila.PubSub, "store:updates")
      ws = create_workflow_session()

      {:ok, ai_session} =
        AI.create_ai_session(%{workflow_session_id: ws.id, claude_session_id: "broadcast-test"})

      assert_receive {:ai_session_created, ^ai_session}
    end
  end
end
