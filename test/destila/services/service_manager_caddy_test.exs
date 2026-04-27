defmodule Destila.Services.ServiceManagerCaddyTest do
  @moduledoc """
  Verifies that ServiceManager wires Caddy register/unregister into the
  service lifecycle and persists `caddy_route` into `service_state`.

  Feature: features/caddy_proxy.feature
  """
  use DestilaWeb.ConnCase, async: false
  use Mimic

  alias Destila.Projects
  alias Destila.Proxy.Caddy
  alias Destila.PubSubHelper
  alias Destila.Services.{ServiceManager, Target}
  alias Destila.Terminal.Tmux

  @feature "caddy_proxy"

  setup :set_mimic_from_context
  setup :stub_external

  defp stub_external(_) do
    stub(Tmux, :ensure_session, fn _, _ -> :ok end)
    stub(Tmux, :kill_window, fn _ -> :ok end)
    stub(Tmux, :new_window, fn _, _ -> :ok end)
    stub(Tmux, :pipe_pane, fn _, _ -> :ok end)
    stub(Tmux, :send_keys, fn _, _ -> :ok end)
    stub(Tmux, :term_panes, fn _ -> :ok end)
    stub(Tmux, :window_exists?, fn _ -> false end)
    :ok
  end

  defp create_project(attrs) do
    {:ok, project} =
      Projects.create_project(
        Map.merge(
          %{
            name: "Test Project",
            local_folder: System.tmp_dir!(),
            run_command: "mix phx.server",
            service_env_var: "PORT"
          },
          attrs
        )
      )

    project
  end

  defp project_target(project) do
    %Target{
      kind: :project,
      id: project.id,
      cwd: project.local_folder,
      tmux_session_name: "destila-test-" <> project.id,
      tmux_window: 0,
      log_key: "project-test-" <> project.id,
      pubsub_topic: PubSubHelper.project_service_topic(project.id),
      run_command: project.run_command,
      setup_command: project.setup_command,
      service_env_var: project.service_env_var,
      project: project,
      workflow_session: nil
    }
  end

  defp open_listener do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true, active: false])

    {:ok, port} = :inet.port(socket)
    parent = self()

    acceptor =
      spawn(fn ->
        send(parent, :acceptor_started)
        accept_loop(socket)
      end)

    receive do
      :acceptor_started -> :ok
    after
      1000 -> :ok
    end

    {socket, port, acceptor}
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket, 5_000) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        accept_loop(socket)

      {:error, :closed} ->
        :ok

      {:error, _other} ->
        accept_loop(socket)
    end
  end

  defp close_listener({socket, _port, acceptor}) do
    Process.exit(acceptor, :kill)
    :gen_tcp.close(socket)
  end

  describe "do_start: Caddy register hook" do
    @tag feature: @feature,
         scenario:
           "Project service start registers a Caddy route with a deterministic @id when domain is set"
    test "persists caddy_route=true when Caddy.register returns :registered" do
      project = create_project(%{domain: "myapp.example.com"})
      listener = open_listener()
      {_, port, _} = listener

      stub(ServiceManager, :reserve_port, fn -> port end)
      expect(Caddy, :preflight, fn _ -> :ok end)
      expect(Caddy, :register, fn _, ^port -> {:ok, :registered} end)

      target = project_target(project)

      assert {:ok, state} = ServiceManager.execute_target(target, "start")
      assert state["status"] == "running"
      assert state["caddy_route"] == true

      close_listener(listener)
    end

    @tag feature: @feature,
         scenario: "Project service start makes no Caddy calls when no domain is set"
    test "persists caddy_route=false when Caddy.register returns :no_proxy" do
      project = create_project(%{})
      listener = open_listener()
      {_, port, _} = listener

      stub(ServiceManager, :reserve_port, fn -> port end)
      expect(Caddy, :preflight, fn _ -> :ok end)
      expect(Caddy, :register, fn _, ^port -> {:ok, :no_proxy} end)

      target = project_target(project)

      assert {:ok, state} = ServiceManager.execute_target(target, "start")
      assert state["status"] == "running"
      assert state["caddy_route"] == false

      close_listener(listener)
    end

    @tag feature: @feature,
         scenario: "Register is a silent no-op when the Caddy admin URL is unreachable"
    test "persists caddy_route=false when Caddy is unreachable (no_proxy)" do
      project = create_project(%{domain: "myapp.example.com"})
      listener = open_listener()
      {_, port, _} = listener

      stub(ServiceManager, :reserve_port, fn -> port end)
      expect(Caddy, :preflight, fn _ -> :ok end)
      expect(Caddy, :register, fn _, ^port -> {:ok, :no_proxy} end)

      target = project_target(project)

      assert {:ok, state} = ServiceManager.execute_target(target, "start")
      assert state["status"] == "running"
      assert state["caddy_route"] == false

      close_listener(listener)
    end

    @tag feature: @feature,
         scenario:
           "Service start blocks with a clear error when basic auth is required and credentials are missing"
    test "preflight failure blocks before any tmux setup" do
      project = create_project(%{domain: "myapp.example.com", basic_auth_enabled: true})

      expect(Caddy, :preflight, fn _ -> {:error, :missing_credentials} end)

      reject(&Tmux.ensure_session/2)
      reject(&Caddy.register/2)

      target = project_target(project)

      assert {:error, message} = ServiceManager.execute_target(target, "start")
      assert message =~ "Basic auth is required"
    end

    @tag feature: @feature,
         scenario:
           "A non-2xx response from Caddy on register surfaces an error flash on the service detail page"
    test "broadcasts :service_proxy_error and persists caddy_route=false on non-2xx" do
      project = create_project(%{domain: "myapp.example.com"})
      listener = open_listener()
      {_, port, _} = listener

      stub(ServiceManager, :reserve_port, fn -> port end)
      expect(Caddy, :preflight, fn _ -> :ok end)

      expect(Caddy, :register, fn _, ^port ->
        {:error, {:caddy_status, 400, "bad route"}}
      end)

      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(project.id))

      target = project_target(project)

      assert {:ok, state} = ServiceManager.execute_target(target, "start")
      assert state["status"] == "running"
      assert state["caddy_route"] == false

      assert_receive {:service_proxy_error, {:caddy_status, 400, "bad route"}}, 500

      close_listener(listener)
    end
  end

  describe "do_stop: Caddy unregister hook" do
    @tag feature: @feature,
         scenario: "Service stop unregisters the route via DELETE /id/<route_id>"
    test "calls Caddy.unregister and persists caddy_route=false" do
      project =
        create_project(%{
          domain: "myapp.example.com",
          service_state: %{
            "status" => "running",
            "port" => 4321,
            "caddy_route" => true
          }
        })

      expect(Caddy, :unregister, fn _ -> :ok end)

      target = project_target(project)

      assert {:ok, state} = ServiceManager.execute_target(target, "stop")
      assert state["status"] == "stopped"
      assert state["caddy_route"] == false
    end

    test "logs but ignores Caddy.unregister errors during stop" do
      project = create_project(%{})

      expect(Caddy, :unregister, fn _ ->
        {:error, {:caddy_status, 500, "boom"}}
      end)

      target = project_target(project)

      assert {:ok, state} = ServiceManager.execute_target(target, "stop")
      assert state["status"] == "stopped"
    end
  end

  describe "cleanup_target: Caddy unregister hook" do
    test "calls Caddy.unregister during cleanup" do
      project = create_project(%{domain: "myapp.example.com"})

      expect(Caddy, :unregister, fn _ -> :ok end)

      target = project_target(project)

      assert :ok = ServiceManager.cleanup_target(target)
    end
  end
end
