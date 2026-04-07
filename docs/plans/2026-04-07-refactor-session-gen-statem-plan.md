---
title: "refactor: Session as a gen_statem process"
type: refactor
date: 2026-04-07
---

# refactor: Session as a gen_statem process

## Overview

Replace `Destila.Executions.Engine` with a `Destila.Sessions.SessionProcess` `gen_statem` that owns the complete state machine for a workflow session. The process serializes all state access — no concurrent DB writes, no reload-and-check patterns, no race conditions. `WorkflowRunnerLive` communicates exclusively through `SessionProcess` for all domain events (user messages, phase advances, retries, etc.).

## Current state

The Engine (`lib/destila/executions/engine.ex`) is a stateless dispatcher:
- Reads DB → makes a decision → writes DB → broadcasts
- Called from 4 places: `WorkflowRunnerLive`, `AiQueryWorker`, `PrepareWorkflowSession`, and `Workflows.create_workflow_session`
- Each call re-fetches the session from DB, creating read-modify-write race windows
- The LiveView also directly calls `Executions` functions (e.g., `reject_completion` in `decline_advance`, `await_input` in `cancel_phase`) — bypassing Engine orchestration

`StateMachine` module (`lib/destila/executions/state_machine.ex`) already validates transitions and persists to DB. It stays — the `gen_statem` calls it internally.

### Current callers and their translations

| Caller | Current call | New call |
|--------|-------------|----------|
| `WorkflowRunnerLive` `send_text` | `Engine.phase_update(ws.id, phase, %{message: content})` | `SessionProcess.send_message(ws.id, content)` |
| `WorkflowRunnerLive` `confirm_advance` | `Engine.advance_to_next(ws)` | `SessionProcess.confirm_advance(ws.id)` |
| `WorkflowRunnerLive` `decline_advance` | `Executions.reject_completion(pe)` | `SessionProcess.decline_advance(ws.id)` |
| `WorkflowRunnerLive` `retry_phase` | `Engine.phase_retry(ws)` | `SessionProcess.retry(ws.id)` |
| `WorkflowRunnerLive` `cancel_phase` | `AI.ClaudeSession.stop_for_workflow_session` + `Executions.await_input` | `SessionProcess.cancel(ws.id)` |
| `WorkflowRunnerLive` `mark_done` | `Workflows.update_workflow_session(ws, %{done_at: ...})` | `SessionProcess.mark_done(ws.id)` |
| `WorkflowRunnerLive` `mark_undone` | `Workflows.update_workflow_session(ws, %{done_at: nil})` | `SessionProcess.mark_undone(ws.id)` |
| `WorkflowRunnerLive` `retry_setup` | `Engine.start_session(ws)` | `SessionProcess.retry_setup(ws.id)` |
| `AiQueryWorker` | `Engine.phase_update(ws.id, phase, %{ai_result: result})` | `SessionProcess.cast(ws.id, {:ai_response, result})` |
| `AiQueryWorker` | `Engine.phase_update(ws.id, phase, %{ai_error: reason})` | `SessionProcess.cast(ws.id, {:ai_error, reason})` |
| `PrepareWorkflowSession` | `Engine.phase_update(ws.id, phase, %{worktree_ready: true})` | `SessionProcess.cast(ws.id, :worktree_ready)` |
| `Workflows.create_workflow_session` | `Engine.start_session(ws)` | `SessionProcess.ensure_started(ws.id)` |

## Key design decisions

### 1. gen_statem with `:handle_event_function` callback mode

The state space is `{:phase, n, sub_status} | :done | :setup`, where `sub_status` is `:processing | :awaiting_input | :awaiting_confirmation | :preparing`. This maps naturally to `gen_statem` states. Using `:handle_event_function` (not `:state_functions`) gives a single `handle_event/4` with pattern matching on both state and event — cleaner for states that share event handlers.

### 2. User actions are synchronous calls, worker results are async casts

- **User actions** (`send_message`, `confirm_advance`, `decline_advance`, `retry`, `cancel`, `mark_done`, `mark_undone`) → `:gen_statem.call/2` returning `{:ok, ws}`. The LiveView gets immediate feedback.
- **Worker results** (`ai_response`, `ai_error`, `worktree_ready`) → `:gen_statem.cast/2`. The LiveView learns about these via PubSub broadcasts from SessionProcess.

