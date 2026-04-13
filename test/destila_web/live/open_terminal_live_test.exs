defmodule DestilaWeb.OpenTerminalLiveTest do
  @moduledoc """
  LiveView tests for terminal link in sidebar and terminal page.
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

  defp create_session_with_worktree do
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
        worktree_path: System.tmp_dir!()
      })

    ws
  end

  describe "terminal link in session sidebar" do
    @tag feature: "exported_metadata",
         scenario: "Source code section shows terminal toggle button"
    test "link is present when worktree path exists", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#open-terminal-btn")
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal toggle opens an inline xterm.js terminal"
    test "link navigates to terminal page", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, ~s|#open-terminal-btn[href="/sessions/#{ws.id}/terminal"]|)
    end
  end

  describe "terminal page" do
    @tag feature: "exported_metadata",
         scenario: "Terminal toggle opens an inline xterm.js terminal"
    test "mounts and shows terminal panel", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert has_element?(view, "#terminal-panel-#{ws.id}")
    end
  end
end
