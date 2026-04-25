defmodule Destila.Services.ProjectServicesTest do
  @moduledoc """
  Lifecycle and pull-and-restart tests for project-level services.
  Feature: features/project_service.feature
  """
  use DestilaWeb.ConnCase, async: false
  use Mimic

  alias Destila.Git
  alias Destila.Projects
  alias Destila.PubSubHelper
  alias Destila.Services.{ProjectServices, ServiceManager}

  @feature "project_service"

  setup :set_mimic_from_context

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

  describe "start/1 singleton enforcement" do
    @tag feature: @feature,
         scenario: ~s|Singleton — start refuses when status is already "running"|
    test "refuses when status is already running" do
      project =
        create_project(%{service_state: %{"status" => "running", "port" => 4321}})

      assert {:error, :already_running} = ProjectServices.start(project)
    end

    @tag feature: @feature,
         scenario: ~s|Singleton — start accepts "starting" entry state|
    test "does not refuse when status is starting" do
      project = create_project(%{service_state: %{"status" => "starting"}})

      stub(ServiceManager, :execute_target, fn _target, "start" ->
        {:ok, %{"status" => "running", "port" => 4321}}
      end)

      assert {:ok, %{"status" => "running"}} = ProjectServices.start(project)
    end
  end

  describe "stop/1" do
    @tag feature: @feature,
         scenario: ~s|stop persists "stopped" status while preserving prior state fields|
    test "persists stopped status while preserving prior fields" do
      project =
        create_project(%{
          service_state: %{
            "status" => "running",
            "port" => 4321,
            "run_command" => "mix phx.server",
            "setup_command" => "mix deps.get"
          }
        })

      stub(ServiceManager, :execute_target, fn _t, "stop" ->
        {:ok, %{"status" => "stopped"}}
      end)

      assert {:ok, _} = ProjectServices.stop(project)

      reloaded = Projects.get_project(project.id)
      assert reloaded.service_state["status"] == "stopped"
      assert reloaded.service_state["port"] == 4321
      assert reloaded.service_state["run_command"] == "mix phx.server"
      assert reloaded.service_state["setup_command"] == "mix deps.get"
    end
  end

  describe "pull_and_restart/1" do
    setup do
      Phoenix.PubSub.subscribe(Destila.PubSub, "service:project-broadcast-test")
      :ok
    end

    @tag feature: @feature,
         scenario: "pull_and_restart no-ops when local is already up to date"
    test "noops and persists last_pulled_at when not ahead" do
      project = create_project(%{})
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(project.id))

      stub(Git, :fetch, fn _ -> :ok end)
      stub(Git, :default_branch, fn _ -> {:ok, "main"} end)
      stub(Git, :dirty?, fn _ -> {:ok, false} end)
      stub(Git, :diverged?, fn _ -> {:ok, false} end)
      stub(Git, :ahead?, fn _ -> {:ok, false} end)

      reject(&Git.fast_forward/1)
      reject(&ServiceManager.execute_target/2)

      assert {:ok, :noop} = ProjectServices.pull_and_restart(project.id)

      reloaded = Projects.get_project(project.id)
      assert reloaded.service_state["last_pulled_at"]
      assert reloaded.service_state["default_branch"] == "main"
    end

    @tag feature: @feature,
         scenario: "pull_and_restart restarts when local is behind origin"
    test "fast-forwards and restarts when ahead" do
      project = create_project(%{})
      test_pid = self()

      stub(Git, :fetch, fn _ -> :ok end)
      stub(Git, :default_branch, fn _ -> {:ok, "main"} end)
      stub(Git, :dirty?, fn _ -> {:ok, false} end)
      stub(Git, :diverged?, fn _ -> {:ok, false} end)
      stub(Git, :ahead?, fn _ -> {:ok, true} end)

      stub(Git, :fast_forward, fn _ ->
        send(test_pid, :git_fast_forward)
        :ok
      end)

      stub(ServiceManager, :execute_target, fn _target, action ->
        send(test_pid, {:execute_target, action})

        case action do
          "stop" -> {:ok, %{"status" => "stopped"}}
          "start" -> {:ok, %{"status" => "running", "port" => 4321}}
        end
      end)

      assert {:ok, _} = ProjectServices.pull_and_restart(project.id)

      assert_received :git_fast_forward
      assert_received {:execute_target, "stop"}
      assert_received {:execute_target, "start"}
    end

    @tag feature: @feature,
         scenario: "pull_and_restart halts on a dirty working tree"
    test "halts on dirty working tree" do
      project = create_project(%{})
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(project.id))

      stub(Git, :fetch, fn _ -> :ok end)
      stub(Git, :default_branch, fn _ -> {:ok, "main"} end)
      stub(Git, :dirty?, fn _ -> {:ok, true} end)
      reject(&Git.fast_forward/1)
      reject(&ServiceManager.execute_target/2)

      assert {:error, :dirty} = ProjectServices.pull_and_restart(project.id)
      assert_received {:project_service_error, :dirty, _}
    end

    @tag feature: @feature,
         scenario: "pull_and_restart halts on a diverged working tree"
    test "halts on diverged working tree" do
      project = create_project(%{})
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(project.id))

      stub(Git, :fetch, fn _ -> :ok end)
      stub(Git, :default_branch, fn _ -> {:ok, "main"} end)
      stub(Git, :dirty?, fn _ -> {:ok, false} end)
      stub(Git, :diverged?, fn _ -> {:ok, true} end)
      reject(&Git.fast_forward/1)
      reject(&ServiceManager.execute_target/2)

      assert {:error, :diverged} = ProjectServices.pull_and_restart(project.id)
      assert_received {:project_service_error, :diverged, _}
    end

    @tag feature: @feature,
         scenario: "pull_and_restart halts when fetch fails"
    test "halts when fetch fails" do
      project = create_project(%{})
      Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.project_service_topic(project.id))

      stub(Git, :fetch, fn _ -> {:error, "network down"} end)
      reject(&Git.fast_forward/1)
      reject(&ServiceManager.execute_target/2)

      assert {:error, "network down"} = ProjectServices.pull_and_restart(project.id)
      assert_received {:project_service_error, :fetch, _}
    end
  end

  describe "self_restart/1" do
    @tag feature: @feature,
         scenario: "self_restart raises on a non-self-hosted project"
    test "raises on non-self-hosted project" do
      project = create_project(%{local_folder: "/tmp/somewhere/else"})

      assert_raise ArgumentError, fn -> ProjectServices.self_restart(project) end
    end
  end

  describe "remove/1" do
    @tag feature: @feature,
         scenario: "remove clears state and cleans up tmux + log"
    test "clears service_state and cleans up tmux + log" do
      project =
        create_project(%{service_state: %{"status" => "running", "port" => 4321}})

      test_pid = self()

      stub(ServiceManager, :cleanup_target, fn _target ->
        send(test_pid, :cleanup_target_called)
        :ok
      end)

      stub(System, :cmd, fn cmd, args, opts ->
        send(test_pid, {:system_cmd, cmd, args, opts})
        {"", 0}
      end)

      assert :ok = ProjectServices.remove(project)

      assert_received :cleanup_target_called
      assert_received {:system_cmd, "tmux", ["kill-session", "-t", _], _}

      reloaded = Projects.get_project(project.id)
      assert is_nil(reloaded.service_state)
    end
  end

  describe "resume_all/0" do
    @tag feature: @feature,
         scenario: ~s|resume_all dispatches start/1 for "running" and "starting" projects|
    test "is :ok and only enumerates non-stopped, non-archived projects" do
      _running =
        create_project(%{
          name: "Running",
          service_state: %{"status" => "running", "port" => 4001}
        })

      _starting =
        create_project(%{
          name: "Starting",
          service_state: %{"status" => "starting"}
        })

      _stopped =
        create_project(%{
          name: "Stopped",
          service_state: %{"status" => "stopped"}
        })

      _archived =
        create_project(%{
          name: "Archived",
          service_state: %{"status" => "running"},
          archived_at: DateTime.utc_now()
        })

      eligible = Projects.list_projects_by_service_status(["running", "starting"])
      names = Enum.map(eligible, & &1.name) |> Enum.sort()
      assert names == ["Running", "Starting"]

      assert :ok = ProjectServices.resume_all()
    end
  end
end
