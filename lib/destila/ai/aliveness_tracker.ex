defmodule Destila.AI.AlivenessTracker do
  @moduledoc """
  Centralized GenServer that monitors all AI session processes and exposes
  aliveness via ETS (for instant reads) and PubSub (for change notifications).
  """

  use GenServer

  @ets_table :ai_session_aliveness
  @pubsub_topic "session_aliveness"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns true if an AI session GenServer is running for the given session ID."
  def alive?(session_id) do
    case :ets.lookup(@ets_table, session_id) do
      [{^session_id, true}] -> true
      _ -> false
    end
  end

  @doc "PubSub topic for aliveness change notifications."
  def topic, do: @pubsub_topic

  @impl true
  def init(_) do
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())

    # Scan for existing sessions already registered in the AI SessionRegistry
    refs =
      Registry.select(Destila.AI.SessionRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reduce(%{}, fn {session_id, pid}, acc ->
        ref = Process.monitor(pid)
        :ets.insert(@ets_table, {session_id, true})
        Map.put(acc, ref, session_id)
      end)

    {:ok, %{refs: refs}}
  end

  @impl true
  def handle_info({:claude_session_started, session_id}, state) do
    name = {:via, Registry, {Destila.AI.SessionRegistry, session_id}}

    case GenServer.whereis(name) do
      nil ->
        {:noreply, state}

      pid ->
        ref = Process.monitor(pid)
        :ets.insert(@ets_table, {session_id, true})
        broadcast(session_id, true)
        {:noreply, put_in(state, [:refs, ref], session_id)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _state} ->
        {:noreply, state}

      {session_id, refs} ->
        :ets.delete(@ets_table, session_id)
        broadcast(session_id, false)
        {:noreply, %{state | refs: refs}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(session_id, alive?) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      @pubsub_topic,
      {:aliveness_changed, session_id, alive?}
    )
  end
end
