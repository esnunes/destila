defmodule Destila.Sessions.SessionProcess do
  @moduledoc """
  A gen_statem process that owns the complete state machine for a workflow session.

  Serializes all state access — no concurrent DB writes, no reload-and-check patterns.
  WorkflowRunnerLive communicates exclusively through this process for domain events.
  """

  @behaviour :gen_statem

  alias Destila.{AI, Executions, Workflows}
  alias Destila.Executions.StateMachine
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

  def send_message(session_id, content), do: call(session_id, {:user_message, content})
  def confirm_advance(session_id), do: call(session_id, :confirm_advance)
  def decline_advance(session_id), do: call(session_id, :decline_advance)
  def retry(session_id), do: call(session_id, :retry)
  def retry_setup(session_id), do: call(session_id, :retry_setup)
  def cancel(session_id), do: call(session_id, :cancel)
  def mark_done(session_id), do: call(session_id, :mark_done)
  def mark_undone(session_id), do: call(session_id, :mark_undone)

  def cast(session_id, event) do
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
  def callback_mode, do: :handle_event_function

  @impl true
  def init(session_id) do
    ws = Workflows.get_workflow_session!(session_id)
    state = reconstruct_state(ws)
    data = %{session_id: session_id, ws: ws}

    # For new sessions (no PE yet), kick off the first phase.
    {state, data} =
      if state == :setup do
        start_first_phase(data)
        ws = reload(data)
        {reconstruct_state(ws), %{data | ws: ws}}
      else
        {state, data}
      end

    {:ok, state, data, [inactivity_timeout()]}
  end

  # --- User message ---
  @impl true
  def handle_event({:call, from}, {:user_message, content}, {:phase, n, status}, data)
      when status in [:awaiting_input, :awaiting_confirmation] do
    case AI.Conversation.phase_update(data.ws, %{message: content}) do
      :processing ->
        transition_pe(data, n, :processing)
        ws = reload(data)
        broadcast_updated(ws)

        {:next_state, {:phase, n, :processing}, %{data | ws: ws},
         [{:reply, from, {:ok, ws}}, inactivity_timeout()]}

      :awaiting_input ->
        ws = reload(data)

        {:keep_state, %{data | ws: ws}, [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
    end
  end

  # --- Confirm advance ---
  def handle_event({:call, from}, :confirm_advance, {:phase, n, :awaiting_confirmation}, data) do
    {next_state, data} = advance(data, n)

    {:next_state, next_state, data, [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  # --- Decline advance ---
  def handle_event({:call, from}, :decline_advance, {:phase, n, :awaiting_confirmation}, data) do
    transition_pe(data, n, :awaiting_input, %{staged_result: nil})
    ws = reload(data)
    broadcast_updated(ws)

    {:next_state, {:phase, n, :awaiting_input}, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- AI response (phase must match to reject stale worker results) ---
  def handle_event(:cast, {:ai_response, result, phase}, {:phase, n, :processing}, data)
      when phase == n do
    case AI.Conversation.phase_update(data.ws, %{ai_result: result}) do
      :awaiting_input ->
        transition_pe(data, n, :awaiting_input)
        ws = reload(data)
        broadcast_updated(ws)
        {:next_state, {:phase, n, :awaiting_input}, %{data | ws: ws}, [inactivity_timeout()]}

      :suggest_phase_complete ->
        transition_pe(data, n, :awaiting_confirmation, %{staged_result: nil})
        ws = reload(data)
        broadcast_updated(ws)

        {:next_state, {:phase, n, :awaiting_confirmation}, %{data | ws: ws},
         [inactivity_timeout()]}

      :phase_complete ->
        complete_and_advance(data, n)
    end
  end

  # --- AI response from a stale/different phase — ignore ---
  def handle_event(:cast, {:ai_response, _result, _phase}, _state, _data) do
    :keep_state_and_data
  end

  # --- AI error (phase must match) ---
  def handle_event(:cast, {:ai_error, reason, phase}, {:phase, n, :processing}, data)
      when phase == n do
    AI.Conversation.phase_update(data.ws, %{ai_error: reason})
    transition_pe(data, n, :awaiting_input)
    ws = reload(data)
    broadcast_updated(ws)
    {:next_state, {:phase, n, :awaiting_input}, %{data | ws: ws}, [inactivity_timeout()]}
  end

  # --- AI error from a stale/different phase — ignore ---
  def handle_event(:cast, {:ai_error, _reason, _phase}, _state, _data) do
    :keep_state_and_data
  end

  # --- Retry ---
  def handle_event({:call, from}, :retry, {:phase, n, status}, data)
      when status in [:awaiting_input, :awaiting_confirmation] do
    AI.ClaudeSession.stop_for_workflow_session(data.session_id)
    AI.Conversation.handle_session_strategy(data.ws, n)

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

    ws = reload(data)
    AI.Conversation.phase_start(ws)

    ws = reload(data)
    broadcast_updated(ws)

    {:next_state, {:phase, n, :processing}, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- Retry setup ---
  def handle_event({:call, from}, :retry_setup, :setup, data) do
    start_first_phase(data)
    ws = reload(data)
    broadcast_updated(ws)

    {:keep_state, %{data | ws: ws}, [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- Cancel ---
  def handle_event({:call, from}, :cancel, {:phase, n, :processing}, data) do
    AI.ClaudeSession.stop_for_workflow_session(data.session_id)
    transition_pe(data, n, :awaiting_input)
    ws = reload(data)
    broadcast_updated(ws)

    {:next_state, {:phase, n, :awaiting_input}, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- Mark done ---
  def handle_event({:call, from}, :mark_done, {:phase, _n, status}, data)
      when status != :processing do
    # Create completion message (moved from LiveView)
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

  # --- Mark undone ---
  def handle_event({:call, from}, :mark_undone, :done, data) do
    {:ok, ws} = Workflows.update_workflow_session(data.ws, %{done_at: nil})
    state = reconstruct_state(ws)
    broadcast_updated(ws)

    {:next_state, state, %{data | ws: ws}, [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- Worktree ready ---
  def handle_event(:cast, :worktree_ready, state, data)
      when state == :setup or (is_tuple(state) and elem(state, 2) == :preparing) do
    ws = reload(data)
    phase = ws.current_phase
    {:ok, _pe} = Executions.ensure_phase_execution(ws, phase)
    AI.Conversation.phase_start(ws)
    ws = reload(data)
    broadcast_updated(ws)
    {:next_state, {:phase, phase, :processing}, %{data | ws: ws}, [inactivity_timeout()]}
  end

  # --- Inactivity timeout ---
  def handle_event(:state_timeout, :inactivity, _state, _data) do
    {:stop, :normal}
  end

  # --- Catch-all for unexpected events (MUST be last) ---
  # Returns {:error, :invalid_event} for calls so the LiveView can handle gracefully
  def handle_event({:call, from}, _event, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}
  end

  def handle_event(:cast, _event, _state, _data) do
    :keep_state_and_data
  end

  # Also handle plain :info messages (e.g., from Process.monitor, if any)
  def handle_event(:info, _msg, _state, _data) do
    :keep_state_and_data
  end

  # --- Helpers ---

  defp reconstruct_state(ws) do
    cond do
      Session.done?(ws) ->
        :done

      true ->
        case Executions.get_current_phase_execution(ws.id) do
          nil -> :setup
          %{status: :processing} -> {:phase, ws.current_phase, :processing}
          %{status: :awaiting_input} -> {:phase, ws.current_phase, :awaiting_input}
          %{status: :awaiting_confirmation} -> {:phase, ws.current_phase, :awaiting_confirmation}
          %{status: :failed} -> {:phase, ws.current_phase, :awaiting_input}
          %{status: :completed} -> {:phase, ws.current_phase, :processing}
        end
    end
  end

  defp reload(data), do: Workflows.get_workflow_session!(data.session_id)

  defp transition_pe(data, phase_number, status, extra_attrs \\ %{}) do
    case Executions.get_phase_execution_by_number(data.session_id, phase_number) do
      nil -> :ok
      pe -> StateMachine.transition(pe, status, extra_attrs)
    end
  end

  defp advance(data, current_phase) do
    # Complete current phase execution
    case Executions.get_current_phase_execution(data.session_id) do
      nil -> :ok
      pe when pe.status in [:completed, :skipped] -> :ok
      pe -> Executions.complete_phase(pe)
    end

    next = current_phase + 1
    ws = data.ws

    if next > ws.total_phases do
      {:ok, ws} = Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})
      broadcast_updated(ws)
      {:done, %{data | ws: ws}}
    else
      {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next})
      data = %{data | ws: ws}
      start_phase(data, next)
    end
  end

  defp complete_and_advance(data, current_phase) do
    {next_state, data} = advance(data, current_phase)
    {:next_state, next_state, data, [inactivity_timeout()]}
  end

  defp start_first_phase(data) do
    ws = data.ws

    case ensure_worktree_ready(ws) do
      :ready ->
        {:ok, _pe} = Executions.ensure_phase_execution(ws, ws.current_phase)
        AI.Conversation.phase_start(ws)

      :preparing ->
        :ok
    end
  end

  defp start_phase(data, phase_number) do
    ws = data.ws

    case ensure_worktree_ready(ws) do
      :ready ->
        {:ok, _pe} = Executions.ensure_phase_execution(ws, phase_number)
        AI.Conversation.phase_start(ws)
        ws = reload(data)
        broadcast_updated(ws)
        {{:phase, phase_number, :processing}, %{data | ws: ws}}

      :preparing ->
        broadcast_updated(ws)
        {{:phase, phase_number, :preparing}, data}
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
