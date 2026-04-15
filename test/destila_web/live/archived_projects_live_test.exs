defmodule DestilaWeb.ArchivedProjectsLiveTest do
  @moduledoc """
  LiveView tests for Archived Projects page.
  Feature: features/project_archiving.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "project_archiving"

  setup %{conn: conn} do
    {:ok, conn: conn}
  end

  describe "archived projects page" do
    @tag feature: @feature, scenario: "View archived projects on the archived page"
    test "lists archived projects", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Old Project",
          git_repo_url: "https://github.com/test/old"
        })

      {:ok, _} = Destila.Projects.archive_project(project)

      {:ok, view, _html} = live(conn, ~p"/projects/archived")

      assert has_element?(view, "#archived-project-#{project.id}")
      assert render(view) =~ "Old Project"
    end

    @tag feature: @feature, scenario: "Archived page is empty when no projects are archived"
    test "shows empty state when no projects are archived", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/archived")

      assert has_element?(view, "#archived-empty")
      assert render(view) =~ "No archived projects"
    end

    @tag feature: @feature, scenario: "View archived projects on the archived page"
    test "back link navigates to projects page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/archived")

      assert has_element?(view, "#back-to-projects-link")
    end

    @tag feature: @feature, scenario: "View archived projects on the archived page"
    test "non-archived projects do not appear on the archived page", %{conn: conn} do
      {:ok, _project} =
        Destila.Projects.create_project(%{
          name: "Active Project",
          git_repo_url: "https://github.com/test/active"
        })

      {:ok, view, _html} = live(conn, ~p"/projects/archived")

      refute render(view) =~ "Active Project"
    end

    @tag feature: @feature, scenario: "Unarchive restores project to the active list"
    test "unarchiving removes project from archived list via PubSub", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Restore Me",
          git_repo_url: "https://github.com/test/restore"
        })

      {:ok, archived} = Destila.Projects.archive_project(project)

      {:ok, view, _html} = live(conn, ~p"/projects/archived")
      assert has_element?(view, "#archived-project-#{project.id}")

      view |> element("#unarchive-project-#{project.id}") |> render_click()

      refute has_element?(view, "#archived-project-#{archived.id}")
      assert render(view) =~ "Project restored"
    end
  end
end
