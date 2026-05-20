defmodule Destila.Agent.SessionServer do
  @moduledoc """
  GenServer per active agent session. Receives tool calls from the HTTP+SSE
  transport via `Destila.Agent.EventRouter`, mutates session state via
  `Destila.Agent.Sessions`, and broadcasts UI events over PubSub.

  Phase advancement is *always* the result of an explicit `phase_complete`
  tool call. The server never advances on its own.
  """

  use GenServer

  alias Destila.Agent.{Sessions, ToolHandlers}
  alias Destila.Agent.Session

  @idle_timeout_ms :timer.minutes(30)

  # --- Client API ---

  def start_link(session_id),
    do: GenServer.start_link(__MODULE__, session_id, name: via(session_id))

  def child_spec(session_id) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [session_id]},
      restart: :temporary
    }
  end

  def ensure_started(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil ->
        case DynamicSupervisor.start_child(
               Destila.Agent.SessionSupervisor,
               {__MODULE__, session_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  def whereis(session_id), do: GenServer.whereis(via(session_id))

  def handle_tool_call(session_id, name, params) do
    with {:ok, pid} <- ensure_started(session_id) do
      GenServer.call(pid, {:tool_call, name, params})
    end
  end

  def sse_connected(session_id) do
    with {:ok, pid} <- ensure_started(session_id) do
      GenServer.cast(pid, :sse_connected)
    end
  end

  def sse_closed(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :sse_closed)
    end
  end

  def answer_question(session_id, question_id, value) do
    case whereis(session_id) do
      nil -> {:error, :no_server}
      pid -> GenServer.call(pid, {:answer_question, question_id, value})
    end
  end

  def get_state(session_id) do
    case whereis(session_id) do
      nil -> {:error, :no_server}
      pid -> GenServer.call(pid, :get_state)
    end
  end

  defp via(session_id), do: {:via, Registry, {Destila.Agent.SessionRegistry, session_id}}

  # --- GenServer callbacks ---

  @impl true
  def init(session_id) do
    case Sessions.get_session(session_id) do
      nil ->
        {:stop, {:no_session, session_id}}

      %Session{} = session ->
        {:ok,
         %{
           session: session,
           pending_questions: %{}
         }, @idle_timeout_ms}
    end
  end

  @impl true
  def handle_call({:tool_call, name, params}, _from, state) do
    {reply, state} = ToolHandlers.dispatch(name, params, state)
    {:reply, reply, state, @idle_timeout_ms}
  end

  def handle_call({:answer_question, question_id, value}, _from, state) do
    Sessions.broadcast_session(
      state.session.id,
      {:question_answered, question_id, value}
    )

    pending = Map.delete(state.pending_questions, question_id)
    {:reply, :ok, %{state | pending_questions: pending}, @idle_timeout_ms}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast(:sse_connected, state) do
    {:ok, session} =
      case state.session.status do
        :awaiting_agent -> Sessions.mark_connected(state.session)
        :disconnected -> Sessions.mark_connected(state.session)
        _ -> {:ok, state.session}
      end

    Sessions.broadcast_session(session.id, {:agent_connected, session})
    {:noreply, %{state | session: session}, @idle_timeout_ms}
  end

  def handle_cast(:sse_closed, state) do
    {:ok, session} =
      case state.session.status do
        :active -> Sessions.mark_disconnected(state.session)
        _ -> {:ok, state.session}
      end

    Sessions.broadcast_session(session.id, {:agent_disconnected, session})
    {:noreply, %{state | session: session}, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state, @idle_timeout_ms}
  end
end
