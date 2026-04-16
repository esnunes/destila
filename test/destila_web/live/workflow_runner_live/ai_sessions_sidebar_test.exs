defmodule DestilaWeb.WorkflowRunnerLive.AiSessionsSidebarTest do
  @moduledoc """
  Tests for the AI Sessions section in the WorkflowRunnerLive right sidebar.
  Feature: features/ai_sessions.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    {:ok, conn: conn}
  end

  defp create_workflow_session do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    ws
  end

  defp create_ai_session(ws_id, attrs \\ %{}) do
    {:ok, ai_session} =
      Destila.AI.create_ai_session(Map.merge(%{workflow_session_id: ws_id}, attrs))

    ai_session
  end

  defp create_message(ai_session_id, workflow_session_id) do
    {:ok, _message} =
      Destila.AI.create_message(ai_session_id, %{
        role: :user,
        content: "test message",
        workflow_session_id: workflow_session_id
      })
  end

  describe "AI sessions sidebar section" do
    @tag feature: "ai_sessions", scenario: "AI sessions list appears in the right sidebar"
    test "shows ai-sessions-section element", %{conn: conn} do
      ws = create_workflow_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-sessions-section")
    end

    @tag feature: "ai_sessions",
         scenario: "AI sessions sidebar shows empty state when no sessions exist"
    test "shows empty state when no AI sessions exist", %{conn: conn} do
      ws = create_workflow_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-sessions-empty-state")
      refute has_element?(view, "[id^='ai-session-item-']")
    end

    @tag feature: "ai_sessions", scenario: "AI sessions list appears in the right sidebar"
    test "shows session items when AI sessions exist", %{conn: conn} do
      ws = create_workflow_session()
      ai_session_1 = create_ai_session(ws.id)
      ai_session_2 = create_ai_session(ws.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-session-item-#{ai_session_1.id}")
      assert has_element?(view, "#ai-session-item-#{ai_session_2.id}")
      refute has_element?(view, "#ai-sessions-empty-state")
    end

    @tag feature: "ai_sessions", scenario: "AI sessions list appears in the right sidebar"
    test "each session item links to the detail page", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(
               view,
               ~s|#ai-session-item-#{ai_session.id}[href="/sessions/#{ws.id}/ai/#{ai_session.id}"]|
             )
    end

    @tag feature: "ai_sessions", scenario: "AI sessions list appears in the right sidebar"
    test "shows message count for each session", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)
      create_message(ai_session.id, ws.id)
      create_message(ai_session.id, ws.id)
      create_message(ai_session.id, ws.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-session-item-#{ai_session.id}")
      assert render(view) =~ "3"
    end
  end

  describe "real-time updates" do
    @tag feature: "ai_sessions",
         scenario: "AI sessions sidebar updates in real time when a new session is created"
    test "sidebar updates when a new AI session is broadcast", %{conn: conn} do
      ws = create_workflow_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-sessions-empty-state")

      # Simulate the broadcast that create_ai_session sends
      {:ok, ai_session} =
        Destila.AI.create_ai_session(%{workflow_session_id: ws.id})

      # Give the LiveView process time to handle the broadcast
      :sys.get_state(view.pid)

      assert has_element?(view, "#ai-session-item-#{ai_session.id}")
      refute has_element?(view, "#ai-sessions-empty-state")
    end

    @tag feature: "ai_sessions",
         scenario: "AI sessions sidebar updates in real time when a new session is created"
    test "sidebar does not update when broadcast is for a different workflow session", %{
      conn: conn
    } do
      ws = create_workflow_session()
      other_ws = create_workflow_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#ai-sessions-empty-state")

      # Create an AI session for the OTHER workflow session
      {:ok, _ai_session} =
        Destila.AI.create_ai_session(%{workflow_session_id: other_ws.id})

      :sys.get_state(view.pid)

      # The sidebar for ws should still show empty state
      assert has_element?(view, "#ai-sessions-empty-state")
    end

    @tag feature: "ai_sessions",
         scenario: "AI sessions sidebar updates in real time when a new session is created"
    test "sidebar message count updates when a message is added", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Initial state - 0 messages
      assert has_element?(view, "#ai-session-item-#{ai_session.id}")

      # Add a message via the context function which broadcasts
      {:ok, _msg} =
        Destila.AI.create_message(ai_session.id, %{
          role: :user,
          content: "new message",
          workflow_session_id: ws.id
        })

      :sys.get_state(view.pid)

      # The count badge should now show 1 within the session item
      assert has_element?(view, "#ai-session-item-#{ai_session.id}", "1")
    end
  end
end
