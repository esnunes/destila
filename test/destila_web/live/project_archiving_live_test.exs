defmodule DestilaWeb.ProjectArchivingLiveTest do
  @moduledoc """
  Integration tests for project archiving across pages.
  Feature: features/project_archiving.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "project_archiving"

  setup %{conn: conn} do
    {:ok, conn: conn}
  end

  describe "archive from projects page" do
    @tag feature: @feature, scenario: "Archive a project from the projects page"
    test "archive a project with confirmation, flash, and removal from list", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Archive Me",
          git_repo_url: "https://github.com/test/archive"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert render(view) =~ "Archive Me"

      view |> element("#archive-project-#{project.id}") |> render_click()
      assert has_element?(view, "#confirm-archive-#{project.id}")

      view |> element("#confirm-archive-#{project.id}") |> render_click()

      assert render(view) =~ "Project archived"
      refute render(view) =~ "Archive Me"
    end

    @tag feature: @feature, scenario: "Cancel archive confirmation"
    test "cancel archive confirmation returns to normal state", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Keep Me",
          git_repo_url: "https://github.com/test/keep"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#archive-project-#{project.id}") |> render_click()
      assert has_element?(view, "#confirm-archive-#{project.id}")

      view |> element("button", "Cancel") |> render_click()
      refute has_element?(view, "#confirm-archive-#{project.id}")
      assert has_element?(view, "#archive-project-#{project.id}")
    end
  end

  describe "unarchive from archived page" do
    @tag feature: @feature, scenario: "Unarchive restores project to the active list"
    test "unarchive a project and verify it reappears on the projects page", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Restore Project",
          git_repo_url: "https://github.com/test/restore"
        })

      {:ok, _} = Destila.Projects.archive_project(project)

      {:ok, archived_view, _html} = live(conn, ~p"/projects/archived")
      assert render(archived_view) =~ "Restore Project"

      archived_view |> element("#unarchive-project-#{project.id}") |> render_click()
      assert render(archived_view) =~ "Project restored"
      refute render(archived_view) =~ "Restore Project"

      {:ok, projects_view, _html} = live(conn, ~p"/projects")
      assert render(projects_view) =~ "Restore Project"
    end
  end

  describe "archived projects excluded from session creation" do
    @tag feature: @feature,
         scenario: "Archived project not shown in session creation project selector"
    test "archived project does not appear in session creation project selector", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Hidden Project",
          git_repo_url: "https://github.com/test/hidden"
        })

      {:ok, _} = Destila.Projects.archive_project(project)

      {:ok, view, _html} = live(conn, ~p"/workflows/brainstorm_idea")

      refute render(view) =~ "Hidden Project"
    end
  end

  describe "archiving does not affect linked sessions" do
    @tag feature: @feature, scenario: "Archiving a project does not affect its linked sessions"
    test "archiving a project does not affect its linked sessions on the crafting board", %{
      conn: conn
    } do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Session Project",
          git_repo_url: "https://github.com/test/sessions"
        })

      {:ok, _ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "Test Session",
          project_id: project.id,
          workflow_type: :brainstorm_idea,
          total_phases: 4
        })

      {:ok, _} = Destila.Projects.archive_project(project)

      {:ok, view, _html} = live(conn, ~p"/crafting")
      assert render(view) =~ "Test Session"
    end
  end

  describe "archived projects link" do
    @tag feature: @feature, scenario: "Navigate to archived projects page"
    test "archived link is visible on the projects page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(view, "#archived-projects-link")
    end
  end
end
