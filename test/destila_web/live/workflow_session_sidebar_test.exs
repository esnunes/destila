defmodule DestilaWeb.WorkflowSessionSidebarTest do
  @moduledoc """
  LiveView tests for the workflow session sidebar.
  Feature: features/workflow_session_sidebar.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "workflow_session_sidebar"

  setup %{conn: conn} do
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

  defp create_session(attrs \\ %{}) do
    defaults = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 3,
      total_phases: 6,
      phase_status: :awaiting_input,
      position: System.unique_integer([:positive])
    }

    {:ok, ws} = Destila.Workflows.create_workflow_session(Map.merge(defaults, attrs))
    ws
  end

  defp create_ai_session_with_messages(ws) do
    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Let's work on this.",
        phase: 3,
        raw_response: %{
          "text" => "Let's work on this.",
          "usage" => %{"input_tokens" => 1500, "output_tokens" => 300}
        }
      })

    {:ok, _} =
      Destila.AI.create_message(ai_session.id, %{
        role: :user,
        content: "Fix the login bug",
        phase: 3
      })

    ai_session
  end

  # --- Tests ---

  @tag feature: @feature, scenario: "Sidebar is visible by default on an active session"
  test "sidebar is visible on session detail page", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#session-sidebar")
    assert has_element?(view, "#session-sidebar-content")
    assert has_element?(view, "#sidebar-session-info")
  end

  @tag feature: @feature, scenario: "Sidebar is not shown on workflow type selection"
  test "sidebar is not rendered on type selection page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows")

    refute has_element?(view, "#session-sidebar")
  end

  @tag feature: @feature, scenario: "Collapse and expand the sidebar"
  test "toggle button exists with data-toggle-sidebar attribute", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-toggle-btn[data-toggle-sidebar]")
    assert has_element?(view, "#session-sidebar-toggle[phx-hook='.SidebarToggle']")
  end

  @tag feature: @feature, scenario: "Sidebar shows session info"
  test "sidebar shows session creation date and duration", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-session-info")
    assert has_element?(view, "#sidebar-session-info dt")
    assert has_element?(view, "#sidebar-session-info dd")
  end

  @tag feature: @feature, scenario: "Sidebar shows done status for completed session"
  test "sidebar shows completion date when session is done", %{conn: conn} do
    ws = create_session(%{done_at: DateTime.utc_now()})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-completed-date")
  end

  @tag feature: @feature, scenario: "Sidebar shows project info"
  test "sidebar shows project name and repository URL", %{conn: conn} do
    project = create_project()
    ws = create_session(%{project_id: project.id})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-project-info")
    assert has_element?(view, "#sidebar-project-name")
    assert has_element?(view, "#sidebar-project-repo")
  end

  @tag feature: @feature, scenario: "Sidebar shows exported metadata grouped by phase"
  test "sidebar shows metadata grouped by phase name", %{conn: conn} do
    ws = create_session()

    Destila.Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "My idea"})
    Destila.Workflows.upsert_metadata(ws.id, "wizard", "prompt", %{"text" => "A prompt"})
    Destila.Workflows.upsert_metadata(ws.id, "setup", "repo_cloned", %{"text" => "true"})

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-metadata-wizard")
    assert has_element?(view, "#sidebar-metadata-setup")
    refute has_element?(view, "#sidebar-metadata-empty")
  end

  @tag feature: @feature, scenario: "Sidebar updates when new metadata is exported"
  test "sidebar updates in real-time when new metadata is broadcast", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    # Initially no metadata
    assert has_element?(view, "#sidebar-metadata-empty")

    # Add metadata (this triggers PubSub broadcast)
    Destila.Workflows.upsert_metadata(ws.id, "wizard", "idea", %{"text" => "New idea"})

    # Wait for the PubSub message to arrive and be processed
    _ = render(view)

    assert has_element?(view, "#sidebar-metadata-wizard")
    refute has_element?(view, "#sidebar-metadata-empty")
  end

  @tag feature: @feature, scenario: "Sidebar shows AI sessions"
  test "sidebar shows AI sessions with status", %{conn: conn} do
    ws = create_session()
    ai_session = create_ai_session_with_messages(ws)

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-ai-sessions")
    assert has_element?(view, "#sidebar-ai-session-#{ai_session.id}")
    refute has_element?(view, "#sidebar-ai-sessions-empty")
  end

  @tag feature: @feature, scenario: "Sidebar shows AI sessions"
  test "sidebar shows empty state when no AI sessions", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-ai-sessions-empty")
  end

  @tag feature: @feature, scenario: "Sidebar shows exported metadata grouped by phase"
  test "sidebar shows empty state when no metadata", %{conn: conn} do
    ws = create_session()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

    assert has_element?(view, "#sidebar-metadata-empty")
  end
end