### 3. AI streaming bypasses SessionProcess

Stream chunks already broadcast on `ai_stream:{ws_id}` directly from `ClaudeSession`. They're a display concern, not a state concern. No change needed.

### 4. PubSub broadcasts replace full reloads

SessionProcess broadcasts `{:workflow_session_updated, ws}` after state changes (reusing the existing event the LiveView already handles). This avoids introducing new PubSub events and keeps the LiveView's existing `handle_info` working during the transition.

Initially, the LiveView will continue doing full reloads on `:workflow_session_updated` (same as today). Incremental PubSub updates (`:message_added`, `:status_changed`) can be added as a follow-up optimization.

### 5. Process lifecycle: start on demand, terminate on inactivity

- `ensure_started/1` — looks up Registry, starts via DynamicSupervisor if not running
- `init/1` — loads session from DB, reconstructs state from phase execution status
- Inactivity timeout — 30 minutes of no events → process terminates (`:stop, :normal`)
- Crash recovery — next call to `ensure_started/1` re-spawns and reconstructs from DB

### 6. The LiveView becomes a thin translation layer

UI events → named client functions → SessionProcess → DB writes + PubSub → LiveView updates. The LiveView no longer imports `Destila.Executions.Engine` or directly calls `Executions` functions for state transitions.

### 7. What stays in the LiveView

- **Rendering** — templates, components, streaming chunk display
- **Question answer accumulation** — `question_answers` assign is UI state; only when submitted does it become a `send_message` call
- **Title editing** — direct `Workflows.update_workflow_session` call (cosmetic, not a state machine event)
- **Archive/Unarchive** — direct DB calls (session lifecycle, not phase state machine)
- **Aliveness monitoring** — Registry lookups + Process.monitor for ClaudeSession (unchanged)

### 8. Mark done includes completion message logic

Currently `mark_done` in the LiveView creates a system completion message before setting `done_at`. This logic moves into SessionProcess so it's centralized. The LiveView just calls `SessionProcess.mark_done(ws.id)`.

## gen_statem state space

```
States:
  :setup                                   — no PE yet, worktree being prepared
  {:phase, n, :preparing}                  — PE exists, worktree being prepared
  {:phase, n, :processing}                 — AI worker running
  {:phase, n, :awaiting_input}             — waiting for user
  {:phase, n, :awaiting_confirmation}      — AI suggests advance, user to confirm/decline
  :done                                    — workflow complete
```

State reconstruction from DB (used in `init/1` and `mark_undone`):

```elixir
defp reconstruct_state(ws) do
  cond do
    Session.done?(ws) -> :done
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
```

## Implementation steps

### Step 1: Add Registry and DynamicSupervisor to supervision tree

**File:** `lib/destila/application.ex`

Add before `DestilaWeb.Endpoint`:
```elixir
{Registry, keys: :unique, name: Destila.Sessions.Registry},
{DynamicSupervisor, name: Destila.Sessions.Supervisor, strategy: :one_for_one},
```

### Step 2: Create `Destila.Sessions.SessionProcess`

**File:** `lib/destila/sessions/session_process.ex`

#### Client API

```elixir
defmodule Destila.Sessions.SessionProcess do
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
        DynamicSupervisor.start_child(
          Destila.Sessions.Supervisor,
          {__MODULE__, session_id}
        )
      pid -> {:ok, pid}
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
end
```

#### Callbacks and handle_event clauses

```elixir
  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(session_id) do
    ws = Workflows.get_workflow_session!(session_id)
    state = reconstruct_state(ws)
    data = %{session_id: session_id, ws: ws}
    {:ok, state, data, [inactivity_timeout()]}
  end
```

**State enter callbacks:**

The `:enter` callback for `{:phase, n, :processing}` is where we start the AI conversation when transitioning into processing from a phase advance (not from user message — user messages handle their own enqueue). However, since enter callbacks fire on *every* state entry including re-entry, we need to be careful. The safest approach: do NOT use `:state_enter` for side effects. Instead, handle phase starts explicitly in the `advance/2` helper and `start_first_phase/1`.

