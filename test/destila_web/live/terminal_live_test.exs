defmodule DestilaWeb.TerminalLiveTest do
  @moduledoc """
  LiveView tests for in-browser terminal.
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
        title: "Test Terminal Session",
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

    ws
  end

  describe "terminal page" do
    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "mounts and shows terminal container", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert has_element?(view, ".terminal-window")
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "shows back link to session page", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert has_element?(view, ~s(a[href="/sessions/#{ws.id}"]))
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "displays worktree path in header", %{conn: conn} do
      ws = create_session_with_worktree()
      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}/terminal")

      assert html =~ "/tmp/test-worktree"
    end

    @tag feature: "exported_metadata",
         scenario: "Terminal page renders an interactive terminal"
    test "redirects when session has no worktree path", %{conn: conn} do
      {:ok, ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "No Worktree",
          workflow_type: :brainstorm_idea,
          project_id: nil,
          done_at: DateTime.utc_now(),
          current_phase: 4,
          total_phases: 4
        })

      assert {:error, {:live_redirect, %{to: "/sessions/" <> _}}} =
               live(conn, ~p"/sessions/#{ws.id}/terminal")
    end
  end
end
