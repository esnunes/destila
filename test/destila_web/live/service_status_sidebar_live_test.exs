defmodule DestilaWeb.ServiceStatusSidebarLiveTest do
  @moduledoc """
  LiveView tests for Service status item in sidebar.
  Feature: features/service_status_sidebar.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @feature "service_status_sidebar"

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

  defp create_project(attrs) do
    {:ok, project} =
      Destila.Projects.create_project(
        Map.merge(
          %{name: "Test Project", local_folder: System.tmp_dir!()},
          attrs
        )
      )

    project
  end

  defp create_session(attrs) do
    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(
        Map.merge(
          %{
            title: "Test Session",
            workflow_type: :brainstorm_idea,
            project_id: nil,
            done_at: DateTime.utc_now(),
            current_phase: 4,
            total_phases: 4
          },
          attrs
        )
      )

    ws
  end

  describe "service item visibility" do
    @tag feature: @feature,
         scenario: "Service item visible when project is a webservice"
    test "shows service item when project has run_command and service_env_var", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws = create_session(%{project_id: project.id})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item")
    end

    @tag feature: @feature,
         scenario: "Service item hidden when project has no run_command"
    test "hides service item when project has no run_command", %{conn: conn} do
      project = create_project(%{run_command: nil, service_env_var: "PORT"})
      ws = create_session(%{project_id: project.id})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#service-status-item")
    end

    @tag feature: @feature,
         scenario: "Service item hidden when project has no service_env_var"
    test "hides service item when project has no service_env_var", %{conn: conn} do
      project = create_project(%{run_command: "mix phx.server", service_env_var: nil})
      ws = create_session(%{project_id: project.id})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#service-status-item")
    end

    @tag feature: @feature,
         scenario: "Service item hidden when session has no project"
    test "does not show service item when session has no project", %{conn: conn} do
      ws = create_session(%{project_id: nil})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#service-status-item")
      refute has_element?(view, "#service-status-link")
    end
  end

  describe "service icon color" do
    @tag feature: @feature,
         scenario: "Service icon is green when service is running"
    test "icon is green when service is running", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4000}
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-link")
      assert has_element?(view, "#service-status-item .text-green-500")
    end

    @tag feature: @feature,
         scenario: "Service icon is muted when service is stopped"
    test "icon is muted when service is stopped", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "stopped"}
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item .text-base-content\\/30")
    end

    @tag feature: @feature,
         scenario: "Nil service_state treated as stopped"
    test "icon is muted when service_state is nil", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws = create_session(%{project_id: project.id, service_state: nil})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item .text-base-content\\/30")
    end
  end

  describe "service link behavior" do
    @tag feature: @feature,
         scenario: "Running service with port is a clickable link"
    test "renders link with correct href when running with port", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4000}
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, ~s|#service-status-link[href="http://localhost:4000"]|)
      assert has_element?(view, ~s|#service-status-link[target="_blank"]|)
    end

    @tag feature: @feature,
         scenario: "Stopped service is not clickable"
    test "renders static element when stopped", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "stopped"}
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item")
      refute has_element?(view, "#service-status-link")
    end

    @tag feature: @feature,
         scenario: "Nil service_state treated as stopped"
    test "not a link when service_state is nil", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws = create_session(%{project_id: project.id, service_state: nil})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item")
      refute has_element?(view, "#service-status-link")
    end

    test "legacy service_state with ports map renders running icon but no link", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "ports" => %{"PORT" => 4712}}
        })

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item")
      refute has_element?(view, "#service-status-link")
      assert has_element?(view, "#service-status-item .text-green-500")
    end
  end

  describe "real-time updates" do
    @tag feature: @feature,
         scenario: "Service status updates in real-time"
    test "updates when service state changes via PubSub", %{conn: conn} do
      project =
        create_project(%{run_command: "mix phx.server", service_env_var: "PORT"})

      ws = create_session(%{project_id: project.id, service_state: nil})
      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#service-status-item")
      refute has_element?(view, "#service-status-link")

      {:ok, updated_ws} =
        Destila.Workflows.update_workflow_session(ws, %{
          service_state: %{"status" => "running", "port" => 4000}
        })

      send(view.pid, {:workflow_session_updated, updated_ws})

      assert has_element?(view, ~s|#service-status-link[href="http://localhost:4000"]|)
    end
  end
end
