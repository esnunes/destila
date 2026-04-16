defmodule Destila.AI.AlivenessTracker do
  @moduledoc """
  Centralized GenServer that monitors all AI session processes and exposes
  aliveness via ETS (for instant reads) and PubSub (for change notifications).

  Tracks aliveness by two independent keys — `workflow_session_id` (stable
  across AI sessions for a given workflow) and `ai_session_id` (one per
  Destila.AI.Session row). Both share the underlying monitored pid so a
  single :DOWN clears both keys atomically.
  """

  use GenServer

  require Logger

  @ets_table :ai_session_aliveness
  @pubsub_topic "session_aliveness"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns true if a ClaudeSession GenServer is running for the given workflow session ID."
  def alive?(workflow_session_id) do
    lookup({:workflow, workflow_session_id})
  end

  @doc "Returns true if a ClaudeSession GenServer is running for the given AI session ID."
  def alive_ai?(ai_session_id) do
    lookup({:ai, ai_session_id})
  end

  defp lookup(key) do
    case :ets.lookup(@ets_table, key) do
      [{^key, true}] -> true
      _ -> false
    end
  end

  @doc "PubSub topic for aliveness change notifications."
  def topic, do: @pubsub_topic

  @impl true
  def init(_) do
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(Destila.PubSub, Destila.PubSubHelper.claude_session_topic())

    # Scan for existing sessions already registered in the AI SessionRegistry.
    # Best-effort rehydrate of ai_session_id via the Repo — a missing row just
    # means the workflow key is populated and the ai key will be filled in by
    # the next :claude_session_started broadcast.
    refs =
      Registry.select(Destila.AI.SessionRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reduce(%{}, fn {workflow_session_id, pid}, acc ->
        ref = Process.monitor(pid)
        ai_session_id = lookup_ai_session_id(workflow_session_id)
        insert_entries(workflow_session_id, ai_session_id)
        Map.put(acc, ref, {workflow_session_id, ai_session_id})
      end)

    {:ok, %{refs: refs}}
  end

  @impl true
  def handle_info({:claude_session_started, workflow_session_id, ai_session_id}, state) do
    start_tracking(workflow_session_id, ai_session_id, state)
  end

  def handle_info({:claude_session_started, workflow_session_id}, state) do
    start_tracking(workflow_session_id, nil, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {{workflow_session_id, ai_session_id}, refs} ->
        delete_entries(workflow_session_id, ai_session_id)
        broadcast_workflow(workflow_session_id, false)
        if ai_session_id, do: broadcast_ai(ai_session_id, false)
        {:noreply, %{state | refs: refs}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_tracking(workflow_session_id, ai_session_id, state) do
    name = {:via, Registry, {Destila.AI.SessionRegistry, workflow_session_id}}

    case GenServer.whereis(name) do
      nil ->
        {:noreply, state}

      pid ->
        ref = Process.monitor(pid)
        state = put_in(state, [:refs, ref], {workflow_session_id, ai_session_id})
        insert_entries(workflow_session_id, ai_session_id)
        broadcast_workflow(workflow_session_id, true)
        if ai_session_id, do: broadcast_ai(ai_session_id, true)
        {:noreply, state}
    end
  end

  defp insert_entries(workflow_session_id, ai_session_id) do
    :ets.insert(@ets_table, {{:workflow, workflow_session_id}, true})
    if ai_session_id, do: :ets.insert(@ets_table, {{:ai, ai_session_id}, true})
  end

  defp delete_entries(workflow_session_id, ai_session_id) do
    :ets.delete(@ets_table, {:workflow, workflow_session_id})
    if ai_session_id, do: :ets.delete(@ets_table, {:ai, ai_session_id})
  end

  defp broadcast_workflow(workflow_session_id, alive?) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      @pubsub_topic,
      {:aliveness_changed, workflow_session_id, alive?}
    )
  end

  defp broadcast_ai(ai_session_id, alive?) do
    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      @pubsub_topic,
      {:aliveness_changed_ai, ai_session_id, alive?}
    )
  end

  defp lookup_ai_session_id(workflow_session_id) do
    case Destila.AI.get_ai_session_for_workflow(workflow_session_id) do
      nil -> nil
      ai_session -> ai_session.id
    end
  rescue
    error ->
      Logger.debug(
        "AlivenessTracker: lookup_ai_session_id/1 failed for #{inspect(workflow_session_id)}: #{Exception.message(error)}"
      )

      nil
  end
end
