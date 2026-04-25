defmodule Destila.Services.TargetTest do
  @moduledoc """
  Unit tests for the service Target abstraction.
  Feature: features/project_service.feature
  """
  use ExUnit.Case, async: true

  alias Destila.Projects.Project
  alias Destila.Services.Target
  alias Destila.Workflows.Session

  describe "for_project/1" do
    test "uses project-scoped tmux session name and window 0" do
      project = %Project{
        id: "abc123",
        name: "demo",
        local_folder: "/tmp/demo",
        run_command: "mix phx.server",
        setup_command: "mix deps.get",
        service_env_var: "PORT"
      }

      target = Target.for_project(project)

      assert target.kind == :project
      assert target.id == "abc123"
      assert target.cwd == "/tmp/demo"
      assert target.tmux_session_name == "destila-service-project-abc123"
      assert target.tmux_window == 0
      assert target.log_key == "project-abc123"
      assert target.pubsub_topic == "service:project-abc123"
      assert target.run_command == "mix phx.server"
      assert target.setup_command == "mix deps.get"
      assert target.service_env_var == "PORT"
      assert target.project == project
      assert target.workflow_session == nil
    end

    test "tmux_address joins session and window" do
      project = %Project{
        id: "p1",
        local_folder: "/tmp",
        run_command: "x",
        service_env_var: "P"
      }

      assert Target.tmux_address(Target.for_project(project)) ==
               "destila-service-project-p1:0"
    end
  end

  describe "for_session/2" do
    test "uses session-scoped tmux name and window 9" do
      project = %Project{
        id: "p1",
        run_command: "mix phx.server",
        setup_command: nil,
        service_env_var: "PORT"
      }

      ws = %Session{id: "ws-1", title: "Test"}

      target =
        Target.for_session(ws,
          project: project,
          worktree_path: "/tmp/wt"
        )

      assert target.kind == :session
      assert target.id == "ws-1"
      assert target.cwd == "/tmp/wt"
      assert target.tmux_window == 9
      assert target.log_key == "session-ws-1"
      assert target.pubsub_topic == "service:ws-1"
      assert target.workflow_session == ws
      assert target.project == project
    end
  end
end
