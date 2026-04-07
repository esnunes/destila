defmodule DestilaWeb.SessionArchivingLiveTest do
  @moduledoc """
  LiveView tests for archiving and unarchiving sessions from the detail page,
  and verifying visibility on the crafting board and dashboard.
  Feature: features/session_archiving.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "session_archiving"

  setup %{conn: conn} do
    conn = post(conn, "/login", %{"email" => "test@example.com"})

    {:ok, project} =
      Destila.Projects.create_project(%{
        name: "destila",
        git_repo_url: "https://github.com/test/destila"
      })

    {:ok, conn: conn, project: project}
  end

  defp create_session(attrs) do
    defaults = %{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4,
      position: System.unique_integer([:positive])
    }

    {:ok, session} = Destila.Workflows.insert_workflow_session(Map.merge(defaults, attrs))

    # Create PE so derived status is :awaiting_input
    {:ok, _pe} =
      Destila.Executions.create_phase_execution(session, session.current_phase, %{
        status: :awaiting_input
      })

    session
  end

  # --- Archiving from session detail ---

  describe "archive from session detail" do
    @tag feature: @feature, scenario: "Archive a session from the session detail page"
    test "redirects to crafting board with flash on archive", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})

      # Add a message so mount doesn't try to start workflow
      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Welcome",
        phase: 1
      })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      # Archive button should be visible
      assert has_element?(view, "#archive-btn")

      # Click archive
      view |> element("#archive-btn") |> render_click()

      # Should redirect to crafting board with flash
      {path, flash} = assert_redirect(view)
      assert path == "/crafting"
      assert flash["info"] == "Session archived"
    end
  end

  # --- Unarchiving from session detail ---

  describe "unarchive from session detail" do
    @tag feature: @feature, scenario: "Unarchive a session from the session detail page"
    test "shows Unarchive button and restores on click", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})

      {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

      Destila.AI.create_message(ai_session.id, %{
        role: :system,
        content: "Welcome",
        phase: 1
      })

      {:ok, archived} = Destila.Workflows.archive_workflow_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{archived.id}")

      # Unarchive button should be visible
      assert has_element?(view, "#unarchive-btn")
      refute has_element?(view, "#archive-btn")

      # Click unarchive
      view |> element("#unarchive-btn") |> render_click()

      # Flash and button swap
      assert has_element?(view, "#archive-btn")
      refute has_element?(view, "#unarchive-btn")
      assert render(view) =~ "Session restored"
    end
  end

  # --- Unarchive PE transition ---

  describe "unarchive PE transition" do
    @tag feature: @feature, scenario: "Unarchive transitions processing PE to awaiting_input"
    test "transitions PE from processing to awaiting_input on unarchive", %{
      conn: _conn,
      project: project
    } do
      # Create session with a processing PE
      {:ok, ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "Processing Session",
          workflow_type: :brainstorm_idea,
          current_phase: 1,
          total_phases: 4,
          project_id: project.id
        })

      {:ok, _pe} =
        Destila.Executions.create_phase_execution(ws, 1, %{status: :processing})

      # Archive (kills ClaudeSession, but PE stays :processing)
      {:ok, archived} = Destila.Workflows.archive_workflow_session(ws)

      pe = Destila.Executions.get_current_phase_execution(archived.id)
      assert pe.status == :processing

      # Unarchive should transition PE to awaiting_input
      {:ok, _restored} = Destila.Workflows.unarchive_workflow_session(archived)

      pe = Destila.Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input
    end

    @tag feature: @feature, scenario: "Unarchive preserves non-processing PE status"
    test "does not change PE when status is not processing", %{
      conn: _conn,
      project: project
    } do
      ws = create_session(%{project_id: project.id})
      # PE is created with :awaiting_input in create_session helper

      {:ok, archived} = Destila.Workflows.archive_workflow_session(ws)
      {:ok, _restored} = Destila.Workflows.unarchive_workflow_session(archived)

      pe = Destila.Executions.get_current_phase_execution(ws.id)
      assert pe.status == :awaiting_input
    end
  end

  # --- Crafting board visibility ---

  describe "crafting board visibility" do
    @tag feature: @feature, scenario: "Archived session is hidden from the crafting board"
    test "archived session is not shown on crafting board", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      Destila.Workflows.archive_workflow_session(ws)

      {:ok, _view, html} = live(conn, ~p"/crafting")

      refute html =~ "Fix login bug"
    end

    @tag feature: @feature, scenario: "Restored session reappears on the crafting board"
    test "restored session reappears on crafting board", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      {:ok, archived} = Destila.Workflows.archive_workflow_session(ws)
      Destila.Workflows.unarchive_workflow_session(archived)

      {:ok, _view, html} = live(conn, ~p"/crafting")

      assert html =~ "Fix login bug"
    end
  end

  # --- Dashboard visibility ---

  describe "dashboard visibility" do
    @tag feature: @feature, scenario: "Archived session is hidden from the dashboard"
    test "archived session is not shown on dashboard", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      Destila.Workflows.archive_workflow_session(ws)

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ "Fix login bug"
    end
  end
end
