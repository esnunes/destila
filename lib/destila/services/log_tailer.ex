defmodule Destila.Services.LogTailer do
  @moduledoc """
  One process per active service run. Polls the session's log file and
  broadcasts new bytes to `"service:<ws_id>"` as `{:service_log, chunk}`.

  A tailer exists only while a service is running. On crash the
  `DynamicSupervisor` does not restart the process (`restart: :temporary`);
  the user can restart the service to re-establish a tailer.
  """

  use GenServer, restart: :temporary

  alias Destila.PubSubHelper
  alias Destila.Services.Logs

  @default_poll_ms 250

  @registry Destila.Services.LogTailerRegistry
  @supervisor Destila.Services.LogTailerSupervisor

  @doc """
  Starts (or no-ops if already running) a tailer for the given workflow
  session id. Returns `{:ok, pid}` in both cases.
  """
  def start_for(ws_id) when is_binary(ws_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, ws_id: ws_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Stops a running tailer for the given workflow session id, if any.
  Idempotent — returns `:ok` whether or not a tailer was running.
  """
  def stop_for(ws_id) when is_binary(ws_id) do
    case Registry.lookup(@registry, ws_id) do
      [{pid, _}] ->
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Returns `{:ok, pid} | :error` for the tailer registered for `ws_id`.
  """
  def whereis(ws_id) when is_binary(ws_id) do
    case Registry.lookup(@registry, ws_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def start_link(opts) do
    ws_id = Keyword.fetch!(opts, :ws_id)
    name = {:via, Registry, {@registry, ws_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ws_id = Keyword.fetch!(opts, :ws_id)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)

    Logs.ensure_log_dir()
    log_path = Logs.log_path(ws_id)

    # Ensure the file exists so File.open succeeds even on a fresh start.
    unless File.exists?(log_path), do: File.write!(log_path, "")

    {:ok, io} = File.open(log_path, [:read, :binary])

    state = %{
      ws_id: ws_id,
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
        PubSubHelper.broadcast_service_log(state.ws_id, data)
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