**Decision: Drop `:state_enter`, use explicit helpers instead.** This avoids double-firing issues and keeps side effects explicit.

```elixir
  @impl true
  def callback_mode, do: :handle_event_function
```

**handle_event clauses:**

```elixir
  # --- User message ---
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
        {:keep_state, %{data | ws: ws},
         [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
    end
  end

  # --- Confirm advance ---
  def handle_event({:call, from}, :confirm_advance, {:phase, n, :awaiting_confirmation}, data) do
    {next_state, data} = advance(data, n)
    {:next_state, next_state, data,
     [{:reply, from, {:ok, data.ws}}, inactivity_timeout()]}
  end

  # --- Decline advance ---
  def handle_event({:call, from}, :decline_advance, {:phase, n, :awaiting_confirmation}, data) do
    transition_pe(data, n, :awaiting_input, %{staged_result: nil})
    ws = reload(data)
    broadcast_updated(ws)
    {:next_state, {:phase, n, :awaiting_input}, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- AI response ---
  def handle_event(:cast, {:ai_response, result}, {:phase, n, :processing}, data) do
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

      :processing ->
        {:keep_state, data, [inactivity_timeout()]}
    end
  end

  # --- AI error ---
  def handle_event(:cast, {:ai_error, reason}, {:phase, n, :processing}, data) do
    AI.Conversation.phase_update(data.ws, %{ai_error: reason})
    transition_pe(data, n, :awaiting_input)
    ws = reload(data)
    broadcast_updated(ws)
    {:next_state, {:phase, n, :awaiting_input}, %{data | ws: ws}, [inactivity_timeout()]}
  end

  # --- Retry ---
  def handle_event({:call, from}, :retry, {:phase, n, status}, data)
      when status in [:awaiting_input, :awaiting_confirmation] do
    AI.ClaudeSession.stop_for_workflow_session(data.session_id)
    AI.Conversation.handle_session_strategy(data.ws, n)
    ws = reload(data)
    AI.Conversation.phase_start(ws)

    # Handle PE transition (awaiting_confirmation needs reject first)
    case Executions.get_current_phase_execution(data.session_id) do
      %{status: :awaiting_confirmation} = pe ->
        {:ok, pe} = Executions.reject_completion(pe)
        Executions.process_phase(pe)
      pe when pe != nil ->
        Executions.process_phase(pe)
      nil -> :ok
    end

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
    {:keep_state, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
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
    {:next_state, :done, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
  end

  # --- Mark undone ---
  def handle_event({:call, from}, :mark_undone, :done, data) do
    {:ok, ws} = Workflows.update_workflow_session(data.ws, %{done_at: nil})
    state = reconstruct_state(ws)
    broadcast_updated(ws)
    {:next_state, state, %{data | ws: ws},
     [{:reply, from, {:ok, ws}}, inactivity_timeout()]}
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

  # --- Catch-all for unexpected events (no-op) ---
  def handle_event({:call, from}, _event, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_event}}]}
  end

  def handle_event(:cast, _event, _state, _data) do
    :keep_state_and_data
  end
```

#### Helper functions

```elixir
  defp reconstruct_state(ws) do
    cond do
      Session.done?(ws) -> :done
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
```

### Step 3: Update WorkflowRunnerLive

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Replace all Engine/Executions calls with SessionProcess calls:

1. **Remove:** `Destila.Executions.Engine` references
2. **Add:** `alias Destila.Sessions.SessionProcess`
3. **Replace event handlers** — each becomes a thin wrapper calling the named SessionProcess function and assigning the returned `ws`

Key changes:

