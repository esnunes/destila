defmodule DestilaWeb.NewPromptLiveTest do
  @moduledoc """
  LiveView tests for the Create Prompt Wizard.
  Feature: features/create_prompt_wizard.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "create_prompt_wizard"

  setup %{conn: conn} do
    # Shared mode so spawned Tasks can access the stub
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("Test Title"),
        ClaudeCode.Test.result("Test Title")
      ]
    end)

    # Log in to establish session
    conn = post(conn, "/login", %{"email" => "test@example.com"})

    # Create a test project for selection tests
    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "Test Project",
        git_repo_url: "https://github.com/test/repo"
      })

    {:ok, conn: conn, project: project}
  end

  describe "step 1 - workflow type selection" do
    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "shows three step indicators and three workflow type options", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      # Three step indicators
      assert view |> element(".flex.items-center.justify-center.gap-2") |> has_element?()

      # Three workflow type options
      assert has_element?(view, "button[phx-value-type='feature_request']")
      assert has_element?(view, "button[phx-value-type='chore_task']")
      assert has_element?(view, "button[phx-value-type='project']")
    end
  end

  describe "step 2 - project selection" do
    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "shows project selection after selecting a workflow type", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()

      assert has_element?(view, "#project-#{project.id}")
    end

    @tag feature: @feature, scenario: "Project is required for non-Project workflow types"
    test "skip button is not available for non-Project types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()

      refute has_element?(view, "#skip-project-btn")
    end

    @tag feature: @feature, scenario: "Project is required for non-Project workflow types"
    test "shows error when continuing without selecting a project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='chore_task']") |> render_click()
      view |> element("#continue-project-btn") |> render_click()

      assert render(view) =~ "select a project"
    end

    @tag feature: @feature, scenario: "Skip project for Project workflow type"
    test "skip button is available for Project type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()

      assert has_element?(view, "#skip-project-btn")
    end

    @tag feature: @feature, scenario: "Skip project for Project workflow type"
    test "skipping project for Project type advances to step 3", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("#skip-project-btn") |> render_click()

      assert has_element?(view, "#initial_idea")
    end

    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "selecting a project and continuing advances to step 3", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#continue-project-btn") |> render_click()

      assert has_element?(view, "#initial_idea")
    end

    @tag feature: @feature, scenario: "Create a new project inline during step 2"
    test "inline project creation creates and selects the project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#create-new-project-btn") |> render_click()

      assert has_element?(view, "#inline-project-form")

      view
      |> form("#inline-project-form", %{
        "name" => "New Inline Project",
        "git_repo_url" => "https://github.com/new/repo"
      })
      |> render_submit()

      # Should be back on select view with new project selected
      assert render(view) =~ "New Inline Project"
    end
  end

  describe "step 3 - initial idea" do
    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "shows initial idea textarea after completing project step", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#continue-project-btn") |> render_click()

      assert has_element?(view, "#initial_idea")
    end

    @tag feature: @feature, scenario: "Attempt to save without an initial idea"
    test "shows error when saving without an initial idea", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("#skip-project-btn") |> render_click()
      view |> form("#initial-idea-form", %{"initial_idea" => ""}) |> render_submit()

      assert has_element?(view, "#initial_idea")
      assert render(view) =~ "Please describe your initial idea"
    end

    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "save & continue creates prompt and redirects to detail page", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#continue-project-btn") |> render_click()

      view
      |> form("#initial-idea-form", %{"initial_idea" => "Add PDF export for reports"})
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r"/prompts/.+"
    end

    @tag feature: @feature, scenario: "Complete the wizard with Save & Close"
    test "save & close creates prompt and redirects to crafting board", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("#skip-project-btn") |> render_click()

      view
      |> form("#initial-idea-form", %{"initial_idea" => "A task management app"})
      |> render_change()

      view |> element("#save-and-close-btn") |> render_click()

      assert_redirect(view, "/crafting")
    end
  end

  describe "inline project creation" do
    @tag feature: "project_inline_creation",
         scenario: "Create a project with a git repository URL"
    test "creates and selects a project with git URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#create-new-project-btn") |> render_click()

      assert has_element?(view, "#inline-project-form")

      view
      |> form("#inline-project-form", %{
        "name" => "Git Project",
        "git_repo_url" => "https://github.com/inline/repo"
      })
      |> render_submit()

      assert render(view) =~ "Git Project"
      assert has_element?(view, "#continue-project-btn")
    end

    @tag feature: "project_inline_creation",
         scenario: "Create a project with a local folder only"
    test "creates and selects a project with local folder only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "Local Project",
        "local_folder" => "/path/to/local"
      })
      |> render_submit()

      assert render(view) =~ "Local Project"
      assert has_element?(view, "#continue-project-btn")
    end

    @tag feature: "project_inline_creation",
         scenario: "Create a project with both git URL and local folder"
    test "creates and selects a project with both git URL and local folder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "Full Project",
        "git_repo_url" => "https://github.com/full/repo",
        "local_folder" => "/path/to/full"
      })
      |> render_submit()

      assert render(view) =~ "Full Project"
      assert has_element?(view, "#continue-project-btn")
    end

    @tag feature: "project_inline_creation",
         scenario: "Cannot create a project without git URL or local folder"
    test "shows error when neither git URL nor local folder provided", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{"name" => "Incomplete"})
      |> render_submit()

      assert render(view) =~ "Provide at least one"
      assert has_element?(view, "#inline-project-form")
    end

    @tag feature: "project_inline_creation",
         scenario: "Cannot create a project without a name"
    test "shows error when name is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> element("#create-new-project-btn") |> render_click()

      view
      |> form("#inline-project-form", %{
        "name" => "",
        "git_repo_url" => "https://github.com/test/repo"
      })
      |> render_submit()

      assert render(view) =~ "Name is required"
      assert has_element?(view, "#inline-project-form")
    end
  end

  describe "navigation" do
    @tag feature: @feature, scenario: "Navigate back from step 2 to step 1"
    test "back from step 2 returns to step 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()

      assert has_element?(view, "#project-list") or
               has_element?(view, "#create-first-project-btn")

      view |> element("button[phx-click='back']") |> render_click()

      assert has_element?(view, "button[phx-value-type='feature_request']")
      assert has_element?(view, "button[phx-value-type='chore_task']")
      assert has_element?(view, "button[phx-value-type='project']")
    end

    @tag feature: @feature, scenario: "Navigate back from step 3 to step 2"
    test "back from step 3 returns to step 2", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("#skip-project-btn") |> render_click()

      assert has_element?(view, "#initial_idea")

      view |> element("button[phx-click='back_to_project']") |> render_click()

      assert has_element?(view, "#continue-project-btn")
    end
  end
end
