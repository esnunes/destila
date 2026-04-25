defmodule Destila.Workers.ProjectServicePullRestartWorkerTest do
  @moduledoc """
  Tests for the project-service pull-restart funnel worker.
  Feature: features/project_service.feature
  """
  use DestilaWeb.ConnCase, async: false
  use Mimic

  alias Destila.Projects
  alias Destila.Services.ProjectServices
  alias Destila.Workers.ProjectServicePullRestartWorker

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

  describe "perform/1" do
    @tag feature: @feature,
         scenario: "archived projects are skipped by the polling worker"
    test "archived projects are skipped in cron mode" do
      _archived =
        create_project(%{
          name: "Archived",
          service_state: %{"status" => "running"},
          archived_at: DateTime.utc_now()
        })

      test_pid = self()

      stub(ProjectServices, :pull_and_restart, fn id ->
        send(test_pid, {:pull_and_restart, id})
        {:ok, :noop}
      end)

      assert :ok = perform_job(ProjectServicePullRestartWorker, %{})

      refute_received {:pull_and_restart, _}
    end

    @tag feature: @feature,
         scenario:
           "ProjectServicePullRestartWorker dispatches a single project when given project_id"
    test "targeted mode dispatches the single project" do
      project =
        create_project(%{
          name: "Targeted",
          service_state: %{"status" => "running"}
        })

      _other =
        create_project(%{
          name: "Other",
          service_state: %{"status" => "running"}
        })

      test_pid = self()

      stub(ProjectServices, :pull_and_restart, fn id ->
        send(test_pid, {:pull_and_restart, id})
        {:ok, :noop}
      end)

      assert :ok = perform_job(ProjectServicePullRestartWorker, %{"project_id" => project.id})

      assert_received {:pull_and_restart, project_id}
      assert project_id == project.id

      refute_received {:pull_and_restart, _}
    end

    test "cron mode iterates running and starting non-archived projects" do
      running =
        create_project(%{
          name: "Running",
          service_state: %{"status" => "running"}
        })

      starting =
        create_project(%{
          name: "Starting",
          service_state: %{"status" => "starting"}
        })

      _stopped =
        create_project(%{
          name: "Stopped",
          service_state: %{"status" => "stopped"}
        })

      test_pid = self()

      stub(ProjectServices, :pull_and_restart, fn id ->
        send(test_pid, {:pull_and_restart, id})
        {:ok, :noop}
      end)

      assert :ok = perform_job(ProjectServicePullRestartWorker, %{})

      running_id = running.id
      starting_id = starting.id
      assert_received {:pull_and_restart, ^running_id}
      assert_received {:pull_and_restart, ^starting_id}
      refute_received {:pull_and_restart, _}
    end
  end
end
