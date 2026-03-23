defmodule DestilaWeb.CraftingBoardLiveTest do
  @moduledoc """
  LiveView tests for the Crafting Board.
  Feature: features/crafting_board.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "crafting_board"

  setup %{conn: conn} do
    conn = post(conn, "/login", %{"email" => "test@example.com"})

    {:ok, project_a} =
      Destila.Projects.create_project(%{
        name: "destila",
        git_repo_url: "https://github.com/test/destila"
      })

    {:ok, project_b} =
      Destila.Projects.create_project(%{
        name: "other-project",
        git_repo_url: "https://github.com/test/other"
      })

    {:ok, conn: conn, project_a: project_a, project_b: project_b}
  end

  defp create_prompt(attrs) do
    defaults = %{
      title: "Test Prompt",
      workflow_type: :chore_task,
      board: :crafting,
      column: :request,
      steps_completed: 1,
      steps_total: 4,
      position: System.unique_integer([:positive])
    }

    {:ok, prompt} = Destila.Prompts.create_prompt(Map.merge(defaults, attrs))
    prompt
  end

  # --- Default List View ---

  describe "sectioned list view" do
    @tag feature: @feature, scenario: "View prompts in sectioned list"
    test "shows four sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/crafting")

      assert has_element?(view, "#section-setup")
      assert has_element?(view, "#section-waiting")
      assert has_element?(view, "#section-in_progress")
      assert has_element?(view, "#section-done")
    end

    @tag feature: @feature, scenario: "View prompts in sectioned list"
    test "classifies prompts into correct sections", %{conn: conn, project_a: project} do
      setup_prompt =
        create_prompt(%{
          title: "Setup Prompt",
          phase_status: :setup,
          project_id: project.id
        })

      waiting_prompt =
        create_prompt(%{
          title: "Waiting Prompt",
          phase_status: :conversing,
          project_id: project.id
        })

      generating_prompt =
        create_prompt(%{
          title: "Generating Prompt",
          phase_status: :generating,
          project_id: project.id
        })

      in_progress_prompt =
        create_prompt(%{
          title: "Active Prompt",
          phase_status: nil,
          workflow_type: :feature_request,
          project_id: project.id
        })

      done_prompt =
        create_prompt(%{
          title: "Done Prompt",
          column: :done,
          project_id: project.id
        })

      {:ok, view, _html} = live(conn, ~p"/crafting")

      # Setup section
      assert has_element?(view, "#section-setup #crafting-card-#{setup_prompt.id}")

      # Waiting section (both conversing and generating)
      assert has_element?(view, "#section-waiting #crafting-card-#{waiting_prompt.id}")
      assert has_element?(view, "#section-waiting #crafting-card-#{generating_prompt.id}")

      # In Progress section
      assert has_element?(view, "#section-in_progress #crafting-card-#{in_progress_prompt.id}")

      # Done section
      assert has_element?(view, "#section-done #crafting-card-#{done_prompt.id}")
    end

    @tag feature: @feature, scenario: "View prompts in sectioned list"
    test "advance_suggested appears in waiting section", %{conn: conn, project_a: project} do
      prompt =
        create_prompt(%{
          title: "Advance Prompt",
          phase_status: :advance_suggested,
          project_id: project.id
        })

      {:ok, view, _html} = live(conn, ~p"/crafting")
      assert has_element?(view, "#section-waiting #crafting-card-#{prompt.id}")
    end
  end

  describe "card content" do
    @tag feature: @feature, scenario: "Prompt card displays title, project, and phase"
    test "card shows title, project name, and phase number", %{conn: conn, project_a: project} do
      create_prompt(%{
        title: "Fix login bug",
        project_id: project.id,
        steps_completed: 2,
        workflow_type: :feature_request
      })

      {:ok, _view, html} = live(conn, ~p"/crafting")

      assert html =~ "Fix login bug"
      assert html =~ "destila"
      assert html =~ "Feature Type"
    end

    @tag feature: @feature, scenario: "Click prompt card to navigate to detail page"
    test "card title links to prompt detail page", %{conn: conn, project_a: project} do
      prompt =
        create_prompt(%{
          title: "Clickable Prompt",
          project_id: project.id
        })

      {:ok, view, _html} = live(conn, ~p"/crafting")

      assert has_element?(view, "a[href='/prompts/#{prompt.id}']", "Clickable Prompt")
    end
  end

  # --- Project Filter ---

  describe "project filter" do
    @tag feature: @feature, scenario: "Filter prompts by project"
    test "filters prompts by project via dropdown", %{
      conn: conn,
      project_a: project_a,
      project_b: project_b
    } do
      prompt_a = create_prompt(%{title: "Prompt A", project_id: project_a.id})
      prompt_b = create_prompt(%{title: "Prompt B", project_id: project_b.id})

      {:ok, view, _html} = live(conn, ~p"/crafting")

      # Both visible initially
      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      assert has_element?(view, "#crafting-card-#{prompt_b.id}")

      # Filter to project_a
      view
      |> form("#project-filter-form", %{"project" => project_a.id})
      |> render_change()

      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      refute has_element?(view, "#crafting-card-#{prompt_b.id}")
    end

    @tag feature: @feature, scenario: "Clear project filter"
    test "clearing filter shows all prompts", %{
      conn: conn,
      project_a: project_a,
      project_b: project_b
    } do
      prompt_a = create_prompt(%{title: "Prompt A", project_id: project_a.id})
      prompt_b = create_prompt(%{title: "Prompt B", project_id: project_b.id})

      # Start with filter active
      {:ok, view, _html} = live(conn, "/crafting?project=#{project_a.id}")
      refute has_element?(view, "#crafting-card-#{prompt_b.id}")

      # Clear filter
      view
      |> form("#project-filter-form", %{"project" => ""})
      |> render_change()

      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      assert has_element?(view, "#crafting-card-#{prompt_b.id}")
    end

    @tag feature: @feature, scenario: "Click project name on card to filter by project"
    test "clicking project name on card activates filter", %{
      conn: conn,
      project_a: project_a,
      project_b: project_b
    } do
      prompt_a = create_prompt(%{title: "Prompt A", project_id: project_a.id})
      prompt_b = create_prompt(%{title: "Prompt B", project_id: project_b.id})

      {:ok, view, _html} = live(conn, ~p"/crafting")

      # Click the project name link on prompt_a's card
      view
      |> element("#crafting-card-#{prompt_a.id} a", "destila")
      |> render_click()

      # Should filter to project_a only
      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      refute has_element?(view, "#crafting-card-#{prompt_b.id}")
    end

    @tag feature: @feature, scenario: "Filter prompts by project"
    test "prompts without project appear only when no filter active", %{
      conn: conn,
      project_a: project_a
    } do
      with_project = create_prompt(%{title: "With Project", project_id: project_a.id})

      without_project =
        create_prompt(%{title: "No Project", project_id: nil, workflow_type: :project})

      {:ok, view, _html} = live(conn, ~p"/crafting")

      # Both visible when no filter
      assert has_element?(view, "#crafting-card-#{with_project.id}")
      assert has_element?(view, "#crafting-card-#{without_project.id}")

      # Filter to project_a — prompt without project disappears
      view
      |> form("#project-filter-form", %{"project" => project_a.id})
      |> render_change()

      assert has_element?(view, "#crafting-card-#{with_project.id}")
      refute has_element?(view, "#crafting-card-#{without_project.id}")
    end
  end

  # --- Group by Workflow ---

  describe "group by workflow" do
    @tag feature: @feature, scenario: "Toggle group by workflow"
    test "toggle shows workflow boards with phase columns", %{conn: conn, project_a: project} do
      create_prompt(%{
        title: "Chore Prompt",
        workflow_type: :chore_task,
        steps_completed: 2,
        project_id: project.id
      })

      create_prompt(%{
        title: "Feature Prompt",
        workflow_type: :feature_request,
        steps_completed: 1,
        steps_total: 4,
        project_id: project.id
      })

      {:ok, view, _html} = live(conn, ~p"/crafting")

      # Toggle to workflow view
      view |> element("#view-toggle input") |> render_click()

      # Should see workflow boards
      assert has_element?(view, "#workflow-board-chore_task")
      assert has_element?(view, "#workflow-board-feature_request")

      # Chore/Task board should have phase columns
      html = render(view)
      assert html =~ "Task Description"
      assert html =~ "Gherkin Review"

      # Feature Request board should have its columns
      assert html =~ "Problem"
      assert html =~ "Feature Type"
    end

    @tag feature: @feature, scenario: "Empty workflow boards are hidden"
    test "hides workflow boards with no prompts", %{conn: conn, project_a: project} do
      create_prompt(%{
        title: "Chore Only",
        workflow_type: :chore_task,
        project_id: project.id
      })

      {:ok, view, _html} = live(conn, "/crafting?view=workflow")

      assert has_element?(view, "#workflow-board-chore_task")
      refute has_element?(view, "#workflow-board-feature_request")
      refute has_element?(view, "#workflow-board-project")
    end

    @tag feature: @feature, scenario: "Boards are read-only (no drag and drop)"
    test "no sortable hooks on workflow boards", %{conn: conn, project_a: project} do
      create_prompt(%{
        title: "Test Prompt",
        workflow_type: :chore_task,
        project_id: project.id
      })

      {:ok, view, _html} = live(conn, "/crafting?view=workflow")

      html = render(view)
      refute html =~ "phx-hook=\"Sortable\""
    end

    @tag feature: @feature, scenario: "Toggle group by workflow"
    test "toggling back returns to list view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/crafting?view=workflow")

      view |> element("#view-toggle input") |> render_click()

      assert has_element?(view, "#crafting-sections")
      refute has_element?(view, "#crafting-workflow-boards")
    end
  end

  # --- Combined filter + grouping ---

  describe "filter with workflow grouping" do
    @tag feature: @feature, scenario: "Filter by project with group by workflow active"
    test "project filter works in workflow view", %{
      conn: conn,
      project_a: project_a,
      project_b: project_b
    } do
      prompt_a =
        create_prompt(%{
          title: "Chore A",
          workflow_type: :chore_task,
          project_id: project_a.id
        })

      prompt_b =
        create_prompt(%{
          title: "Chore B",
          workflow_type: :chore_task,
          project_id: project_b.id
        })

      {:ok, view, _html} = live(conn, "/crafting?view=workflow")

      # Both visible initially
      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      assert has_element?(view, "#crafting-card-#{prompt_b.id}")

      # Filter to project_a
      view
      |> form("#project-filter-form", %{"project" => project_a.id})
      |> render_change()

      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      refute has_element?(view, "#crafting-card-#{prompt_b.id}")
    end

    @tag feature: @feature, scenario: "Filter by project with group by workflow active"
    test "filter persists when toggling view mode", %{conn: conn, project_a: project_a} do
      create_prompt(%{title: "Prompt A", project_id: project_a.id})

      # Start with filter active in list view
      {:ok, view, _html} = live(conn, "/crafting?project=#{project_a.id}")

      # Toggle to workflow view — filter should persist
      view |> element("#view-toggle input") |> render_click()

      # Should still be filtered (URL should have both params)
      assert has_element?(view, "#crafting-workflow-boards")
      assert has_element?(view, "#project-filter")
    end
  end

  # --- URL State ---

  describe "URL state" do
    test "filter updates URL query params", %{conn: conn, project_a: project_a} do
      create_prompt(%{title: "Test", project_id: project_a.id})

      {:ok, view, _html} = live(conn, ~p"/crafting")

      view
      |> form("#project-filter-form", %{"project" => project_a.id})
      |> render_change()

      assert_patch(view, "/crafting?project=#{project_a.id}")
    end

    test "toggle updates URL query params", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/crafting")

      view |> element("#view-toggle input") |> render_click()

      assert_patch(view, "/crafting?view=workflow")
    end

    test "loads state from URL on mount", %{
      conn: conn,
      project_a: project_a,
      project_b: project_b
    } do
      prompt_a = create_prompt(%{title: "A", project_id: project_a.id})
      prompt_b = create_prompt(%{title: "B", project_id: project_b.id})

      {:ok, view, _html} = live(conn, "/crafting?project=#{project_a.id}&view=workflow")

      # Should be in workflow mode with filter active
      assert has_element?(view, "#crafting-workflow-boards")
      assert has_element?(view, "#crafting-card-#{prompt_a.id}")
      refute has_element?(view, "#crafting-card-#{prompt_b.id}")
    end
  end

  # --- PubSub ---

  describe "real-time updates" do
    @tag feature: @feature, scenario: "View prompts in sectioned list"
    test "board updates when a prompt is created", %{conn: conn, project_a: project} do
      {:ok, view, _html} = live(conn, ~p"/crafting")

      # Create a new prompt — triggers PubSub broadcast
      prompt = create_prompt(%{title: "New Prompt", project_id: project.id})

      # The PubSub handler will refresh the view
      assert has_element?(view, "#crafting-card-#{prompt.id}")
    end
  end
end
