defmodule Destila.Agent.EmbeddedHost do
  @moduledoc """
  Lifecycle controller for embedded-host agent sessions: spawns a `claude`
  process inside `Destila.Terminal.Server`, pushes kickoff prompts and
  answers via stdin, and stops the process at phase boundaries.

  This module is mocked via Mimic in the test environment. Real PTY
  side-effects only happen in dev/prod.
  """

  alias Destila.Agent.McpConfigWriter
  alias Destila.Agent.Workflow.Phase

  require Logger

  @doc """
  Start a `claude` process for the given session/phase. Returns
  `{:ok, terminal_pid}` or `{:error, reason}`.
  """
  def start_phase(session_id, %Phase{} = phase, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    topic = "agent_session_terminal:#{session_id}"

    {:ok, files} = McpConfigWriter.write(session_id, phase)

    cmd = resolve_command(phase.agent_command, files)

    Logger.debug(fn -> "EmbeddedHost.start_phase: #{inspect(cmd)} cwd=#{cwd}" end)

    Destila.Terminal.Server.start_link(
      cwd: cwd,
      topic: topic,
      session_name: "agent-#{String.slice(session_id, 0, 12)}"
    )
  end

  def stop_phase(terminal_pid) when is_pid(terminal_pid) do
    if Process.alive?(terminal_pid) do
      Destila.Terminal.Server.write(terminal_pid, "\x03")
      :ok = GenServer.stop(terminal_pid, :normal, 5_000)
    end

    :ok
  rescue
    _ -> :ok
  end

  def stop_phase(_), do: :ok

  def push_kickoff(terminal_pid, kickoff_prompt) when is_pid(terminal_pid) do
    Destila.Terminal.Server.write(terminal_pid, kickoff_prompt <> "\n")
    :ok
  end

  def push_kickoff(_, _), do: :ok

  def push_answer(terminal_pid, value) when is_pid(terminal_pid) do
    Destila.Terminal.Server.write(terminal_pid, value <> "\n")
    :ok
  end

  def push_answer(_, _), do: :ok

  defp resolve_command(command, files) do
    Enum.map(command, fn arg ->
      arg
      |> String.replace("{{mcp_config_path}}", files.mcp_config_path)
      |> String.replace("{{system_prompt_path}}", files.system_prompt_path)
    end)
  end
end
