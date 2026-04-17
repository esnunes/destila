defmodule Destila.Services.ServiceManager do
  @moduledoc """
  Manages the lifecycle of a project's development service within a
  workflow session's tmux session.

  Handles port reservation, tmux window creation, process management,
  and service state persistence. The service always runs in tmux window
  index 9 of the session.
  """

  alias Destila.{Projects, Workflows}
  alias Destila.Projects.Project
  alias Destila.Terminal.Tmux
  import Destila.StringHelper, only: [blank?: 1]
  require Logger

  @service_window 9
  @startup_timeout_ms 60_000
  @port_probe_interval_ms 500
  @port_probe_timeout_ms 500

  @webservice_precondition_error "Project is not configured as a webservice (requires run_command and service_env_var)"

  @doc """
  Executes a service action for the given workflow session.

  Returns `{:ok, service_state_map}` or `{:error, reason}`.
  """
  def execute(ws, action, opts \\ []) do
    case action do
      "start" -> do_start(ws, opts)
      "stop" -> do_stop(ws)
      "restart" -> do_restart(ws, opts)
      "status" -> do_status(ws)
      _ -> {:error, "Unknown service action: #{action}"}
    end
  end

  @doc """
  Cleans up the service tmux window and clears service state.
  Called during session archival.
  """
  def cleanup(ws) do
    Tmux.kill_window(service_target(ws))
    Workflows.update_workflow_session(ws, %{service_state: nil})
    :ok
  end

  # --- Private ---

  defp do_start(ws, opts) do
    project = Projects.get_project(ws.project_id)

    cond do
      is_nil(project) ->
        {:error, "No project linked to this session"}

      not Project.webservice?(project) ->
        {:error, @webservice_precondition_error}

      true ->
        port = reserve_port()
        worktree_path = Keyword.get(opts, :worktree_path)
        session = Tmux.session_name(ws)
        target = service_target(ws)

        Tmux.ensure_session(session, worktree_path)
        Tmux.kill_window(target)
        Tmux.new_window(target, cwd: worktree_path)

        Tmux.send_keys(
          target,
          build_service_command(
            project.setup_command,
            project.run_command,
            project.service_env_var,
            port
          )
        )

        starting_state = %{
          "status" => "starting",
          "port" => port,
          "run_command" => project.run_command,
          "setup_command" => project.setup_command
        }

        Workflows.update_workflow_session(ws, %{service_state: starting_state})
        Logger.info("ServiceManager: #{ws.id} starting; waiting for port #{port}")

        if wait_for_port(port, @startup_timeout_ms) do
          Logger.info("ServiceManager: #{ws.id} port responded; marking running")
          running_state = %{starting_state | "status" => "running"}
          Workflows.update_workflow_session(ws, %{service_state: running_state})
          {:ok, running_state}
        else
          Logger.warning(
            "ServiceManager: #{ws.id} port did not respond within #{@startup_timeout_ms}ms; stopping"
          )

          do_stop(ws)

          {:error,
           "Service did not become ready within #{div(@startup_timeout_ms, 1000)}s; stopped to avoid leaving an unreachable process running"}
        end
    end
  end

  defp do_stop(ws) do
    target = service_target(ws)
    Tmux.term_panes(target)
    Tmux.kill_window(target)

    ws = Workflows.get_workflow_session!(ws.id)

    prior_state = ws.service_state || %{}

    service_state =
      prior_state
      |> Map.take(["port", "run_command", "setup_command"])
      |> Map.put("status", "stopped")

    Workflows.update_workflow_session(ws, %{service_state: service_state})

    {:ok, service_state}
  end

  defp do_restart(ws, opts) do
    do_stop(ws)
    ws = Workflows.get_workflow_session!(ws.id)
    do_start(ws, opts)
  end

  defp do_status(ws) do
    current_state = ws.service_state || %{"status" => "stopped"}

    service_state =
      if current_state["status"] == "running" and
           not Tmux.window_exists?(service_target(ws)) do
        %{current_state | "status" => "stopped"}
      else
        current_state
      end

    if service_state != current_state do
      Workflows.update_workflow_session(ws, %{service_state: service_state})
    end

    {:ok, service_state}
  end

  # --- Helpers ---

  defp service_target(ws), do: "#{Tmux.session_name(ws)}:#{@service_window}"

  @doc false
  def build_service_command(setup_command, run_command, env_var, port) do
    env_export = "export #{env_var}=#{port}"

    body =
      if blank?(setup_command) do
        run_command
      else
        "#{setup_command}; #{run_command}"
      end

    "#{env_export} && #{body}"
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

  @doc false
  def reserve_port do
    {:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
