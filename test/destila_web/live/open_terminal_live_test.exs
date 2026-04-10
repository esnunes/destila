defmodule DestilaWeb.OpenTerminalLiveTest do
  @moduledoc """
  LiveView tests for Open Terminal button in sidebar.
  Feature: features/exported_metadata.feature
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

  defp create_session_with_worktree(conn) do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Session",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        done_at: DateTime.utc_now(),
        current_phase: 4,
        total_phases: 4
      })

    {:ok, _ai_session} =
      Destila.AI.create_ai_session(%{
        workflow_session_id: ws.id,
        worktree_path: "/tmp/test-worktree"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
    {ws, view}
  end

  describe "open terminal button" do
    @tag feature: "exported_metadata",
         scenario: "Source code section shows open terminal button"
    test "button is present when worktree path exists", %{conn: conn} do
      {_ws, view} = create_session_with_worktree(conn)

      assert has_element?(view, "#open-terminal-btn")
    end

    @tag feature: "exported_metadata",
         scenario: "Open terminal button opens a Ghostty tab at the worktree path"
    test "clicking the button sends the open_terminal event", %{conn: conn} do
      {_ws, view} = create_session_with_worktree(conn)

      # Click the button — the System.cmd call will likely fail in test
      # (Ghostty not running), but we verify the event is handled without crash
      view |> element("#open-terminal-btn") |> render_click()

      # The LiveView should still be alive (event was handled gracefully)
      assert has_element?(view, "#open-terminal-btn")
    end
  end
end
