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
    {:ok, conn: conn}
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

  describe "step 2 - repository URL" do
    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "shows repository URL input after selecting a workflow type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()

      assert has_element?(view, "#repo_url")
    end

    @tag feature: @feature, scenario: "Repository URL can only be skipped for Project type"
    test "skip button is not available for non-Project types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()

      refute has_element?(view, "button[phx-click='skip_repo']")
    end

    @tag feature: @feature, scenario: "Repository URL can only be skipped for Project type"
    test "shows error when continuing without a URL for non-Project type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='chore_task']") |> render_click()
      view |> form("form", %{"repo_url" => ""}) |> render_submit()

      assert has_element?(view, "#repo_url")
      assert render(view) =~ "Repository URL is required"
    end

    @tag feature: @feature, scenario: "Skip repository URL for Project type"
    test "skip button is available for Project type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()

      assert has_element?(view, "button[phx-click='skip_repo']")
    end

    @tag feature: @feature, scenario: "Skip repository URL for Project type"
    test "skipping repo URL for Project advances to step 3", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("button[phx-click='skip_repo']") |> render_click()

      assert has_element?(view, "#initial_idea")
    end
  end

  describe "step 3 - initial idea" do
    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "shows initial idea textarea after completing repo URL step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> form("form", %{"repo_url" => "https://github.com/owner/repo"}) |> render_submit()

      assert has_element?(view, "#initial_idea")
    end

    @tag feature: @feature, scenario: "Attempt to save without an initial idea"
    test "shows error when saving without an initial idea", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("button[phx-click='skip_repo']") |> render_click()
      view |> form("#initial-idea-form", %{"initial_idea" => ""}) |> render_submit()

      assert has_element?(view, "#initial_idea")
      assert render(view) =~ "Please describe your initial idea"
    end

    @tag feature: @feature, scenario: "Complete the wizard with Save & Continue"
    test "save & continue creates prompt and redirects to detail page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()
      view |> form("form", %{"repo_url" => "https://github.com/owner/repo"}) |> render_submit()

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
      view |> element("button[phx-click='skip_repo']") |> render_click()

      view
      |> form("#initial-idea-form", %{"initial_idea" => "A task management app"})
      |> render_change()

      view |> element("#save-and-close-btn") |> render_click()

      assert_redirect(view, "/crafting")
    end
  end

  describe "navigation" do
    @tag feature: @feature, scenario: "Navigate back from step 2 to step 1"
    test "back from step 2 returns to step 1", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='feature_request']") |> render_click()

      assert has_element?(view, "#repo_url")

      view |> element("button[phx-click='back']") |> render_click()

      assert has_element?(view, "button[phx-value-type='feature_request']")
      assert has_element?(view, "button[phx-value-type='chore_task']")
      assert has_element?(view, "button[phx-value-type='project']")
    end

    @tag feature: @feature, scenario: "Navigate back from step 3 to step 2"
    test "back from step 3 returns to step 2", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/prompts/new")

      view |> element("button[phx-value-type='project']") |> render_click()
      view |> element("button[phx-click='skip_repo']") |> render_click()

      assert has_element?(view, "#initial_idea")

      view |> element("button[phx-click='back_to_repo']") |> render_click()

      assert has_element?(view, "#repo_url")
    end
  end
end
