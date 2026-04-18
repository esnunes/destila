defmodule DestilaWeb.ArchivedSessionsLiveTest do
  @moduledoc """
  LiveView tests for the Archived Sessions page.
  Feature: features/session_archiving.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "session_archiving"

  setup %{conn: conn} do
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
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4,
      position: System.unique_integer([:positive])
    }

    {:ok, session} = Destila.Workflows.insert_workflow_session(Map.merge(defaults, attrs))
    session
  end

  defp archive_session(session) do
    {:ok, archived} = Destila.Workflows.archive_workflow_session(session)
    archived
  end

  describe "archived sessions page" do
    @tag feature: @feature, scenario: "View archived sessions on a dedicated page"
    test "lists archived sessions with title, project, and workflow type", %{
      conn: conn,
      project: project
    } do
      ws1 = create_session(%{title: "Fix login bug", project_id: project.id})
      ws2 = create_session(%{title: "Refactor auth", project_id: project.id})
      archive_session(ws1)
      archive_session(ws2)

      {:ok, _view, html} = live(conn, ~p"/sessions/archived")

      assert html =~ "Fix login bug"
      assert html =~ "Refactor auth"
      assert html =~ "destila"
    end

    @tag feature: @feature, scenario: "Archived page is empty when no sessions are archived"
    test "shows empty state when no sessions are archived", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sessions/archived")

      assert has_element?(view, "#archived-empty")
    end

    @tag feature: @feature, scenario: "Navigate to archived session detail from archived page"
    test "clicking a session navigates to detail page", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      archived = archive_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/archived")

      assert has_element?(view, "a[href='/sessions/#{archived.id}']")
    end

    @tag feature: @feature, scenario: "View archived sessions on a dedicated page"
    test "does not show non-archived sessions", %{conn: conn, project: project} do
      _active = create_session(%{title: "Active Session", project_id: project.id})
      archived = create_session(%{title: "Archived Session", project_id: project.id})
      archive_session(archived)

      {:ok, _view, html} = live(conn, ~p"/sessions/archived")

      assert html =~ "Archived Session"
      refute html =~ "Active Session"
    end

    @tag feature: @feature, scenario: "View archived sessions on a dedicated page"
    test "updates in real time when a session is unarchived", %{conn: conn, project: project} do
      ws = create_session(%{title: "Soon Restored", project_id: project.id})
      archived = archive_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/archived")
      assert has_element?(view, "#archived-session-#{archived.id}")

      # Unarchive it
      Destila.Workflows.unarchive_workflow_session(archived)

      # Should disappear from the archived list
      refute has_element?(view, "#archived-session-#{archived.id}")
    end

    @tag feature: "session_deletion",
         scenario: "Deleted session is hidden from the archived sessions page"
    test "deleted archived session is not listed", %{conn: conn, project: project} do
      ws = create_session(%{title: "Archived and Deleted", project_id: project.id})
      archived = archive_session(ws)
      {:ok, _} = Destila.Workflows.delete_workflow_session(archived)

      {:ok, view, _html} = live(conn, ~p"/sessions/archived")

      refute has_element?(view, "#archived-session-#{archived.id}")
    end
  end
end
