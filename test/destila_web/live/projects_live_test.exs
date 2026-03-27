defmodule DestilaWeb.ProjectsLiveTest do
  @moduledoc """
  LiveView tests for Project Management.
  Feature: features/project_management.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "project_management"

  setup %{conn: conn} do
    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  describe "project list" do
    @tag feature: @feature, scenario: "View list of projects"
    test "shows existing projects", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "My Project",
          git_repo_url: "https://github.com/test/repo"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert render(view) =~ "My Project"
      assert render(view) =~ "https://github.com/test/repo"
      assert has_element?(view, "#edit-project-#{project.id}")
    end

    @tag feature: @feature, scenario: "View list of projects"
    test "shows empty state when no projects exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert render(view) =~ "No projects yet"
    end
  end

  describe "create project" do
    @tag feature: @feature, scenario: "Create a new project with git repository URL"
    test "creates a project with git URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()
      assert has_element?(view, "#create-project-card")

      view
      |> form("#project-form-create_project", %{
        "name" => "New Project",
        "git_repo_url" => "https://github.com/new/repo"
      })
      |> render_submit()

      assert render(view) =~ "New Project"
      refute has_element?(view, "#create-project-card")
    end

    @tag feature: @feature, scenario: "Create a new project with local folder only"
    test "creates a project with local folder only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      view
      |> form("#project-form-create_project", %{
        "name" => "Local Project",
        "local_folder" => "/path/to/project"
      })
      |> render_submit()

      assert render(view) =~ "Local Project"
    end

    @tag feature: @feature, scenario: "Create a new project with both git URL and local folder"
    test "creates a project with both git URL and local folder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      view
      |> form("#project-form-create_project", %{
        "name" => "Full Project",
        "git_repo_url" => "https://github.com/full/repo",
        "local_folder" => "/path/to/full"
      })
      |> render_submit()

      assert render(view) =~ "Full Project"
    end

    @tag feature: @feature, scenario: "Cannot create a project without git URL or local folder"
    test "shows error when neither git URL nor local folder provided", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      view
      |> form("#project-form-create_project", %{"name" => "Incomplete"})
      |> render_submit()

      assert render(view) =~ "Provide at least one"
    end

    @tag feature: @feature, scenario: "Cannot create a project without a name"
    test "shows error when name is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      view
      |> form("#project-form-create_project", %{
        "name" => "",
        "git_repo_url" => "https://github.com/test/repo"
      })
      |> render_submit()

      assert render(view) =~ "Name is required"
    end
  end

  describe "edit project" do
    @tag feature: @feature, scenario: "Edit an existing project"
    test "edits an existing project", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Original Name",
          git_repo_url: "https://github.com/test/repo"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#edit-project-#{project.id}") |> render_click()
      assert has_element?(view, "#project-form-update_project")

      view
      |> form("#project-form-update_project", %{"name" => "Updated Name"})
      |> render_submit()

      assert render(view) =~ "Updated Name"
    end

    @tag feature: @feature, scenario: "Cannot save an edited project with invalid data"
    test "shows validation errors when all fields are cleared", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Original Name",
          git_repo_url: "https://github.com/test/repo"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#edit-project-#{project.id}") |> render_click()

      view
      |> form("#project-form-update_project", %{
        "name" => "",
        "git_repo_url" => "",
        "local_folder" => ""
      })
      |> render_submit()

      assert render(view) =~ "Name is required"
      assert render(view) =~ "Provide at least one"
    end
  end

  describe "delete project" do
    @tag feature: @feature, scenario: "Delete a project not linked to any sessions"
    test "deletes a project not linked to sessions", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Deletable Project",
          git_repo_url: "https://github.com/test/repo"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert render(view) =~ "Deletable Project"

      view |> element("#delete-project-#{project.id}") |> render_click()
      view |> element("#confirm-delete-#{project.id}") |> render_click()

      refute render(view) =~ "Deletable Project"
    end

    @tag feature: @feature, scenario: "Cannot delete a project linked to sessions"
    test "cannot delete a project linked to sessions", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Linked Project",
          git_repo_url: "https://github.com/test/repo"
        })

      {:ok, _ws} =
        Destila.Workflows.create_workflow_session(%{
          title: "Test Prompt",
          project_id: project.id,
          workflow_type: :prompt_chore_task,
          total_phases: 6
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#delete-project-#{project.id}") |> render_click()
      view |> element("#confirm-delete-#{project.id}") |> render_click()

      assert render(view) =~ "Cannot delete this project while it is linked to sessions"
      assert render(view) =~ "Linked Project"
    end
  end
end
