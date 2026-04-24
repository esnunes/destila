defmodule DestilaWeb.ServicesLiveTest do
  @moduledoc """
  LiveView tests for the services index page.
  Feature: features/services_index.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.PubSubHelper

  @feature "services_index"

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

  defp webservice_project(extra \\ %{}) do
    create_project(
      Map.merge(
        %{
          name: "Web Project #{System.unique_integer([:positive])}",
          run_command: "mix phx.server",
          service_env_var: "PORT",
          setup_command: "mix deps.get"
        },
        extra
      )
    )
  end

  describe "mount and eligibility" do
    @tag feature: @feature,
         scenario: "Index lists services for non-archived sessions with webservice projects"
    test "lists rows for eligible sessions and excludes ineligible ones", %{conn: conn} do
      project = webservice_project()
      non_web_project = create_project(%{name: "Non-Web", run_command: nil, service_env_var: nil})

      ws_running =
        create_session(%{
          project_id: project.id,
          title: "Running Service",
          service_state: %{"status" => "running", "port" => 4321}
        })

      ws_stopped =
        create_session(%{
          project_id: project.id,
          title: "Stopped Service",
          service_state: %{"status" => "stopped"}
        })

      ws_non_web =
        create_session(%{project_id: non_web_project.id, title: "Non-Web Session"})

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#service-row-#{ws_running.id}")
      assert has_element?(view, "#service-row-#{ws_stopped.id}")
      refute has_element?(view, "#service-row-#{ws_non_web.id}")
    end

    @tag feature: @feature, scenario: "Archived sessions are excluded"
    test "archived sessions do not appear", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4321}
        })

      {:ok, _} = Destila.Workflows.archive_workflow_session(ws)

      {:ok, view, _html} = live(conn, ~p"/services")

      refute has_element?(view, "#service-row-#{ws.id}")
    end

    @tag feature: @feature,
         scenario: "Sessions whose project is not a webservice are excluded"
    test "sessions with non-webservice projects are excluded", %{conn: conn} do
      missing_run =
        create_project(%{name: "Missing Run", run_command: nil, service_env_var: "PORT"})

      missing_env =
        create_project(%{
          name: "Missing Env",
          run_command: "mix phx.server",
          service_env_var: nil
        })

      ws1 = create_session(%{project_id: missing_run.id})
      ws2 = create_session(%{project_id: missing_env.id})

      {:ok, view, _html} = live(conn, ~p"/services")

      refute has_element?(view, "#service-row-#{ws1.id}")
      refute has_element?(view, "#service-row-#{ws2.id}")
    end

    @tag feature: @feature, scenario: "Sessions with no project are excluded"
    test "sessions with nil project_id are excluded", %{conn: conn} do
      ws = create_session(%{project_id: nil})

      {:ok, view, _html} = live(conn, ~p"/services")

      refute has_element?(view, "#service-row-#{ws.id}")
    end
  end

  describe "row rendering" do
    @tag feature: @feature, scenario: "Row shows status, port, session, and project"
    test "row displays status, port, title, and project name", %{conn: conn} do
      project = webservice_project(%{name: "Acme"})

      ws =
        create_session(%{
          project_id: project.id,
          title: "Checkout Service",
          service_state: %{"status" => "running", "port" => 4321}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#service-row-#{ws.id}", "Checkout Service")
      assert has_element?(view, "#service-row-#{ws.id}", "Acme")
      assert has_element?(view, "#service-row-#{ws.id}", "running")
      assert has_element?(view, "#service-row-#{ws.id}", "4321")
    end

    @tag feature: @feature, scenario: "Running service row shows a clickable localhost URL"
    test "running service row exposes a localhost URL anchor", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4321}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(
               view,
               ~s|#service-url-#{ws.id}[href="http://localhost:4321"][target="_blank"][rel="noopener noreferrer"]|
             )
    end

    @tag feature: @feature, scenario: "Stopped service row hides the URL"
    test "stopped service row does not render a localhost URL", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "stopped"}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#service-row-#{ws.id}")
      refute has_element?(view, "#service-url-#{ws.id}")
    end

    @tag feature: @feature, scenario: "Row navigates to the service detail page"
    test "row link navigates to /services/:id", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "stopped"}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, ~s|#service-row-#{ws.id}[href="/services/#{ws.id}"]|)
    end

    @tag feature: @feature, scenario: "No inline lifecycle controls in the list"
    test "page does not expose lifecycle controls", %{conn: conn} do
      project = webservice_project()

      _ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4321}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      refute has_element?(view, "#start-service-button")
      refute has_element?(view, "#stop-service-button")
      refute has_element?(view, "#restart-service-button")
      refute has_element?(view, "#clear-logs-button")
    end
  end

  describe "empty state" do
    @tag feature: @feature, scenario: "Empty state when no eligible services exist"
    test "shows empty state when no eligible sessions", %{conn: conn} do
      non_web = create_project(%{name: "Non-Web", run_command: nil, service_env_var: nil})
      _ws = create_session(%{project_id: non_web.id})

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#services-empty")
    end
  end

  describe "live updates" do
    @tag feature: @feature, scenario: "List updates live when a service starts"
    test "service_status broadcast flips a row to running and shows URL", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "stopped"}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      refute has_element?(view, "#service-url-#{ws.id}")

      {:ok, _updated} =
        Destila.Workflows.update_workflow_session(ws, %{
          service_state: %{"status" => "running", "port" => 4321}
        })

      PubSubHelper.broadcast_service_status(ws.id, %{
        "status" => "running",
        "port" => 4321
      })

      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               ~s|#service-url-#{ws.id}[href="http://localhost:4321"]|
             )
    end

    @tag feature: @feature, scenario: "List updates live when a service stops"
    test "service_status broadcast hides URL when service stops", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4321}
        })

      {:ok, view, _html} = live(conn, ~p"/services")

      assert has_element?(view, "#service-url-#{ws.id}")

      {:ok, _updated} =
        Destila.Workflows.update_workflow_session(ws, %{
          service_state: %{"status" => "stopped", "port" => 4321}
        })

      PubSubHelper.broadcast_service_status(ws.id, %{
        "status" => "stopped",
        "port" => 4321
      })

      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#service-url-#{ws.id}")
    end
  end

  describe "navigation" do
    @tag feature: @feature,
         scenario: "Services page is reachable from the top-level navigation"
    test "sidebar exposes a link to /services", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a[href="/services"]|)
    end
  end
end
