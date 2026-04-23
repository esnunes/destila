defmodule DestilaWeb.CodeRedesignAnalysisWorkflowLiveTest do
  @moduledoc """
  LiveView tests for the Code Redesign Analysis Workflow.
  Feature: features/code_redesign_analysis_workflow.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "code_redesign_analysis_workflow"

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

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

  defp create_redesign_session(phase, opts) do
    pe_status = Keyword.get(opts, :pe_status, :processing)
    project_id = Keyword.get(opts, :project_id)

    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test Redesign",
        workflow_type: :code_redesign_analysis,
        project_id: project_id,
        current_phase: phase,
        total_phases: 4,
        title_generating: Keyword.get(opts, :title_generating, true),
        user_prompt: Keyword.get(opts, :user_prompt, "authentication")
      })

    unless pe_status == :setup do
      {:ok, _pe} = Destila.Executions.create_phase_execution(ws, phase, %{status: pe_status})
    end

    ws
  end

  # --- Workflow type selection ---

  @tag feature: @feature, scenario: "Workflow type selection shows the new workflow"
  test "type selection shows Code Redesign Analysis option", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/workflows")

    assert html =~ "Code Redesign Analysis"

    assert html =~
             "Analyze an area of a codebase and propose a redesign with an implementation prompt"
  end

  # --- Creation form ---

  describe "Creation form" do
    @tag feature: @feature, scenario: "Creation form collects scope and project"
    test "collects scope and project, creates session, redirects", %{conn: conn} do
      project = create_project()
      {:ok, view, _html} = live(conn, ~p"/workflows/code_redesign_analysis")

      view
      |> element("#manual-input-form")
      |> render_change(%{"input_text" => "authentication"})

      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#start-workflow-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{/sessions/.+}
    end

    @tag feature: @feature, scenario: "Creation form requires a scope"
    test "shows error when scope is missing", %{conn: conn} do
      project = create_project()
      {:ok, view, _html} = live(conn, ~p"/workflows/code_redesign_analysis")

      view |> element("#project-#{project.id}") |> render_click()
      view |> element("#start-workflow-btn") |> render_click()

      assert render(view) =~ "Please select or write a scope"
    end

    @tag feature: @feature, scenario: "Creation form requires a project"
    test "shows error when project is missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows/code_redesign_analysis")

      view
      |> element("#manual-input-form")
      |> render_change(%{"input_text" => "authentication"})

      view |> element("#start-workflow-btn") |> render_click()

      assert render(view) =~ "Please select a project"
    end
  end

  # --- Non-interactive phases ---

  describe "Non-interactive phases" do
    @tag feature: @feature, scenario: "Phase 1 - Non-interactive AI extracts requirements"
    test "phase 1 hides text input and shows cancel button", %{conn: conn} do
      ws = create_redesign_session(1, pe_status: :processing)

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Analyzing the scope...",
          phase: 1,
          workflow_session_id: ws.id
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "input[name='content']")
      assert has_element?(view, "#cancel-phase-btn")
    end

    @tag feature: @feature, scenario: "Non-interactive phase shows retry on error"
    test "phase 1 shows retry when errored", %{conn: conn} do
      ws = create_redesign_session(1, pe_status: :awaiting_input)

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "Something went wrong.",
          phase: 1,
          workflow_session_id: ws.id
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#retry-phase-btn")
      refute has_element?(view, "#cancel-phase-btn")
    end
  end

  # --- Exported metadata sidebar ---

  describe "Exported metadata sidebar" do
    @tag feature: @feature, scenario: "Exported metadata sidebar shows all four artifacts"
    test "sidebar shows entries for all four artifacts", %{conn: conn} do
      ws = create_redesign_session(4, pe_status: :awaiting_input)

      for {phase_name, key} <- [
            {"Extract Requirements", "requirements_doc"},
            {"Greenfield Design", "greenfield_design"},
            {"Compare & Improve", "comparison_report"},
            {"Compare & Improve", "prompt_generated"}
          ] do
        Destila.Workflows.upsert_metadata(
          ws.id,
          phase_name,
          key,
          %{"markdown" => "# #{key}\n\nSome content"},
          exported: true
        )
      end

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#metadata-sidebar")

      html = render(view)
      assert html =~ "Requirements Doc"
      assert html =~ "Greenfield Design"
      assert html =~ "Comparison Report"
      assert html =~ "Prompt Generated"
    end
  end

  # --- Adjustments phase ---

  describe "Adjustments phase" do
    @tag feature: @feature, scenario: "Phase 4 - Adjustments phase is interactive"
    test "phase 4 shows a text input", %{conn: conn} do
      ws = create_redesign_session(4, pe_status: :awaiting_input)

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      {:ok, _} =
        Destila.AI.create_message(ai_session.id, %{
          role: :system,
          content: "The artifacts are ready. What would you like to refine?",
          phase: 4,
          workflow_session_id: ws.id
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert render(view) =~ "Phase 4/4"
      assert render(view) =~ "Adjustments"
      assert has_element?(view, "input[name='content']")
    end

    @tag feature: @feature, scenario: "Phase 4 re-export replaces the original artifact"
    test "re-exporting in phase 4 replaces the original row", %{conn: conn} do
      ws = create_redesign_session(4, pe_status: :awaiting_input)

      {:ok, _} =
        Destila.Workflows.upsert_metadata(
          ws.id,
          "Extract Requirements",
          "requirements_doc",
          %{"markdown" => "original content"},
          exported: true
        )

      {:ok, _view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      {:ok, _} =
        Destila.Workflows.upsert_metadata(
          ws.id,
          "Adjustments",
          "requirements_doc",
          %{"markdown" => "refined content"},
          exported: true
        )

      exported = Destila.Workflows.get_exported_metadata(ws.id)
      requirements_rows = Enum.filter(exported, &(&1.key == "requirements_doc"))

      assert length(requirements_rows) == 1
      [row] = requirements_rows
      assert row.value == %{"markdown" => "refined content"}
      assert row.phase_name == "Adjustments"
    end
  end

  # --- Cross-workflow source picker ---

  describe "Cross-workflow source picker" do
    @tag feature: @feature,
         scenario: "Prompt Generated surfaces in the Implement a Prompt source picker"
    test "completed redesign session appears in implement_general_prompt picker", %{conn: conn} do
      project = create_project()

      {:ok, ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "Completed Redesign",
          workflow_type: :code_redesign_analysis,
          project_id: project.id,
          current_phase: 4,
          total_phases: 4,
          done_at: DateTime.utc_now()
        })

      {:ok, _} =
        Destila.Workflows.upsert_metadata(
          ws.id,
          "Compare & Improve",
          "prompt_generated",
          %{"markdown" => "Implement the redesign described here."},
          exported: true
        )

      {:ok, view, _html} = live(conn, ~p"/workflows/implement_general_prompt")

      assert has_element?(view, "#session-#{ws.id}")
    end
  end

  # --- Crafting board ---

  describe "Crafting board" do
    @tag feature: @feature, scenario: "Crafting board shows the redesign analysis workflow"
    test "shows Redesign Analysis badge on crafting board", %{conn: conn} do
      _ws = create_redesign_session(1, pe_status: :processing)

      {:ok, _view, html} = live(conn, ~p"/crafting")
      assert html =~ "Redesign Analysis"
    end
  end
end
