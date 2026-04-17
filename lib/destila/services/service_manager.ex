defmodule Destila.Services.ServiceManager do
  @moduledoc """
  Manages the lifecycle of a project's development service within a
  workflow session's tmux session.

  Handles port reservation, tmux window creation, process management,
  and service state persistence. The service always runs in tmux window
  index 9 of the session.
  """

  alias Destila.{Projects, Workflows}
  alias Destila.Terminal.Tmux
  import Destila.StringHelper, only: [blank?: 1]

  @service_window 9
  @startup_timeout_ms 60_000
  @port_probe_interval_ms 500
  @port_probe_timeout_ms 500

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

      is_nil(project.run_command) or project.run_command == "" ->
        {:error, "Project has no run command configured"}

      true ->
        ports = reserve_ports(project.port_definitions)
        worktree_path = Keyword.get(opts, :worktree_path)
        session = Tmux.session_name(ws)
        target = service_target(ws)

        Tmux.ensure_session(session, worktree_path)
        Tmux.kill_window(target)
        Tmux.new_window(target, cwd: worktree_path)

        Tmux.send_keys(
          target,
          build_service_command(project.setup_command, project.run_command, ports)
        )

        ready? = wait_for_ports(Map.values(ports), @startup_timeout_ms)

        service_state = %{
          "status" => "running",
          "ready" => ready?,
          "ports" => ports,
          "run_command" => project.run_command,
          "setup_command" => project.setup_command
        }

        Workflows.update_workflow_session(ws, %{service_state: service_state})

        {:ok, service_state}
    end
  end

  defp do_stop(ws) do
    target = service_target(ws)
    Tmux.term_panes(target)
    Tmux.kill_window(target)

    service_state = %{
      "status" => "stopped",
      "ports" => (ws.service_state || %{})["ports"]
    }

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
  def build_service_command(setup_command, run_command, ports) do
    env_exports =
      ports
      |> Enum.map(fn {name, port} -> "export #{name}=#{port}" end)
      |> Enum.join(" && ")

    body =
      if blank?(setup_command) do
        run_command
      else
        "#{setup_command}; #{run_command}"
      end

    if env_exports != "" do
      "#{env_exports} && #{body}"
    else
      body
    end
  end

  defp wait_for_ports(ports, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_ports(ports, deadline)
  end

  defp do_wait_for_ports(ports, deadline) do
    cond do
      Enum.all?(ports, &port_open?/1) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@port_probe_interval_ms)
        do_wait_for_ports(ports, deadline)
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
  def reserve_ports(port_definitions) do
    Map.new(port_definitions, fn name ->
      {:ok, socket} = :gen_tcp.listen(0, reuseaddr: true)
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      {name, port}
    end)
  end
end
