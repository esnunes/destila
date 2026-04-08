defmodule Destila.Sessions.SessionProcess do
  @moduledoc """
  A gen_statem process that owns the complete state machine for a workflow session.

  States: :setup → :processing → :awaiting_input | :awaiting_confirmation → :done

  Serializes all state access — no concurrent DB writes, no reload-and-check patterns.
  WorkflowRunnerLive communicates exclusively through this process for domain events.
  """

  @behaviour :gen_statem

  alias Destila.{AI, Executions, Workflows}
  alias Destila.Workflows.Session

  @inactivity_timeout :timer.minutes(30)

  # --- Client API ---

  def start_link(session_id) do
    :gen_statem.start_link(via(session_id), __MODULE__, session_id, [])
  end

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
               Destila.Sessions.Supervisor,
               {__MODULE__, session_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end

      pid ->
        {:ok, pid}
    end
  end

  def send_message(session_id, content), do: call(session_id, {:send_message, content})
  def confirm_advance(session_id), do: call(session_id, :confirm_advance)
  def decline_advance(session_id), do: call(session_id, :decline_advance)
  def retry(session_id), do: call(session_id, :retry)
  def retry_setup(session_id), do: call(session_id, :retry_setup)
  def cancel(session_id), do: call(session_id, :cancel)
  def mark_done(session_id), do: call(session_id, :mark_done)
  def mark_undone(session_id), do: call(session_id, :mark_undone)

  def ai_response(session_id, result, phase), do: cast(session_id, {:ai_response, result, phase})
  def ai_error(session_id, reason, phase), do: cast(session_id, {:ai_error, reason, phase})
  def worktree_ready(session_id), do: cast(session_id, :worktree_ready)

  defp cast(session_id, event) do
    {:ok, _pid} = ensure_started(session_id)
    :gen_statem.cast(via(session_id), event)
  end

  defp call(session_id, event) do
    {:ok, _pid} = ensure_started(session_id)
    :gen_statem.call(via(session_id), event)
  end

  defp via(session_id), do: {:via, Registry, {Destila.Sessions.Registry, session_id}}

  # --- Callbacks ---

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(session_id) do
    ws = Workflows.get_workflow_session!(session_id)
    state = reconstruct_state(ws)
    data = %{session_id: session_id, ws: ws}

    actions =
      if state == :setup do
        [inactivity_timeout(), {:next_event, :internal, :initialize}]
      else
        [inactivity_timeout()]
      end

    {:ok, state, data, actions}
  end

  # =====================================================================
  # State: :setup
  # =====================================================================

  def setup(:internal, :initialize, data) do
    ws = data.ws

    case ensure_worktree_ready(ws) do
      :ready ->
        {:ok, _pe} = Executions.ensure_phase_execution(ws, ws.current_phase)
        AI.Conversation.phase_start(ws)
        broadcast_updated(ws)
        {:next_state, :processing, data, [inactivity_timeout()]}

      :preparing ->
        broadcast_updated(ws)
        {:keep_state, data, [inactivity_timeout()]}
    end
  end

  def setup({:call, from}, :retry_setup, data) do
    {:keep_state_and_data,
     [{:reply, from, {:ok, data.ws}}, {:next_event, :internal, :initialize}]}
  end

  def setup(:cast, :worktree_ready, data) do
    handle_worktree_ready(data)
  end

  def setup(:state_timeout, :inactivity, _data), do: {:stop, :normal}

  def setup({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}

  def setup(:cast, _event, _data), do: :keep_state_and_data
  def setup(:info, _msg, _data), do: :keep_state_and_data

  # =====================================================================
  # State: :processing (AI worker running)
  # =====================================================================

  def processing(:cast, {:ai_response, result, phase}, data) do
    if phase == data.ws.current_phase do
      case AI.Conversation.handle_ai_result(data.ws, result) do
        :awaiting_input ->
          with_current_pe(data, &Executions.await_input/1)
          broadcast_updated(data.ws)
          {:next_state, :awaiting_input, data, [inactivity_timeout()]}

        :suggest_phase_complete ->
          with_current_pe(data, &Executions.await_confirmation(&1, nil))
          broadcast_updated(data.ws)
          {:next_state, :awaiting_confirmation, data, [inactivity_timeout()]}

        :phase_complete ->
          complete_current_pe(data)
          {next_state, data} = advance(data)
          {:next_state, next_state, data, [inactivity_timeout()]}
      end
    else
      :keep_state_and_data
    end
  end

  def processing(:cast, {:ai_error, reason, phase}, data) do
    if phase == data.ws.current_phase do
      AI.Conversation.handle_ai_error(data.ws, reason)
      with_current_pe(data, &Executions.await_input/1)
      broadcast_updated(data.ws)
      {:next_state, :awaiting_input, data, [inactivity_timeout()]}
    else
      :keep_state_and_data
    end
  end

  def processing({:call, from}, :cancel, data) do
    AI.ClaudeSession.stop_for_workflow_session(data.session_id)
    with_current_pe(data, &Executions.await_input/1)
    broadcast_updated(data.ws)

    {:next_state, :awaiting_input, data, [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  def processing(:state_timeout, :inactivity, _data), do: {:stop, :normal}

  def processing({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}

  def processing(:cast, _event, _data), do: :keep_state_and_data
  def processing(:info, _msg, _data), do: :keep_state_and_data

  # =====================================================================
  # State: :awaiting_input (waiting for user message)
  # =====================================================================

  def awaiting_input({:call, from}, {:send_message, content}, data) do
    handle_send_message(from, content, data)
  end

  def awaiting_input({:call, from}, :retry, data) do
    handle_retry(from, data)
  end

  def awaiting_input({:call, from}, :mark_done, data) do
    handle_mark_done(from, data)
  end

  def awaiting_input(:state_timeout, :inactivity, _data), do: {:stop, :normal}

  def awaiting_input({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}

  def awaiting_input(:cast, _event, _data), do: :keep_state_and_data
  def awaiting_input(:info, _msg, _data), do: :keep_state_and_data

  # =====================================================================
  # State: :awaiting_confirmation (AI suggested phase_complete)
  # =====================================================================

  def awaiting_confirmation({:call, from}, {:send_message, content}, data) do
    handle_send_message(from, content, data)
  end

  def awaiting_confirmation({:call, from}, :confirm_advance, data) do
    complete_current_pe(data)
    {next_state, data} = advance(data)

    {:next_state, next_state, data, [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  def awaiting_confirmation({:call, from}, :decline_advance, data) do
    with_current_pe(data, &Executions.reject_completion/1)
    broadcast_updated(data.ws)

    {:next_state, :awaiting_input, data, [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  def awaiting_confirmation({:call, from}, :retry, data) do
    handle_retry(from, data)
  end

  def awaiting_confirmation({:call, from}, :mark_done, data) do
    handle_mark_done(from, data)
  end

  def awaiting_confirmation(:state_timeout, :inactivity, _data), do: {:stop, :normal}

  def awaiting_confirmation({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}

  def awaiting_confirmation(:cast, _event, _data), do: :keep_state_and_data
  def awaiting_confirmation(:info, _msg, _data), do: :keep_state_and_data

  # =====================================================================
  # State: :done
  # =====================================================================

  def done({:call, from}, :mark_undone, data) do
    {:ok, ws} = Workflows.update_workflow_session(data.ws, %{done_at: nil})
    state = reconstruct_state(ws)
    broadcast_updated(ws)

    {:next_state, state, %{data | ws: ws}, [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  def done(:state_timeout, :inactivity, _data), do: {:stop, :normal}

  def done({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}

  def done(:cast, _event, _data), do: :keep_state_and_data
  def done(:info, _msg, _data), do: :keep_state_and_data

  # --- Shared event handlers ---

  defp handle_send_message(from, content, data) do
    :processing = AI.Conversation.send_message(data.ws, content)
    with_current_pe(data, &Executions.process_phase/1)
    broadcast_updated(data.ws)

    {:next_state, :processing, data, [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  defp handle_retry(from, data) do
    phase = data.ws.current_phase
    AI.ClaudeSession.stop_for_workflow_session(data.session_id)
    AI.Conversation.handle_session_strategy(data.ws, phase)

    # Transition PE to processing BEFORE starting the phase,
    # so the PE is in the right state when the worker runs inline (Oban :inline in tests).
    case Executions.get_current_phase_execution(data.session_id) do
      %{status: :awaiting_confirmation} = pe ->
        {:ok, pe} = Executions.reject_completion(pe)
        Executions.process_phase(pe)

      %{status: s} = pe when s != :processing ->
        Executions.process_phase(pe)

      _ ->
        :ok
    end

    AI.Conversation.phase_start(data.ws)
    broadcast_updated(data.ws)

    {:next_state, :processing, data, [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  defp handle_mark_done(from, data) do
    ai_session = AI.get_ai_session_for_workflow(data.session_id)

    if ai_session do
      AI.create_message(ai_session.id, %{
        role: :system,
        content: Workflows.completion_message(data.ws.workflow_type),
        phase: data.ws.current_phase,
        workflow_session_id: data.session_id
      })
    end

    {:ok, ws} = Workflows.update_workflow_session(data.ws, %{done_at: DateTime.utc_now()})
    broadcast_updated(ws)

    {:next_state, :done, %{data | ws: ws}, [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  defp handle_worktree_ready(data) do
    ws = data.ws
    {:ok, _pe} = Executions.ensure_phase_execution(ws, ws.current_phase)
    AI.Conversation.phase_start(ws)
    broadcast_updated(ws)
    {:next_state, :processing, data, [inactivity_timeout()]}
  end

  # --- Helpers ---

  defp reconstruct_state(ws) do
    cond do
      Session.done?(ws) ->
        :done

      true ->
        case Executions.get_current_phase_execution(ws.id) do
          nil -> :setup
          %{status: :processing} -> :processing
          %{status: :awaiting_input} -> :awaiting_input
          %{status: :awaiting_confirmation} -> :awaiting_confirmation
          %{status: :failed} -> :awaiting_input
          %{status: :completed} -> :processing
        end
    end
  end

  defp with_current_pe(data, fun) do
    case Executions.get_phase_execution_by_number(data.session_id, data.ws.current_phase) do
      nil -> :ok
      pe -> fun.(pe)
    end
  end

  defp complete_current_pe(data) do
    case Executions.get_current_phase_execution(data.session_id) do
      nil -> :ok
      pe when pe.status in [:completed, :skipped] -> :ok
      pe -> Executions.complete_phase(pe)
    end
  end

  # Completes current phase and either finishes the session or starts the next phase.
  # Returns {next_state, updated_data}.
  defp advance(data) do
    ws = data.ws
    next = ws.current_phase + 1

    if next > ws.total_phases do
      {:ok, ws} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})
      broadcast_updated(ws)
      {:done, %{data | ws: ws}}
    else
      {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next})
      data = %{data | ws: ws}
      start_phase(data)
    end
  end

  # Creates PE, checks worktree readiness, kicks off AI.
  # Returns {state, data}.
  defp start_phase(data) do
    ws = data.ws

    case ensure_worktree_ready(ws) do
      :ready ->
        {:ok, _pe} = Executions.ensure_phase_execution(ws, ws.current_phase)
        AI.Conversation.phase_start(ws)
        broadcast_updated(ws)
        {:processing, data}

      :preparing ->
        broadcast_updated(ws)
        {:setup, data}
    end
  end

  defp ensure_worktree_ready(ws) do
    if ws.project_id do
      ai_session = AI.get_ai_session_for_workflow(ws.id)
      worktree_path = ai_session && ai_session.worktree_path

      if worktree_path && Destila.Git.worktree_exists?(worktree_path) do
        :ready
      else
        %{"workflow_session_id" => ws.id}
        |> Destila.Workers.PrepareWorkflowSession.new()
        |> Oban.insert()

        :preparing
      end
    else
      :ready
    end
  end

  defp broadcast_updated(ws) do
    Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end

  defp inactivity_timeout, do: {:state_timeout, @inactivity_timeout, :inactivity}
end
