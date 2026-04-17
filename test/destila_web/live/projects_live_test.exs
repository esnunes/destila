defmodule DestilaWeb.ProjectsLiveTest do
  @moduledoc """
  LiveView tests for Project Management.
  Feature: features/project_management.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "project_management"

  setup %{conn: conn} do
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
      |> form("#project-form-create-form", %{
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
      |> form("#project-form-create-form", %{
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
      |> form("#project-form-create-form", %{
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
      |> form("#project-form-create-form", %{"name" => "Incomplete"})
      |> render_submit()

      assert render(view) =~ "provide at least one"
    end

    @tag feature: @feature, scenario: "Cannot create a project without a name"
    test "shows error when name is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      view
      |> form("#project-form-create-form", %{
        "name" => "",
        "git_repo_url" => "https://github.com/test/repo"
      })
      |> render_submit()

      assert render(view) =~ "can&#39;t be blank"
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
      assert has_element?(view, "#project-form-#{project.id}-form")

      view
      |> form("#project-form-#{project.id}-form", %{"name" => "Updated Name"})
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
      |> form("#project-form-#{project.id}-form", %{
        "name" => "",
        "git_repo_url" => "",
        "local_folder" => ""
      })
      |> render_submit()

      assert render(view) =~ "can&#39;t be blank"
      assert render(view) =~ "provide at least one"
    end
  end

  describe "run configuration" do
    @tag feature: @feature, scenario: "Create a project with run command and port definitions"
    test "creates a project with run command and port definitions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      # Add a port definition
      view |> element("#project-form-create-add-port-btn") |> render_click()
      assert has_element?(view, "#project-form-create-port-input-0")

      view
      |> form("#project-form-create-form", %{
        "name" => "Service Project",
        "git_repo_url" => "https://github.com/test/service",
        "run_command" => "mix phx.server"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Service Project"
      assert html =~ "mix phx.server"
    end

    @tag feature: @feature, scenario: "Edit a project's run configuration"
    test "edits a project's run configuration", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Run Config Project",
          git_repo_url: "https://github.com/test/repo",
          run_command: "npm start"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#edit-project-#{project.id}") |> render_click()

      # Verify run command is pre-filled
      assert has_element?(view, "#project-form-#{project.id}-run-command")

      view
      |> form("#project-form-#{project.id}-form", %{
        "run_command" => "mix phx.server"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "mix phx.server"
    end

    @tag feature: @feature, scenario: "Create a project with a setup command"
    test "creates a project with setup and run commands", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      view
      |> form("#project-form-create-form", %{
        "name" => "Setup Project",
        "git_repo_url" => "https://github.com/test/setup",
        "setup_command" => "mix deps.get",
        "run_command" => "mix phx.server"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Setup Project"
      assert html =~ "mix deps.get"
      assert html =~ "mix phx.server"
    end

    @tag feature: @feature, scenario: "Edit a project's setup command"
    test "edits a project's setup command", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Setup Edit Project",
          git_repo_url: "https://github.com/test/repo",
          setup_command: "bundle install",
          run_command: "bin/rails server"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      assert render(view) =~ "bundle install"

      view |> element("#edit-project-#{project.id}") |> render_click()

      assert has_element?(view, "#project-form-#{project.id}-setup-command")

      view
      |> form("#project-form-#{project.id}-form", %{"setup_command" => "bundle install --jobs=4"})
      |> render_submit()

      assert render(view) =~ "bundle install --jobs=4"
    end

    @tag feature: @feature,
         scenario: "A project without a setup command keeps its current behavior"
    test "card omits setup row when setup_command is blank", %{conn: conn} do
      {:ok, _project} =
        Destila.Projects.create_project(%{
          name: "No Setup Project",
          git_repo_url: "https://github.com/test/repo",
          run_command: "mix phx.server"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      html = render(view)
      assert html =~ "mix phx.server"
      refute html =~ "hero-wrench"
    end

    @tag feature: @feature, scenario: "Edit a project's setup command"
    test "clearing setup_command removes it from the card", %{conn: conn} do
      {:ok, project} =
        Destila.Projects.create_project(%{
          name: "Clearable Setup",
          git_repo_url: "https://github.com/test/repo",
          setup_command: "mix deps.get"
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#edit-project-#{project.id}") |> render_click()

      view
      |> form("#project-form-#{project.id}-form", %{"setup_command" => ""})
      |> render_submit()

      refute render(view) =~ "mix deps.get"

      reloaded = Destila.Projects.get_project(project.id)
      assert is_nil(reloaded.setup_command)
    end

    @tag feature: @feature,
         scenario: "Port definitions require a valid environment variable name"
    test "shows error for invalid port definition name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#new-project-btn") |> render_click()

      # Add a port and set an invalid value
      view |> element("#project-form-create-add-port-btn") |> render_click()

      view
      |> element("#project-form-create-port-input-0")
      |> render_blur(%{"index" => "0", "value" => "invalid-port"})

      view
      |> form("#project-form-create-form", %{
        "name" => "Bad Port Project",
        "git_repo_url" => "https://github.com/test/repo"
      })
      |> render_submit()

      assert render(view) =~ "must start with A-Z"
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
        Destila.Workflows.insert_workflow_session(%{
          title: "Test Prompt",
          project_id: project.id,
          workflow_type: :brainstorm_idea,
          total_phases: 4
        })

      {:ok, view, _html} = live(conn, ~p"/projects")

      view |> element("#delete-project-#{project.id}") |> render_click()
      view |> element("#confirm-delete-#{project.id}") |> render_click()

      assert render(view) =~ "Cannot delete this project while it is linked to sessions"
      assert render(view) =~ "Linked Project"
    end
  end
end
