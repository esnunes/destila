defmodule Destila.Services.ServiceManager do
  @moduledoc """
  Target-agnostic engine for the lifecycle of a development service.

  Operates on `Destila.Services.Target` so the same code path serves both
  per-session services (running in window 9 of the session's tmux session,
  inside the session's isolated worktree) and project-level services
  (running in window 0 of a dedicated `destila-service-project-<id>` tmux
  session, against the project's primary checkout on the default branch).

  Status persistence and `service_state` writes are owned by the calling
  context (`Destila.Workflows` or `Destila.Services.ProjectServices`); this
  module only persists the per-session `service_state` to keep existing
  callers byte-for-byte identical. Project-target callers receive
  `{:ok, state_map}` and persist via their own context.
  """

  alias Destila.{Projects, PubSubHelper, Workflows}
  alias Destila.Projects.Project
  alias Destila.Services.{LogTailer, Logs, Target}
  alias Destila.Terminal.Tmux
  import Destila.StringHelper, only: [blank?: 1]
  require Logger

  @startup_timeout_ms 60_000
  @port_probe_interval_ms 500
  @port_probe_timeout_ms 500

  @webservice_precondition_error "Project is not configured as a webservice (requires run_command and service_env_var)"

  # ─── Session-target back-compat surface ─────────────────────────────────
  # Keeps existing call sites that pass a workflow session struct unchanged.

  @doc """
  Executes a service action for the given workflow session.

  Returns `{:ok, service_state_map}` or `{:error, reason}`.
  """
  def execute(%_{} = ws, action, opts \\ []) when is_binary(action) do
    case build_session_target(ws, opts) do
      {:ok, target} -> execute_target(target, action)
      {:error, _} = error -> error
    end
  end

  @doc """
  Truncates the session's log file and broadcasts a clear event.
  """
  def clear_logs(%{id: ws_id}) when is_binary(ws_id) do
    clear_logs_for("session-" <> ws_id, &PubSubHelper.broadcast_service_logs_cleared/1, ws_id)
  end

  @doc """
  Cleans up the service tmux window and clears the workflow session's
  persisted service state. Called during session archival.
  """
  def cleanup(ws) do
    project = ws.project_id && Projects.get_project(ws.project_id)

    target =
      case project && build_session_target(ws, project: project, worktree_path: nil) do
        {:ok, t} ->
          t

        _ ->
          # Fall back to a minimal session target so cleanup is best-effort
          # even when the project is gone.
          %Target{
            kind: :session,
            id: ws.id,
            cwd: nil,
            tmux_session_name: Tmux.session_name(ws),
            tmux_window: 9,
            log_key: "session-" <> ws.id,
            pubsub_topic: PubSubHelper.service_topic(ws.id),
            run_command: nil,
            setup_command: nil,
            service_env_var: nil,
            project: project,
            workflow_session: ws
          }
      end

    cleanup_target(target)
    Workflows.update_workflow_session(ws, %{service_state: nil})
    :ok
  end

  # ─── Target-API surface ─────────────────────────────────────────────────

  @doc """
  Executes an action (`"start" | "stop" | "restart" | "status"`) against
  the given target. Returns `{:ok, state_map} | {:error, reason}`.

  For session targets, `service_state` is also persisted on the workflow
  session for back-compat. For project targets the caller persists the
  returned state.
  """
  def execute_target(%Target{} = target, action) when is_binary(action) do
    case action do
      "start" -> do_start(target)
      "stop" -> do_stop(target)
      "restart" -> do_restart(target)
      "status" -> do_status(target)
      _ -> {:error, "Unknown service action: #{action}"}
    end
  end

  @doc """
  Truncates the target's log file and broadcasts a logs-cleared event on
  the target's PubSub topic.
  """
  def clear_logs_target(%Target{} = target) do
    broadcaster =
      case target.kind do
        :session -> &PubSubHelper.broadcast_service_logs_cleared/1
        :project -> &broadcast_project_logs_cleared/1
      end

    clear_logs_for(target.log_key, broadcaster, target.id)
  end

  @doc """
  Kills the tmux window, stops the LogTailer, and removes the log file.
  Best-effort; idempotent. Does NOT persist `service_state` — callers own
  the state transition.
  """
  def cleanup_target(%Target{} = target) do
    Tmux.kill_window(Target.tmux_address(target))
    LogTailer.stop_for(target.log_key)
    File.rm(Logs.log_path(target.log_key))
    :ok
  end

  @doc """
  Reserves an OS-assigned ephemeral port and returns it.
  """
  def reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # ─── Action implementations ─────────────────────────────────────────────

  defp do_start(%Target{} = target) do
    cond do
      not webservice_target?(target) ->
        {:error, @webservice_precondition_error}

      is_nil(target.cwd) or target.cwd == "" ->
        {:error, "Target has no working directory configured"}

      true ->
        port = reserve_port()
        log_path = Logs.log_path(target.log_key)
        tmux_address = Target.tmux_address(target)

        Logs.ensure_log_dir()
        File.write!(log_path, "")
        LogTailer.stop_for(target.log_key)

        Tmux.ensure_session(target.tmux_session_name, target.cwd)
        Tmux.kill_window(tmux_address)
        Tmux.new_window(tmux_address, cwd: target.cwd)
        Tmux.pipe_pane(tmux_address, "cat >> #{Tmux.escape_shell(log_path)}")
        LogTailer.start_for(target.log_key, topic: target.pubsub_topic)

        Tmux.send_keys(
          tmux_address,
          build_service_command(
            target.setup_command,
            target.run_command,
            target.service_env_var,
            port
          )
        )

        starting_state = %{
          "status" => "starting",
          "port" => port,
          "run_command" => target.run_command,
          "setup_command" => target.setup_command
        }

        persist_session_state(target, starting_state)
        broadcast_status(target, starting_state)
        Logger.info("ServiceManager: #{target.log_key} starting; waiting for port #{port}")

        if wait_for_port(port, @startup_timeout_ms) do
          Logger.info("ServiceManager: #{target.log_key} port responded; marking running")
          running_state = %{starting_state | "status" => "running"}
          persist_session_state(target, running_state)
          broadcast_status(target, running_state)
          {:ok, running_state}
        else
          Logger.warning(
            "ServiceManager: #{target.log_key} port did not respond within #{@startup_timeout_ms}ms; stopping"
          )

          do_stop(target)

          {:error,
           "Service did not become ready within #{div(@startup_timeout_ms, 1000)}s; stopped to avoid leaving an unreachable process running"}
        end
    end
  end

  defp do_stop(%Target{} = target) do
    tmux_address = Target.tmux_address(target)
    Tmux.term_panes(tmux_address)
    Tmux.kill_window(tmux_address)
    LogTailer.stop_for(target.log_key)

    prior_state = current_state(target) || %{}

    service_state =
      prior_state
      |> Map.take(["port", "run_command", "setup_command"])
      |> Map.put("status", "stopped")

    persist_session_state(target, service_state)
    broadcast_status(target, service_state)

    {:ok, service_state}
  end

  defp do_restart(%Target{} = target) do
    do_stop(target)
    do_start(refresh_target(target))
  end

  defp do_status(%Target{} = target) do
    current = current_state(target) || %{"status" => "stopped"}

    service_state =
      if current["status"] == "running" and
           not Tmux.window_exists?(Target.tmux_address(target)) do
        %{current | "status" => "stopped"}
      else
        current
      end

    if service_state != current do
      persist_session_state(target, service_state)
    end

    {:ok, service_state}
  end

  # ─── State helpers ──────────────────────────────────────────────────────

  defp persist_session_state(%Target{kind: :session, workflow_session: ws}, state)
       when not is_nil(ws) do
    Workflows.update_workflow_session(ws, %{service_state: state})
  end

  defp persist_session_state(_target, _state), do: :ok

  defp broadcast_status(%Target{kind: :session, id: ws_id}, state),
    do: PubSubHelper.broadcast_service_status(ws_id, state)

  defp broadcast_status(%Target{kind: :project, id: project_id}, state),
    do: PubSubHelper.broadcast_project_service_status(project_id, state)

  defp current_state(%Target{kind: :session, id: ws_id}) do
    case Workflows.get_workflow_session(ws_id) do
      nil -> nil
      ws -> ws.service_state
    end
  end

  defp current_state(%Target{kind: :project, id: project_id}) do
    case Projects.get_project(project_id) do
      nil -> nil
      project -> project.service_state
    end
  end

  defp refresh_target(%Target{kind: :session, workflow_session: ws} = target)
       when not is_nil(ws) do
    case Workflows.get_workflow_session(ws.id) do
      nil -> target
      fresh -> %{target | workflow_session: fresh}
    end
  end

  defp refresh_target(%Target{kind: :project, project: project} = target)
       when not is_nil(project) do
    case Projects.get_project(project.id) do
      nil -> target
      fresh -> %{target | project: fresh}
    end
  end

  defp refresh_target(target), do: target

  defp webservice_target?(%Target{run_command: run, service_env_var: env_var}) do
    not blank?(run) and not blank?(env_var)
  end

  defp clear_logs_for(log_key, broadcaster, broadcast_arg) do
    Logs.ensure_log_dir()
    File.write!(Logs.log_path(log_key), "")
    broadcaster.(broadcast_arg || log_key)
    :ok
  end

  defp broadcast_project_logs_cleared(project_id),
    do: PubSubHelper.broadcast_project_service_logs_cleared(project_id)

  defp build_session_target(%_{} = ws, opts) do
    project =
      Keyword.get(opts, :project) ||
        (ws.project_id && Projects.get_project(ws.project_id))

    cond do
      is_nil(project) ->
        {:error, "No project linked to this session"}

      not Project.webservice?(project) ->
        {:error, @webservice_precondition_error}

      true ->
        worktree_path = Keyword.get(opts, :worktree_path)
        {:ok, Target.for_session(ws, project: project, worktree_path: worktree_path)}
    end
  end

  # ─── Pure helpers ───────────────────────────────────────────────────────

  @doc false
  def build_service_command(setup_command, run_command, env_var, port) do
    env_export = "export #{env_var}=#{port}"
    run_command_expanded = substitute_port_placeholder(run_command, env_var, port)

    body =
      if blank?(setup_command) do
        run_command_expanded
      else
        "#{setup_command}; #{run_command_expanded}"
      end

    "#{env_export} && #{body}"
  end

  defp substitute_port_placeholder(run_command, env_var, port) do
    if blank?(env_var) do
      run_command
    else
      String.replace(run_command, "{#{env_var}}", Integer.to_string(port))
    end
  end

  defp wait_for_port(port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_port(port, deadline)
  end

  defp do_wait_for_port(port, deadline) do
    cond do
      port_open?(port) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@port_probe_interval_ms)
        do_wait_for_port(port, deadline)
    end
  end

  defp port_open?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], @port_probe_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end
end
