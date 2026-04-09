defmodule DestilaWeb.CodeChatWorkflowLiveTest do
  @moduledoc """
  LiveView tests for the Code Chat Workflow.
  Feature: features/code_chat_workflow.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "code_chat_workflow"

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

  # --- Helpers ---

  defp create_chat_session(opts \\ []) do
    pe_status = Keyword.get(opts, :pe_status, :awaiting_input)

    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "New Chat",
        workflow_type: :code_chat,
        current_phase: 1,
        total_phases: 1,
        user_prompt: "Help me refactor this module"
      })

    unless pe_status == :setup do
      {:ok, _pe} = Destila.Executions.create_phase_execution(ws, 1, %{status: pe_status})
    end

    ws
  end

  # --- Workflow Type Selection ---

  @tag feature: @feature, scenario: "Create a new Code Chat session"
  test "type selection shows Code Chat option", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workflows")

    assert html =~ "Code Chat"
    assert html =~ "Chat with AI with full access to tools and write permissions"
  end

  # --- Session rendering ---

  describe "Session rendering" do
    @tag feature: @feature, scenario: "Create a new Code Chat session"
    test "renders chat session without progress bar", %{conn: conn} do
      ws = create_chat_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Title should be visible
      assert has_element?(view, "h1", "New Chat")
      # Workflow badge should show
      html = render(view)
      assert html =~ "Code Chat"
      # Progress bar should NOT be visible (single-phase workflow)
      refute html =~ "Phase 1/1"
    end

    @tag feature: @feature, scenario: "Create a new Code Chat session"
    test "does not render phase dividers", %{conn: conn} do
      ws = create_chat_session()

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Hello! How can I help?",
          phase: 1,
          workflow_session_id: ws.id
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Should not have phase divider summary elements
      refute has_element?(view, "summary", "Phase 1")
    end

    @tag feature: @feature, scenario: "No phase transitions in Code Chat"
    test "does not show phase advance buttons", %{conn: conn} do
      ws = create_chat_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "button", "Continue to Phase")
    end
  end

  # --- Chat interaction ---

  describe "Chat interaction" do
    @tag feature: @feature, scenario: "Send messages in the chat"
    test "text input is available for sending messages", %{conn: conn} do
      ws = create_chat_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "input[name='content']")
      assert has_element?(view, "button", "Send")
    end
  end

  # --- Mark as Done ---

  describe "Mark as Done" do
    @tag feature: @feature, scenario: "Mark chat session as done"
    test "mark as done is available on phase 1 (single-phase)", %{conn: conn} do
      ws = create_chat_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#mark-done-btn")
    end

    @tag feature: @feature, scenario: "Mark chat session as done"
    test "marking as done completes the session", %{conn: conn} do
      ws = create_chat_session()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#mark-done-btn") |> render_click()

      ws = Destila.Workflows.get_workflow_session!(ws.id)
      assert Destila.Workflows.Session.done?(ws)
    end
  end

  # --- Crafting board ---

  describe "Crafting board" do
    @tag feature: @feature, scenario: "Create a new Code Chat session"
    test "shows Code Chat badge on crafting board", %{conn: conn} do
      _ws = create_chat_session()

      {:ok, _view, html} = live(conn, ~p"/crafting")
      assert html =~ "Code Chat"
    end

    @tag feature: @feature, scenario: "Create a new Code Chat session"
    test "does not show progress bar on crafting card", %{conn: conn} do
      _ws = create_chat_session()

      {:ok, view, _html} = live(conn, ~p"/crafting")

      # The card should not have a progress indicator for single-phase
      refute has_element?(view, ".h-1.bg-base-300")
    end
  end
end
