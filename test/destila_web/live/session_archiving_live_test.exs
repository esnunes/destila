defmodule DestilaWeb.SessionArchivingLiveTest do
  @moduledoc """
  LiveView tests for archiving and unarchiving sessions from the detail page,
  and verifying visibility on the crafting board and dashboard.
  Feature: features/session_archiving.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "session_archiving"

  setup %{conn: conn} do
    conn = post(conn, "/login", %{"email" => "test@example.com"})

    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "destila",
        git_repo_url: "https://github.com/test/destila"
      })

    {:ok, conn: conn, project: project}
  end

  defp create_session(attrs) do
    defaults = %{
      title: "Test Session",
      workflow_type: :prompt_chore_task,
      column: :request,
      steps_completed: 1,
      steps_total: 4,
      phase_status: :conversing,
      position: System.unique_integer([:positive])
    }

    {:ok, session} = Destila.WorkflowSessions.create_workflow_session(Map.merge(defaults, attrs))
    session
  end

  # --- Archiving from session detail ---

  describe "archive from session detail" do
    @tag feature: @feature, scenario: "Archive a session from the session detail page"
    test "shows Archive button and archives on click", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})

      # Add a message so mount doesn't try to start workflow
      Destila.Messages.create_message(ws.id, %{
        role: :system,
        content: "Welcome",
        phase: 1
      })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Archive button should be visible
      assert has_element?(view, "#archive-btn")
      refute has_element?(view, "#unarchive-btn")

      # Click archive
      view |> element("#archive-btn") |> render_click()

      # Flash and button swap
      assert has_element?(view, "#unarchive-btn")
      refute has_element?(view, "#archive-btn")
      assert render(view) =~ "Session archived"
    end
  end

  # --- Unarchiving from session detail ---

  describe "unarchive from session detail" do
    @tag feature: @feature, scenario: "Unarchive a session from the session detail page"
    test "shows Unarchive button and restores on click", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})

      Destila.Messages.create_message(ws.id, %{
        role: :system,
        content: "Welcome",
        phase: 1
      })

      {:ok, archived} = Destila.WorkflowSessions.archive_workflow_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{archived.id}")

      # Unarchive button should be visible
      assert has_element?(view, "#unarchive-btn")
      refute has_element?(view, "#archive-btn")

      # Click unarchive
      view |> element("#unarchive-btn") |> render_click()

      # Flash and button swap
      assert has_element?(view, "#archive-btn")
      refute has_element?(view, "#unarchive-btn")
      assert render(view) =~ "Session restored"
    end
  end

  # --- Crafting board visibility ---

  describe "crafting board visibility" do
    @tag feature: @feature, scenario: "Archived session is hidden from the crafting board"
    test "archived session is not shown on crafting board", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      Destila.WorkflowSessions.archive_workflow_session(ws)

      {:ok, _view, html} = live(conn, ~p"/crafting")

      refute html =~ "Fix login bug"
    end

    @tag feature: @feature, scenario: "Restored session reappears on the crafting board"
    test "restored session reappears on crafting board", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      {:ok, archived} = Destila.WorkflowSessions.archive_workflow_session(ws)
      Destila.WorkflowSessions.unarchive_workflow_session(archived)

      {:ok, _view, html} = live(conn, ~p"/crafting")

      assert html =~ "Fix login bug"
    end
  end

  # --- Dashboard visibility ---

  describe "dashboard visibility" do
    @tag feature: @feature, scenario: "Archived session is hidden from the dashboard"
    test "archived session is not shown on dashboard", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      Destila.WorkflowSessions.archive_workflow_session(ws)

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Fix login bug"
    end
  end
end
