defmodule DestilaWeb.ServiceDetailLiveTest do
  @moduledoc """
  LiveView tests for the service detail page.
  Feature: features/service_detail_page.feature
  """
  use DestilaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Destila.PubSubHelper
  alias Destila.Services.Logs

  @feature "service_detail_page"

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
        %{run_command: "mix phx.server", service_env_var: "PORT", setup_command: "mix deps.get"},
        extra
      )
    )
  end

  defp clear_log(ws_id) do
    Logs.ensure_log_dir()
    File.write!(Logs.log_path(ws_id), "")
  end

  describe "mount and status rendering" do
    @tag feature: @feature, scenario: "Running service renders status, port, URL, and commands"
    test "running service shows port, URL, and commands", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{
            "status" => "running",
            "port" => 4000,
            "run_command" => "mix phx.server",
            "setup_command" => "mix deps.get"
          }
        })

      clear_log(ws.id)

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      assert has_element?(
               view,
               ~s|#service-url-link[href="http://localhost:4000"][target="_blank"]|
             )

      assert has_element?(view, "#service-run-command", "mix phx.server")
      assert has_element?(view, "#service-setup-command", "mix deps.get")
      assert has_element?(view, "#service-port-text", "4000")
    end

    @tag feature: @feature, scenario: "Setup command block hidden when blank"
    test "setup_command block is hidden when project has no setup_command", %{conn: conn} do
      project = webservice_project(%{setup_command: nil})

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4000}
        })

      clear_log(ws.id)
      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      refute has_element?(view, "#setup-command-block")
      assert has_element?(view, "#run-command-block")
    end
  end

  describe "lifecycle buttons" do
    @tag feature: @feature, scenario: "Stopped service exposes Start and Clear logs controls"
    test "stopped service shows Start and Clear logs, hides Stop/Restart/URL", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "stopped"}
        })

      clear_log(ws.id)
      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      assert has_element?(view, "#start-service-button")
      assert has_element?(view, "#clear-logs-button")
      refute has_element?(view, "#stop-service-button")
      refute has_element?(view, "#restart-service-button")
      refute has_element?(view, "#service-url-link")
    end

    @tag feature: @feature,
         scenario: "Running service exposes Stop, Restart, and Clear logs controls"
    test "running service shows Stop, Restart, Clear logs; hides Start", %{conn: conn} do
      project = webservice_project()

      ws =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4000}
        })

      clear_log(ws.id)
      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      assert has_element?(view, "#stop-service-button")
      assert has_element?(view, "#restart-service-button")
      assert has_element?(view, "#clear-logs-button")
      refute has_element?(view, "#start-service-button")
    end

    @tag feature: @feature,
         scenario: "Clear logs button visible in both stopped and running states"
    test "Clear logs button visible in stopped and running states", %{conn: conn} do
      project = webservice_project()

      ws_stopped =
        create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})

      clear_log(ws_stopped.id)
      {:ok, view_stopped, _} = live(conn, ~p"/services/#{ws_stopped.id}")
      assert has_element?(view_stopped, "#clear-logs-button")

      ws_running =
        create_session(%{
          project_id: project.id,
          service_state: %{"status" => "running", "port" => 4000}
        })

      clear_log(ws_running.id)
      {:ok, view_running, _} = live(conn, ~p"/services/#{ws_running.id}")
      assert has_element?(view_running, "#clear-logs-button")
    end

    @tag feature: @feature, scenario: "Back link returns to the session detail page"
    test "back-to-session link present", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})
      clear_log(ws.id)

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      assert has_element?(view, ~s|#back-to-session-link[href="/sessions/#{ws.id}"]|)
    end
  end

  describe "log rendering" do
    @tag feature: @feature, scenario: "Initial log file contents render on mount"
    test "initial log contents render on mount", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})

      Logs.ensure_log_dir()
      File.write!(Logs.log_path(ws.id), "line one\nline two\n")

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      assert has_element?(view, "#service-logs", "line one")
      assert has_element?(view, "#service-logs", "line two")
    end

    @tag feature: @feature, scenario: "New log bytes stream into the viewer"
    test "a new log chunk appends a line to the viewer", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})
      clear_log(ws.id)

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      send(view.pid, {:service_log, "hello world\n"})

      assert has_element?(view, "#service-logs", "hello world")
    end

    @tag feature: @feature, scenario: "Partial log chunks buffer until a newline arrives"
    test "partial chunks buffer until a newline", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})
      clear_log(ws.id)

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      send(view.pid, {:service_log, "par"})
      # Force LiveView to flush the handle_info before assertion.
      _ = render(view)
      refute has_element?(view, "#service-logs", "par")

      send(view.pid, {:service_log, "tial\n"})
      assert has_element?(view, "#service-logs", "partial")
    end

    @tag feature: @feature, scenario: "Clear logs resets the viewer to an empty state"
    test "logs_cleared resets the stream and shows the empty state", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})

      Logs.ensure_log_dir()
      File.write!(Logs.log_path(ws.id), "seed\n")
      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")
      assert has_element?(view, "#service-logs", "seed")

      send(view.pid, {:service_logs_cleared, ws.id})

      refute has_element?(view, "#service-logs div[id^=\"log_lines-\"]")
      assert has_element?(view, "#service-logs-empty")
    end

    @tag feature: @feature, scenario: "Logs survive a page reload"
    test "logs survive a page reload", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})

      Logs.ensure_log_dir()
      File.write!(Logs.log_path(ws.id), "persisted\n")

      {:ok, view1, _html} = live(conn, ~p"/services/#{ws.id}")
      assert has_element?(view1, "#service-logs", "persisted")

      {:ok, view2, _html} = live(conn, ~p"/services/#{ws.id}")
      assert has_element?(view2, "#service-logs", "persisted")
    end
  end

  describe "pubsub integration" do
    @tag feature: @feature, scenario: "Status update from PubSub refreshes the header"
    test "service_status message updates the status pill", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})
      clear_log(ws.id)

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      PubSubHelper.broadcast_service_status(ws.id, %{
        "status" => "running",
        "port" => 4321,
        "run_command" => "mix phx.server"
      })

      assert has_element?(view, "#service-url-link[href=\"http://localhost:4321\"]")
    end

    @tag feature: @feature,
         scenario: "Workflow session update refreshes service state on the detail page"
    test "workflow_session_updated triggers a refresh", %{conn: conn} do
      project = webservice_project()
      ws = create_session(%{project_id: project.id, service_state: %{"status" => "stopped"}})
      clear_log(ws.id)

      {:ok, view, _html} = live(conn, ~p"/services/#{ws.id}")

      {:ok, updated_ws} =
        Destila.Workflows.update_workflow_session(ws, %{
          service_state: %{"status" => "running", "port" => 5000}
        })

      send(view.pid, {:workflow_session_updated, updated_ws})

      assert has_element?(view, "#service-url-link[href=\"http://localhost:5000\"]")
    end
  end

  describe "404 handling" do
    @tag feature: @feature, scenario: "Returns 404 for unknown session id"
    test "unknown id returns 404", %{conn: conn} do
      assert_error_sent 404, fn ->
        live(conn, ~p"/services/#{Ecto.UUID.generate()}")
      end
    end

    @tag feature: @feature, scenario: "Returns 404 for session with no project"
    test "session without project returns 404", %{conn: conn} do
      ws = create_session(%{project_id: nil})

      assert_error_sent 404, fn ->
        live(conn, ~p"/services/#{ws.id}")
      end
    end

    @tag feature: @feature,
         scenario: "Returns 404 for project without run_command"
    test "project without run_command returns 404", %{conn: conn} do
      project = create_project(%{run_command: nil, service_env_var: "PORT"})
      ws = create_session(%{project_id: project.id})

      assert_error_sent 404, fn ->
        live(conn, ~p"/services/#{ws.id}")
      end
    end

    @tag feature: @feature,
         scenario: "Returns 404 for project without service_env_var"
    test "project without service_env_var returns 404", %{conn: conn} do
      project = create_project(%{run_command: "mix phx.server", service_env_var: nil})
      ws = create_session(%{project_id: project.id})

      assert_error_sent 404, fn ->
        live(conn, ~p"/services/#{ws.id}")
      end
    end
  end
end
