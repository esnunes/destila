defmodule DestilaWeb.PostCompletionFollowupLiveTest do
  @moduledoc """
  LiveView tests for the Post-Completion Follow-Up Modal.
  Feature: features/post_completion_followup.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.Executions
  alias Destila.Workflows

  @feature "post_completion_followup"

  setup %{conn: conn} do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "Test Project",
        git_repo_url: "https://github.com/test/repo"
      })

    {:ok, conn: conn, project: project}
  end

  # --- Helpers ---

  defp create_brainstorm_on_last_phase(project, opts \\ []) do
    export_prompt? = Keyword.get(opts, :export_prompt?, true)

    {:ok, ws} =
      Workflows.insert_workflow_session(%{
        title: "Completed Brainstorm",
        workflow_type: :brainstorm_idea,
        project_id: project.id,
        current_phase: 4,
        total_phases: 4
      })

    {:ok, _pe} =
      Executions.create_phase_execution(ws, 4, %{status: :awaiting_input})

    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Last phase ready.",
        phase: 4,
        workflow_session_id: ws.id
      })

    if export_prompt? do
      {:ok, _} =
        Workflows.upsert_metadata(
          ws.id,
          "Prompt Generation",
          "prompt_generated",
          %{"markdown" => "Build a login form"},
          exported: true
        )
    end

    ws
  end

  # --- Modal trigger ---

  describe "Modal trigger" do
    @tag feature: @feature, scenario: "Modal opens immediately after Mark as Done"
    test "clicking Mark as Done opens the follow-up modal and marks session done",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#follow-up-modal")

      view |> element("#mark-done-btn") |> render_click()

      assert has_element?(view, "#follow-up-modal")
      assert Destila.Workflows.Session.done?(Workflows.get_workflow_session!(ws.id))
    end

    @tag feature: @feature,
         scenario: "Modal lists all compatible follow-up workflows as selectable cards"
    test "modal shows selectable follow-up cards with footer actions",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()

      assert has_element?(view, "#follow-up-card-implement_general_prompt")

      card_html =
        view
        |> element("#follow-up-card-implement_general_prompt")
        |> render()

      assert card_html =~ "Implement a Prompt"
      assert card_html =~ Destila.Workflows.ImplementGeneralPromptWorkflow.description()

      assert has_element?(view, "#follow-up-start-and-archive-btn", "Start and archive")
      assert has_element?(view, "#follow-up-start-btn", "Start")
      assert has_element?(view, "#follow-up-archive-only-btn")
      assert has_element?(view, "#follow-up-close-btn")
    end

    @tag feature: @feature, scenario: "Modal shows no follow-ups when none are compatible"
    test "modal shows empty state when no compatible follow-ups exist",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project, export_prompt?: false)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()

      assert has_element?(view, "#follow-up-modal")
      assert has_element?(view, "#follow-up-modal-empty-state")
      refute has_element?(view, "#follow-up-card-implement_general_prompt")
      refute has_element?(view, "#follow-up-start-btn")
      refute has_element?(view, "#follow-up-start-and-archive-btn")
      assert has_element?(view, "#follow-up-archive-only-btn")
      assert has_element?(view, "#follow-up-close-btn")
    end
  end

  # --- Follow-up actions ---

  describe "Follow-up actions" do
    @tag feature: @feature,
         scenario: "Start and archive is the primary action on the selected card"
    test "Start and archive creates new session, archives source, and navigates",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()

      view
      |> element("#follow-up-card-implement_general_prompt")
      |> render_click()

      view |> element("#follow-up-start-and-archive-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{^/sessions/}

      "/sessions/" <> new_ws_id = path
      new_ws = Workflows.get_workflow_session!(new_ws_id)
      assert new_ws.workflow_type == :implement_general_prompt
      assert new_ws.project_id == project.id
      assert new_ws.user_prompt == "Build a login form"
      assert new_ws.source_session_id == ws.id

      archived = Workflows.get_workflow_session!(ws.id)
      refute is_nil(archived.archived_at)
    end

    @tag feature: @feature,
         scenario: "Starting a follow-up without archiving keeps the source available"
    test "Start (no archive) creates new session and leaves source done-but-not-archived",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()

      view
      |> element("#follow-up-card-implement_general_prompt")
      |> render_click()

      view |> element("#follow-up-start-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ ~r{^/sessions/}

      "/sessions/" <> new_ws_id = path
      new_ws = Workflows.get_workflow_session!(new_ws_id)
      assert new_ws.workflow_type == :implement_general_prompt
      assert new_ws.project_id == project.id
      assert new_ws.user_prompt == "Build a login form"
      assert new_ws.source_session_id == ws.id

      source = Workflows.get_workflow_session!(ws.id)
      assert Destila.Workflows.Session.done?(source)
      assert is_nil(source.archived_at)
    end

    @tag feature: @feature, scenario: "Archive only archives without starting a follow-up"
    test "Archive only archives source and redirects to crafting board",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()
      view |> element("#follow-up-archive-only-btn") |> render_click()

      {path, flash} = assert_redirect(view)
      assert path == "/crafting"
      assert flash["info"] == "Session archived"

      archived = Workflows.get_workflow_session!(ws.id)
      refute is_nil(archived.archived_at)

      implement_sessions =
        Workflows.list_workflow_sessions()
        |> Enum.filter(&(&1.workflow_type == :implement_general_prompt))

      assert implement_sessions == []
    end

    @tag feature: @feature,
         scenario: "Close dismisses the modal without archiving or starting a follow-up"
    test "Close dismisses modal; session remains done but not archived",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()

      assert has_element?(view, "#follow-up-modal")

      view |> element("#follow-up-close-btn") |> render_click()

      refute has_element?(view, "#follow-up-modal")

      reloaded = Workflows.get_workflow_session!(ws.id)
      assert Destila.Workflows.Session.done?(reloaded)
      assert is_nil(reloaded.archived_at)

      implement_sessions =
        Workflows.list_workflow_sessions()
        |> Enum.filter(&(&1.workflow_type == :implement_general_prompt))

      assert implement_sessions == []
    end
  end

  # --- Existing UI remains available ---

  describe "Existing UI availability" do
    @tag feature: @feature,
         scenario: "Top-of-page Archive button remains available after closing the modal"
    test "top-of-page Archive button still works after closing the modal",
         %{conn: conn, project: project} do
      ws = create_brainstorm_on_last_phase(project)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#mark-done-btn") |> render_click()
      view |> element("#follow-up-close-btn") |> render_click()

      assert has_element?(view, "#archive-btn")
      view |> element("#archive-btn") |> render_click()

      {path, flash} = assert_redirect(view)
      assert path == "/crafting"
      assert flash["info"] == "Session archived"

      archived = Workflows.get_workflow_session!(ws.id)
      refute is_nil(archived.archived_at)
    end
  end
end
