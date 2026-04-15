defmodule DestilaWeb.AiSessionLiveTest do
  @moduledoc """
  LiveView tests for AI session detail page.
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
      Destila.AI.create_ai_session(
        Map.merge(
          %{workflow_session_id: ws_id, claude_session_id: "test-claude-session-id"},
          attrs
        )
      )

    ai_session
  end

  defp create_message(ai_session_id, workflow_session_id, content) do
    {:ok, message} =
      Destila.AI.create_message(ai_session_id, %{
        role: :user,
        content: content,
        workflow_session_id: workflow_session_id
      })

    message
  end

  describe "AI session detail page" do
    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "renders session created_at and claude_session_id", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai_session.id}")

      assert has_element?(view, "#ai-session-created-at")
      assert has_element?(view, "#ai-session-claude-id")
    end

    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "shows all messages in chronological order", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)
      create_message(ai_session.id, ws.id, "first message")
      create_message(ai_session.id, ws.id, "second message")
      create_message(ai_session.id, ws.id, "third message")

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai_session.id}")

      assert has_element?(view, "#ai-session-messages")
      html = render(view)
      assert html =~ "first message"
      assert html =~ "second message"
      assert html =~ "third message"

      # Verify ordering by checking positions
      first_pos = :binary.match(html, "first message") |> elem(0)
      second_pos = :binary.match(html, "second message") |> elem(0)
      third_pos = :binary.match(html, "third message") |> elem(0)
      assert first_pos < second_pos
      assert second_pos < third_pos
    end

    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "renders messages stream container with no items when session has no messages", %{
      conn: conn
    } do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai_session.id}")

      assert has_element?(view, "#ai-session-messages")
    end

    @tag feature: "ai_sessions",
         scenario: "AI session detail page has a back button to the workflow session"
    test "renders back link pointing to workflow session", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai_session.id}")

      assert has_element?(view, ~s|a[href="/sessions/#{ws.id}"]|)
    end

    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "shows claude_session_id value in the metadata block", %{conn: conn} do
      ws = create_workflow_session()
      ai_session = create_ai_session(ws.id, %{claude_session_id: "my-specific-session-id"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/ai/#{ai_session.id}")

      assert render(view) =~ "my-specific-session-id"
    end
  end

  describe "error paths" do
    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "redirects away when workflow session is not found", %{conn: conn} do
      fake_ws_id = Ecto.UUID.generate()
      fake_ai_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/crafting"}}} =
               live(conn, ~p"/sessions/#{fake_ws_id}/ai/#{fake_ai_id}")
    end

    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "redirects to session when ai session is not found", %{conn: conn} do
      ws = create_workflow_session()
      fake_ai_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/sessions/" <> _}}} =
               live(conn, ~p"/sessions/#{ws.id}/ai/#{fake_ai_id}")
    end

    @tag feature: "ai_sessions",
         scenario: "AI session detail page shows session metadata and messages"
    test "redirects to session when ai session belongs to a different workflow session", %{
      conn: conn
    } do
      ws1 = create_workflow_session()
      ws2 = create_workflow_session()
      ai_session = create_ai_session(ws2.id)

      assert {:error, {:live_redirect, %{to: "/sessions/" <> _}}} =
               live(conn, ~p"/sessions/#{ws1.id}/ai/#{ai_session.id}")
    end
  end
end
