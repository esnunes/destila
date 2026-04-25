defmodule Destila.Services.LogTailer do
  @moduledoc """
  One process per active service run. Polls the service's log file and
  broadcasts new bytes as `{:service_log, chunk}` on a configurable
  PubSub topic.

  The registration id is the `log_key` (the same string used to compute
  the log file path under `Destila.Services.Logs.log_path/1`). The
  broadcast topic is independent — sessions register under
  `"session-<uuid>"` but broadcast on `"service:<uuid>"`, and self-hosted
  Destila registers under `"project-destila-<branch>"` but broadcasts on
  `"service:project-<project-id>"`.

  A tailer exists only while a service is running. On crash the
  `DynamicSupervisor` does not restart the process (`restart: :temporary`);
  the user can restart the service to re-establish a tailer.
  """

  use GenServer, restart: :temporary

  alias Destila.Services.Logs

  @default_poll_ms 250

  @registry Destila.Services.LogTailerRegistry
  @supervisor Destila.Services.LogTailerSupervisor

  @doc """
  Starts (or no-ops if already running) a tailer for the given log key.

  Accepts an optional `:topic` keyword overriding the default broadcast
  topic of `"service:<log_key>"`.
  """
  def start_for(log_key, opts \\ []) when is_binary(log_key) do
    topic = Keyword.get(opts, :topic, "service:#{log_key}")

    case DynamicSupervisor.start_child(
           @supervisor,
           {__MODULE__, log_key: log_key, topic: topic}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Stops a running tailer for the given log key, if any. Idempotent.
  """
  def stop_for(log_key) when is_binary(log_key) do
    case Registry.lookup(@registry, log_key) do
      [{pid, _}] ->
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Returns `{:ok, pid} | :error` for the tailer registered under `log_key`.
  """
  def whereis(log_key) when is_binary(log_key) do
    case Registry.lookup(@registry, log_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def start_link(opts) do
    log_key = Keyword.fetch!(opts, :log_key)
    name = {:via, Registry, {@registry, log_key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    log_key = Keyword.fetch!(opts, :log_key)
    topic = Keyword.fetch!(opts, :topic)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)

    Logs.ensure_log_dir()
    log_path = Logs.log_path(log_key)

    unless File.exists?(log_path), do: File.write!(log_path, "")

    {:ok, io} = File.open(log_path, [:read, :binary])

    state = %{
      log_key: log_key,
      topic: topic,
      log_path: log_path,
      io: io,
      position: 0,
      poll_ms: poll_ms
    }

    schedule_poll(poll_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_once(state)
    schedule_poll(state.poll_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.io, do: File.close(state.io)
    :ok
  end

  # --- Private ---

  defp schedule_poll(ms), do: Process.send_after(self(), :poll, ms)

  defp poll_once(state) do
    case File.stat(state.log_path) do
      {:ok, %File.Stat{size: size}} when size > state.position ->
        read_and_broadcast(state, size)

      {:ok, %File.Stat{size: size}} when size < state.position ->
        reopen(state)

      _ ->
        state
    end
  end

  defp read_and_broadcast(state, size) do
    bytes_to_read = size - state.position

    case IO.binread(state.io, bytes_to_read) do
      :eof ->
        state

      {:error, _} ->
        state

      data when is_binary(data) ->
        Phoenix.PubSub.broadcast(Destila.PubSub, state.topic, {:service_log, data})
        %{state | position: state.position + byte_size(data)}
    end
  end

  defp reopen(state) do
    if state.io, do: File.close(state.io)

    case File.open(state.log_path, [:read, :binary]) do
      {:ok, io} -> %{state | io: io, position: 0}
      _ -> %{state | io: nil, position: 0}
    end
  end
end