```elixir
# send_text: remove guard on phase_status (SessionProcess rejects invalid-state events)
def handle_event("send_text", %{"content" => content}, socket) when content != "" do
  case SessionProcess.send_message(socket.assigns.workflow_session.id, content) do
    {:ok, ws} ->
      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign_ai_state(ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# confirm_advance: remove next_phase > total_phases guard (SessionProcess handles it)
def handle_event("confirm_advance", _params, socket) do
  case SessionProcess.confirm_advance(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign(:current_phase, ws.current_phase)
       |> assign(:question_answers, %{})
       |> assign_ai_state(ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# decline_advance: remove direct Executions.reject_completion call
def handle_event("decline_advance", _params, socket) do
  case SessionProcess.decline_advance(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign_ai_state(ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# mark_done: remove completion message creation (moved to SessionProcess)
def handle_event("mark_done", _params, socket) do
  case SessionProcess.mark_done(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply,
       socket
       |> assign(:workflow_session, ws)
       |> assign_ai_state(ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# mark_undone
def handle_event("mark_undone", _params, socket) do
  case SessionProcess.mark_undone(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply, assign(socket, :workflow_session, ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# retry_phase: remove phase_status guard
def handle_event("retry_phase", _params, socket) do
  case SessionProcess.retry(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply, assign(socket, :workflow_session, ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# cancel_phase: remove direct ClaudeSession.stop and Executions.await_input
def handle_event("cancel_phase", _params, socket) do
  case SessionProcess.cancel(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply, assign(socket, :workflow_session, ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end

# retry_setup
def handle_event("retry_setup", _params, socket) do
  case SessionProcess.retry_setup(socket.assigns.workflow_session.id) do
    {:ok, ws} ->
      {:noreply, assign(socket, :workflow_session, ws)}
    {:error, _} ->
      {:noreply, socket}
  end
end
```

The PubSub `handle_info` handlers stay largely the same — `:workflow_session_updated` already does a full reload. The key difference is it no longer needs to re-derive everything since `assign_ai_state/2` handles it.

### Step 4: Update AiQueryWorker

**File:** `lib/destila/workers/ai_query_worker.ex`

```elixir
# Before:
Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_result: result})
Destila.Executions.Engine.phase_update(ws.id, phase, %{ai_error: reason})

# After:
alias Destila.Sessions.SessionProcess

SessionProcess.cast(ws.id, {:ai_response, result})
SessionProcess.cast(ws.id, {:ai_error, reason})
```

Remove the `phase` parameter from cast — SessionProcess knows the current phase from its state.

### Step 5: Update PrepareWorkflowSession

**File:** `lib/destila/workers/prepare_workflow_session.ex`

```elixir
# Before:
Destila.Executions.Engine.phase_update(ws.id, ws.current_phase, %{worktree_ready: true})

# After:
alias Destila.Sessions.SessionProcess

SessionProcess.cast(workflow_session.id, :worktree_ready)
```

### Step 6: Update Workflows.create_workflow_session

**File:** `lib/destila/workflows.ex`

```elixir
# Before:
Destila.Executions.Engine.start_session(ws)

# After:
alias Destila.Sessions.SessionProcess

{:ok, _pid} = SessionProcess.ensure_started(ws.id)
```

The process reconstructs state on init. For a brand-new session, `reconstruct_state/1` returns `:setup` (no PE exists). We need the init to also kick off the first phase. Add to `init/1`:

```elixir
def init(session_id) do
  ws = Workflows.get_workflow_session!(session_id)
  state = reconstruct_state(ws)
  data = %{session_id: session_id, ws: ws}

  # For new sessions, start the first phase
  if state == :setup do
    start_first_phase(data)
    ws = reload(data)
    state = reconstruct_state(ws)
    data = %{data | ws: ws}
  end

  {:ok, state, data, [inactivity_timeout()]}
end
```

### Step 7: Delete Engine

**File:** `lib/destila/executions/engine.ex` — delete entirely.

`StateMachine` (`lib/destila/executions/state_machine.ex`) remains — called internally by SessionProcess helpers.

### Step 8: Update Engine tests → SessionProcess tests

**File:** `test/destila/executions/engine_test.exs` → `test/destila/sessions/session_process_test.exs`

Replace `Engine.phase_update(...)` calls with `SessionProcess.cast(...)` / `SessionProcess.call(...)`. The test structure stays similar — create session, trigger event, assert PE status and ws state.

