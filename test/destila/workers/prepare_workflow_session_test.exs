defmodule Destila.Workers.PrepareWorkflowSessionTest do
  @moduledoc """
  Tests for the post-worktree setup hook.
  Feature: features/service_setup_command.feature
  Feature: features/mise_auto_trust.feature
  """
  use DestilaWeb.ConnCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Destila.Terminal.Tmux
  alias Destila.Workers.PrepareWorkflowSession

  @feature "service_setup_command"

  setup :set_mimic_from_context

  setup do
    test_pid = self()

    stub(Tmux, :session_name, fn ws -> "ws-#{ws.id}" end)

    stub(Tmux, :ensure_session, fn name, cwd ->
      send(test_pid, {:tmux, :ensure_session, [name, cwd]})
      :ok
    end)

    stub(Tmux, :kill_window, fn target ->
      send(test_pid, {:tmux, :kill_window, [target]})
      {"", 0}
    end)

    stub(Tmux, :new_window, fn target, opts ->
      send(test_pid, {:tmux, :new_window, [target, opts]})
      {"", 0}
    end)

    stub(Tmux, :send_keys, fn target, cmd ->
      send(test_pid, {:tmux, :send_keys, [target, cmd]})
      {"", 0}
    end)

    stub(System, :cmd, fn cmd, args, opts ->
      send(test_pid, {:system, :cmd, [cmd, args, opts]})
      {"", 0}
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
      stub(Tmux, :send_keys, fn _target, _cmd -> raise "boom" end)

      project = %Destila.Projects.Project{setup_command: "mix deps.get"}
      ws = make_ws("raising-session")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)
    end
  end

  describe "run_post_worktree_setup/3 with mise_auto_trust" do
    @mise_feature "mise_auto_trust"

    @tag feature: @mise_feature,
         scenario: "Worktree preparation runs mise trust before the setup command"
    test "runs `mise trust -y` before the setup command when flag is on" do
      project = %Destila.Projects.Project{
        mise_auto_trust: true,
        setup_command: "mix deps.get"
      }

      ws = make_ws("mise-with-setup")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      assert_received {:system, :cmd, ["mise", ["trust", "-y"], opts]}
      assert Keyword.get(opts, :cd) == "/tmp/wt"
      assert Keyword.get(opts, :stderr_to_stdout) == true

      assert_received {:tmux, :send_keys, ["ws-mise-with-setup:9", "mix deps.get"]}
    end

    @tag feature: @mise_feature,
         scenario: "Worktree preparation runs mise trust even without a setup command"
    test "runs `mise trust -y` even when setup_command is blank" do
      project = %Destila.Projects.Project{
        mise_auto_trust: true,
        setup_command: nil
      }

      ws = make_ws("mise-no-setup")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      assert_received {:system, :cmd, ["mise", ["trust", "-y"], _opts]}
      refute_received {:tmux, :send_keys, _}
    end

    @tag feature: @mise_feature,
         scenario: "Worktree preparation skips mise trust when the flag is off"
    test "does not invoke mise when flag is off, but still runs setup_command" do
      project = %Destila.Projects.Project{
        mise_auto_trust: false,
        setup_command: "mix deps.get"
      }

      ws = make_ws("no-mise")

      assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)

      refute_received {:system, :cmd, ["mise", _, _]}
      assert_received {:tmux, :send_keys, ["ws-no-mise:9", "mix deps.get"]}
    end

    @tag feature: @mise_feature,
         scenario: "A non-zero mise exit is logged and does not block setup"
    test "non-zero mise exit is logged at warning level and setup still runs" do
      test_pid = self()

      stub(System, :cmd, fn "mise", ["trust", "-y"], _opts ->
        send(test_pid, :mise_called)
        {"failed to trust\n", 1}
      end)

      project = %Destila.Projects.Project{
        mise_auto_trust: true,
        setup_command: "mix deps.get"
      }

      ws = make_ws("mise-exit-1")

      log =
        capture_log(fn ->
          assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)
        end)

      assert_received :mise_called
      assert log =~ "[warning]"
      assert log =~ "failed to trust"

      assert_received {:tmux, :send_keys, ["ws-mise-exit-1:9", "mix deps.get"]}
    end

    @tag feature: @mise_feature,
         scenario: "A missing mise binary is logged and does not block setup"
    test "rescues a raised error from System.cmd (missing binary) and still runs setup" do
      stub(System, :cmd, fn "mise", ["trust", "-y"], _opts ->
        :erlang.error(:enoent)
      end)

      project = %Destila.Projects.Project{
        mise_auto_trust: true,
        setup_command: "mix deps.get"
      }

      ws = make_ws("mise-enoent")

      log =
        capture_log(fn ->
          assert :ok = PrepareWorkflowSession.run_post_worktree_setup(project, "/tmp/wt", ws)
        end)

      assert log =~ "[warning]"
      assert log =~ "mise"

      assert_received {:tmux, :send_keys, ["ws-mise-enoent:9", "mix deps.get"]}
    end
  end
end
