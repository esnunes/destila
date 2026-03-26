defmodule DestilaWeb.ProjectInlineCreationLiveTest do
  @moduledoc """
  LiveView tests for inline project creation within the workflow wizard.
  Feature: features/project_inline_creation.feature
  """
  use DestilaWeb.ConnCase

  import Phoenix.LiveViewTest

  @feature "project_inline_creation"

  # Ensure the atom exists before tests run
  _ = :prompt_chore_task

  setup %{conn: conn} do
    # Create an existing project so #create-new-project-btn is available
    {:ok, _} =
      Destila.Projects.create_project(%{
        name: "Existing Project",
        git_repo_url: "https://github.com/test/existing"
      })

    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  describe "inline project creation" do
    @tag feature: @feature, scenario: "Create a project with a git repository URL"
    test "creates project with git URL and selects it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      view |> element("#create-new-project-btn") |> render_click()

      assert has_element?(view, "#project-name")
      assert has_element?(view, "#project-git-repo-url")
      assert has_element?(view, "#project-local-folder")

      view
      |> form("#inline-project-form", %{
        "name" => "My New Project",
        "git_repo_url" => "https://github.com/test/new-repo"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "My New Project"
      assert html =~ "border-primary"
    end

    @tag feature: @feature, scenario: "Create a project with a local folder only"
    test "creates project with local folder and selects it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "Local Project",
        "local_folder" => "/home/user/projects/local"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Local Project"
      assert html =~ "border-primary"
    end

    @tag feature: @feature, scenario: "Create a project with both git URL and local folder"
    test "creates project with both git URL and local folder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "Full Project",
        "git_repo_url" => "https://github.com/test/full",
        "local_folder" => "/home/user/projects/full"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Full Project"
      assert html =~ "border-primary"
    end

    @tag feature: @feature, scenario: "Cannot create a project without git URL or local folder"
    test "shows error when neither git URL nor local folder provided", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "No Location Project"
      })
      |> render_submit()

      assert render(view) =~ "Provide at least one"
    end

    @tag feature: @feature, scenario: "Cannot create a project without a name"
    test "shows error when name is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/prompt_chore_task")

      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "",
        "git_repo_url" => "https://github.com/test/repo"
      })
      |> render_submit()

      assert render(view) =~ "Name is required"
    end
  end
end