Key changes:
- Start `Destila.Sessions.Registry` and `Destila.Sessions.Supervisor` in test setup (or ensure they're in the test supervision tree)
- Replace `Engine.advance_to_next(ws)` with `SessionProcess.confirm_advance(ws.id)` (but need PE in `:awaiting_confirmation` state first)
- Replace `Engine.phase_retry(ws)` with `SessionProcess.retry(ws.id)`
- For cast-based events (`ai_response`, `ai_error`), may need a small synchronization mechanism (e.g., call a sync function after cast) to avoid race conditions in tests

Test synchronization approach: After a `SessionProcess.cast`, call `SessionProcess.send_message` with a known sentinel or use `:sys.get_state` on the process to ensure the cast has been processed:

```elixir
# Ensure cast is processed before asserting
SessionProcess.cast(ws.id, {:ai_response, result})
_ = :sys.get_state(GenServer.whereis({:via, Registry, {Destila.Sessions.Registry, ws.id}}))
# Now assert
```

### Step 9: Run `mix precommit`

Ensure compilation with `--warnings-as-errors`, formatting, and all tests pass.

## Critical considerations

### Race condition during ensure_started

Two processes calling `ensure_started/1` simultaneously for the same session could try to start two processes. `DynamicSupervisor.start_child` will return `{:error, {:already_started, pid}}` for the second call because the Registry name is unique. Handle this in `ensure_started/1`:

```elixir
def ensure_started(session_id) do
  case GenServer.whereis(via(session_id)) do
    nil ->
      case DynamicSupervisor.start_child(Destila.Sessions.Supervisor, {__MODULE__, session_id}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    pid -> {:ok, pid}
  end
end
```

### gen_statem call timeout

Default `:gen_statem.call` timeout is 5 seconds. Since SessionProcess does DB writes in handlers, this should be sufficient. If any handler risks being slow (e.g., `retry` which stops a ClaudeSession), consider increasing the timeout for specific calls or making them async.

### Existing PubSub event compatibility

SessionProcess broadcasts `{:workflow_session_updated, ws}` — the same event the Engine currently triggers via `Workflows.broadcast({:ok, ws}, :workflow_session_updated)`. This means:
- `WorkflowRunnerLive.handle_info({:workflow_session_updated, ...})` continues to work unchanged
- `CraftingBoardLive` continues to work unchanged
- No new PubSub events need to be introduced

### AI.Conversation.phase_update phase parameter

Currently `Engine.phase_update/3` receives a `phase` parameter from workers and passes it to `AI.Conversation.phase_update` via `%{ws | current_phase: phase}`. In SessionProcess, the process always knows the current phase from its state. However, we must ensure the phase in the worker's message matches the current phase — if not, the message is stale and should be ignored.

Add a phase guard to `ai_response` handler:

```elixir
def handle_event(:cast, {:ai_response, result, phase}, {:phase, n, :processing}, data)
    when phase == n do
  # process response
end

def handle_event(:cast, {:ai_response, _result, phase}, {:phase, n, _status}, _data)
    when phase != n do
  # stale response from previous phase — ignore
  :keep_state_and_data
end
```

Update the worker to include the phase in the cast:
```elixir
SessionProcess.cast(ws.id, {:ai_response, result, phase})
SessionProcess.cast(ws.id, {:ai_error, reason, phase})
```

## Files changed

| File | Action | Description |
|------|--------|-------------|
| `lib/destila/application.ex` | Edit | Add Registry + DynamicSupervisor for Sessions |
| `lib/destila/sessions/session_process.ex` | Create | gen_statem process |
| `lib/destila_web/live/workflow_runner_live.ex` | Edit | Replace Engine calls with SessionProcess calls |
| `lib/destila/workers/ai_query_worker.ex` | Edit | Replace Engine.phase_update with SessionProcess.cast |
| `lib/destila/workers/prepare_workflow_session.ex` | Edit | Replace Engine.phase_update with SessionProcess.cast |
| `lib/destila/workflows.ex` | Edit | Replace Engine.start_session with SessionProcess.ensure_started |
| `lib/destila/executions/engine.ex` | Delete | Replaced by SessionProcess |
| `test/destila/executions/engine_test.exs` | Delete | Replaced by session_process_test.exs |
| `test/destila/sessions/session_process_test.exs` | Create | Tests for SessionProcess |

## Done when

- `Engine` is deleted
- `SessionProcess` handles all session state transitions as a `gen_statem`
- `WorkflowRunnerLive` communicates exclusively through `SessionProcess` named client functions for domain events
- Workers cast results to `SessionProcess`
- Sessions start on demand, reconstruct from DB, and terminate after inactivity
- `mix precommit` passes (compilation, formatting, tests)
