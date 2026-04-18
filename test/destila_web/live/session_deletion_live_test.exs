defmodule DestilaWeb.SessionDeletionLiveTest do
  @moduledoc """
  LiveView tests for deleting workflow sessions from the detail page,
  and verifying deletion behavior across the app.
  Feature: features/session_deletion.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "session_deletion"

  setup %{conn: conn} do
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

    {:ok, _pe} =
      Destila.Executions.create_phase_execution(session, session.current_phase, %{
        status: :awaiting_input
      })

    session
  end

  defp seed_welcome_message(ws) do
    {:ok, ai_session} = Destila.AI.get_or_create_ai_session(ws.id)

    Destila.AI.create_message(ai_session.id, %{
      role: :system,
      content: "Welcome",
      phase: 1,
      workflow_session_id: ws.id
    })
  end

  describe "delete from session detail" do
    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "redirects and flashes on delete", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      seed_welcome_message(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#delete-btn")

      view |> element("#delete-btn") |> render_click()

      {path, flash} = assert_redirect(view)
      assert path == "/crafting"
      assert flash["info"] == "Session deleted"
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "delete button has a data-confirm attribute", %{conn: conn, project: project} do
      ws = create_session(%{project_id: project.id})
      seed_welcome_message(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      html = view |> element("#delete-btn") |> render()

      assert html =~
               ~s(data-confirm="Permanently delete this session? This cannot be undone in the app.")

      refute html =~ "phx-hook"
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "redirects to referer captured in session", %{conn: conn, project: project} do
      ws = create_session(%{title: "Fix login bug", project_id: project.id})
      seed_welcome_message(ws)

      conn =
        conn
        |> init_test_session(%{"session_detail_referer" => "/"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#delete-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path == "/"
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "falls back to /crafting when referer points back to same session", %{
      conn: conn,
      project: project
    } do
      ws = create_session(%{project_id: project.id})
      seed_welcome_message(ws)

      conn =
        conn
        |> init_test_session(%{"session_detail_referer" => "http://localhost/sessions/#{ws.id}"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#delete-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path == "/crafting"
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "falls back to /crafting when referer points under same session path", %{
      conn: conn,
      project: project
    } do
      ws = create_session(%{project_id: project.id})
      seed_welcome_message(ws)

      conn =
        conn
        |> init_test_session(%{"session_detail_referer" => "/sessions/#{ws.id}/terminal"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#delete-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path == "/crafting"
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "falls back to /crafting when referer is empty string", %{conn: conn, project: project} do
      ws = create_session(%{project_id: project.id})
      seed_welcome_message(ws)

      conn =
        conn
        |> init_test_session(%{"session_detail_referer" => ""})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#delete-btn") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path == "/crafting"
    end
  end

  describe "delete button visibility" do
    @tag feature: @feature, scenario: "Delete an archived session"
    test "delete button renders for archived sessions", %{conn: conn, project: project} do
      ws = create_session(%{project_id: project.id})
      seed_welcome_message(ws)
      {:ok, archived} = Destila.Workflows.archive_workflow_session(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{archived.id}")

      assert has_element?(view, "#delete-btn")
      assert has_element?(view, "#unarchive-btn")
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "delete button renders for processing sessions", %{conn: conn, project: project} do
      {:ok, ws} =
        Destila.Workflows.insert_workflow_session(%{
          title: "Processing Session",
          workflow_type: :brainstorm_idea,
          current_phase: 1,
          total_phases: 4,
          project_id: project.id
        })

      {:ok, _pe} = Destila.Executions.create_phase_execution(ws, 1, %{status: :processing})
      seed_welcome_message(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#delete-btn")
    end

    @tag feature: @feature, scenario: "Delete a session from the session detail page"
    test "delete button renders for done sessions", %{conn: conn, project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, ws} = Destila.Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})
      seed_welcome_message(ws)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#delete-btn")
    end
  end

  describe "deleted session direct navigation" do
    @tag feature: @feature, scenario: "Deleted session detail page is no longer accessible"
    test "direct URL redirects to crafting", %{conn: conn, project: project} do
      ws = create_session(%{project_id: project.id})
      {:ok, deleted} = Destila.Workflows.delete_workflow_session(ws)

      {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/sessions/#{deleted.id}")

      assert to == "/crafting"
    end
  end
end
