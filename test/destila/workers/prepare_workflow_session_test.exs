defmodule Destila.Workers.PrepareWorkflowSessionTest do
  @moduledoc """
  Tests for the post-worktree setup hook.
  Feature: features/service_setup_command.feature
  """
  use DestilaWeb.ConnCase, async: false

  alias Destila.Terminal.FakeTmux
  alias Destila.Workers.PrepareWorkflowSession

  @feature "service_setup_command"

  setup do
    Application.put_env(:destila, :tmux, FakeTmux)
    FakeTmux.register()

    on_exit(fn ->
      Application.delete_env(:destila, :tmux)
      FakeTmux.stub_send_keys(nil)
    end)

    :ok
  end

  defp make_ws(id), do: %{id: id, title: "title-for-#{id}"}

  describe "run_post_worktree_setup/3" do
    @tag feature: @feature,
         scenario: "Post-worktree setup runs without allocating a port"
    test "sends the setup command plain, without any env exports" do
      project = %Destila.Projects.Project{
        setup_command: "mix deps.get",
        service_env_var: nil
      }

      ws = make_ws("my-session")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      assert_received {:tmux, :ensure_session, ["ws-my-session", "/tmp/wt"]}
      assert_received {:tmux, :kill_window, ["ws-my-session:9"]}
      assert_received {:tmux, :new_window, ["ws-my-session:9", [cwd: "/tmp/wt"]]}
      assert_received {:tmux, :send_keys, ["ws-my-session:9", "mix deps.get"]}
    end

    @tag feature: @feature,
         scenario: "Post-worktree setup runs without allocating a port"
    test "does not export the service_env_var even when configured" do
      project = %Destila.Projects.Project{
        setup_command: "mix deps.get",
        service_env_var: "PORT",
        run_command: "mix phx.server"
      }

      ws = make_ws("session-with-env-var")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      assert_received {:tmux, :send_keys, ["ws-session-with-env-var:9", command]}
      assert command == "mix deps.get"
      refute command =~ "export"
    end

    @tag feature: @feature,
         scenario: "A project without a setup command keeps its current behavior"
    test "does nothing when setup_command is nil" do
      project = %Destila.Projects.Project{setup_command: nil}
      ws = make_ws("no-setup")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      refute_received {:tmux, :new_window, _}
      refute_received {:tmux, :send_keys, _}
    end

    @tag feature: @feature,
         scenario: "A project without a setup command keeps its current behavior"
    test "does nothing when setup_command is an empty string" do
      project = %Destila.Projects.Project{setup_command: ""}
      ws = make_ws("empty-setup")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      refute_received {:tmux, :new_window, _}
      refute_received {:tmux, :send_keys, _}
    end

    test "does nothing when project is nil" do
      ws = make_ws("no-project")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(nil, "/tmp/wt", ws)

      refute_received {:tmux, :new_window, _}
      refute_received {:tmux, :send_keys, _}
    end

    @tag feature: @feature,
         scenario: "Setup failures do not block worktree readiness"
    test "returns :ok when tmux raises so perform/1 still calls worktree_ready/1" do
      FakeTmux.stub_send_keys(fn _target, _cmd -> raise "boom" end)

      project = %Destila.Projects.Project{setup_command: "mix deps.get"}
      ws = make_ws("raising-session")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      assert_received {:tmux, :send_keys, _}
    end
  end
end
