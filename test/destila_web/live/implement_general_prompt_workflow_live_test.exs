defmodule DestilaWeb.ImplementGeneralPromptWorkflowLiveTest do
  @moduledoc """
  LiveView tests for the Implement General Prompt Workflow.
  Feature: features/implement_general_prompt_workflow.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "implement_general_prompt_workflow"

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  # --- Helpers ---

  defp create_project do
    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "Test Project",
        git_repo_url: "https://github.com/test/repo"
      })

    project
  end

  defp create_completed_brainstorm_idea_session do
    project = create_project()

    {:ok, ws} =
      Destila.Workflows.create_workflow_session(%{
        title: "Completed Brainstorm Idea",
        workflow_type: :brainstorm_idea,
        project_id: project.id,
        current_phase: 6,
        total_phases: 6,
        done_at: DateTime.utc_now()
      })

    Destila.Workflows.upsert_metadata(
      ws.id,
      "Prompt Generation",
      "prompt_generated",
      %{"text" => "This is the generated implementation prompt for the task."}
    )

    {ws, project}
  end

  defp create_implement_session(phase, opts) do
    phase_status = Keyword.get(opts, :phase_status, :processing)
    project_id = Keyword.get(opts, :project_id)

    {:ok, ws} =
      Destila.Workflows.create_workflow_session(%{
        title: "Test Implementation",
        workflow_type: :implement_general_prompt,
        project_id: project_id,
        current_phase: phase,
        total_phases: 9,
        phase_status: phase_status,
        title_generating: Keyword.get(opts, :title_generating, true)
      })

    Destila.Workflows.upsert_metadata(ws.id, "wizard", "prompt", %{
      "text" => "Implement the login feature"
    })

    ws
  end

  # --- Workflow Type Selection ---

  @tag feature: @feature, scenario: "Workflow type selection shows the new workflow"
  test "type selection shows implement a prompt option", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workflows")

    assert html =~ "Implement a Prompt"
    assert html =~ "Take a prompt through planning, coding, review, testing, and recording"
  end

  # --- Phase 1: Prompt & Project Wizard ---

  describe "Phase 1 - Prompt & Project Wizard" do
    @tag feature: @feature,
         scenario: "Phase 1 - Wizard with manual prompt and project selection"
    test "collects manual prompt and project, creates session", %{conn: conn} do
      project = create_project()
      {:ok, view, _html} = live(conn, ~p"/workflows/implement_general_prompt")

      assert has_element?(view, "#tab-select-prompt")
      assert has_element?(view, "#tab-manual-prompt")

      # Switch to manual mode
      view |> element("#tab-manual-prompt") |> render_click()

      # Enter prompt
      view
      |> element("#manual-prompt-form")
      |> render_change(%{"manual_prompt" => "Implement user authentication"})

      # Select project
      view |> element("#project-#{project.id}") |> render_click()

      # Submit
      view |> element("#start-workflow-btn") |> render_click()

      # Should redirect to the new session
      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{/sessions/.+}
    end

    @tag feature: @feature,
         scenario: "Phase 1 - Wizard with existing session prompt selection"
    test "shows completed brainstorm idea sessions for selection", %{conn: conn} do
      {ws, _project} = create_completed_brainstorm_idea_session()
      {:ok, view, _html} = live(conn, ~p"/workflows/implement_general_prompt")

      assert has_element?(view, "#session-#{ws.id}")
    end

    @tag feature: @feature,
         scenario: "Phase 1 - Wizard with existing session prompt selection"
    test "pre-selects project when existing session chosen", %{conn: conn} do
      {ws, project} = create_completed_brainstorm_idea_session()
      {:ok, view, _html} = live(conn, ~p"/workflows/implement_general_prompt")

      # Select the existing session
      view |> element("#session-#{ws.id}") |> render_click()

      # The project should now be selected (highlighted with primary border)
      assert has_element?(view, "#project-#{project.id}.border-primary")
    end

    @tag feature: @feature, scenario: "Phase 1 - Wizard requires a prompt"
    test "shows error when prompt is missing", %{conn: conn} do
      project = create_project()
      {:ok, view, _html} = live(conn, ~p"/workflows/implement_general_prompt")

      # Select project but no prompt
      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#start-workflow-btn") |> render_click()

      assert render(view) =~ "Please select or write a prompt"
    end

    @tag feature: @feature, scenario: "Phase 1 - Wizard requires a project"
    test "shows error when project is missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/implement_general_prompt")

      # Switch to manual and enter prompt but no project
      view |> element("#tab-manual-prompt") |> render_click()

      view
      |> element("#manual-prompt-form")
      |> render_change(%{"manual_prompt" => "Implement something"})

      view |> element("#start-workflow-btn") |> render_click()

      assert render(view) =~ "Please select a project"
    end
  end

  # --- Phase 2: Setup ---

  describe "Phase 2 - Setup" do
    @tag feature: @feature,
         scenario: "Phase 2 - Setup skips title generation for source session"
    test "skips title generation when source session selected", %{conn: conn} do
      ws = create_implement_session(2, title_generating: false)

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")
      refute html =~ "Generating title..."
    end

    @tag feature: @feature, scenario: "Phase 2 - Setup generates title for manual prompt"
    test "shows title generation for manual prompt", %{conn: conn} do
      ws = create_implement_session(2, title_generating: true, project_id: create_project().id)

      Destila.Workflows.upsert_metadata(ws.id, "setup", "title_gen", %{
        "status" => "in_progress"
      })

      {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")
      assert html =~ "Generating title..."
    end
  end

  # --- Non-interactive phases ---

  describe "Non-interactive AI phases" do
    @tag feature: @feature, scenario: "Phase 3 - Non-interactive AI generates plan"
    test "non-interactive phase hides text input", %{conn: conn} do
      ws = create_implement_session(3, phase_status: :processing)

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Planning the implementation...",
          phase: 3
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Should not have text input
      refute has_element?(view, "textarea[name='content']")
      # Should have cancel button
      assert has_element?(view, "#cancel-phase-btn")
    end

    @tag feature: @feature, scenario: "Non-interactive phase shows retry on error"
    test "non-interactive phase shows retry when conversing (error state)", %{conn: conn} do
      ws = create_implement_session(3, phase_status: :awaiting_input)

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Something went wrong.",
          phase: 3
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#retry-phase-btn")
      refute has_element?(view, "#cancel-phase-btn")
    end

    @tag feature: @feature, scenario: "Non-interactive phase shows retry on error"
    test "retry transitions both workflow session and phase execution to processing", %{
      conn: conn
    } do
      ws = create_implement_session(3, phase_status: :awaiting_input)

      {:ok, _pe} =
        Destila.Executions.create_phase_execution(ws, 3, %{status: "awaiting_input"})

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Something went wrong.",
          phase: 3
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#retry-phase-btn")

      view |> element("#retry-phase-btn") |> render_click()

      # Verify workflow session phase_status updated
      ws = Destila.Workflows.get_workflow_session!(ws.id)
      assert ws.phase_status == :processing

      # Verify phase execution status updated
      pe = Destila.Executions.get_current_phase_execution(ws.id)
      assert pe.status == "processing"
    end

    @tag feature: @feature, scenario: "Non-interactive phase shows retry on error"
    test "retry shows processing UI (typing indicator, cancel button)", %{conn: conn} do
      ws = create_implement_session(3, phase_status: :awaiting_input)

      {:ok, _pe} =
        Destila.Executions.create_phase_execution(ws, 3, %{status: "awaiting_input"})

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Something went wrong.",
          phase: 3
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#retry-phase-btn") |> render_click()

      # Retry button should be gone, cancel button visible
      refute has_element?(view, "#retry-phase-btn")
      assert has_element?(view, "#cancel-phase-btn")
    end

    @tag feature: @feature, scenario: "Non-interactive phase shows retry on error"
    test "workflow classified as :processing after retry", %{conn: conn} do
      ws = create_implement_session(3, phase_status: :awaiting_input)

      {:ok, _pe} =
        Destila.Executions.create_phase_execution(ws, 3, %{status: "awaiting_input"})

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Something went wrong.",
          phase: 3
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#retry-phase-btn") |> render_click()

      ws = Destila.Workflows.get_workflow_session!(ws.id)
      assert Destila.Workflows.classify(ws) == :processing
    end
  end

  # --- Session strategy ---

  describe "Session strategy" do
    @tag feature: @feature,
         scenario: "Phase 5 - AI starts a new session for implementation"
    test "session strategy returns :new for phase 5" do
      assert Destila.Workflows.session_strategy(:implement_general_prompt, 5) == {:new, []}
    end

    @tag feature: @feature,
         scenario: "Phase 5 - AI starts a new session for implementation"
    test "session strategy returns :resume for other phases" do
      for phase <- [1, 2, 3, 4, 6, 7, 8, 9] do
        assert Destila.Workflows.session_strategy(:implement_general_prompt, phase) ==
                 {:resume, []}
      end
    end
  end

  # --- Crafting board ---

  describe "Crafting board" do
    @tag feature: @feature, scenario: "Crafting board shows implementation workflow"
    test "shows implementation badge on crafting board", %{conn: conn} do
      _ws = create_implement_session(3, phase_status: :processing)

      {:ok, _view, html} = live(conn, ~p"/crafting")
      assert html =~ "Implementation"
    end
  end
end
