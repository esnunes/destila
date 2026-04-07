---
title: "refactor: Eliminate phase_status from workflow_sessions"
type: refactor
date: 2026-04-06
---

# refactor: Eliminate phase_status from workflow_sessions

## Overview

The `workflow_sessions.phase_status` column duplicates state that already lives in `phase_executions.status`. The Engine currently writes to both in 6+ places, creating a desynchronization risk. This plan removes `phase_status` from the schema and database, making `phase_executions` the single source of truth.

After this change, all status reads go through `Session.phase_status/1`, which derives the value from the latest `PhaseExecution` record via `Executions.current_status/1`.

## Prerequisites

- **F1** (Ecto.Enum conversion for PhaseExecution.status) — merged as `78d24a6`
- **F2** (Explicit phase execution state machine) — merged as `a594cd1`

## Mapping: PhaseExecution.status → derived phase_status

| PhaseExecution.status | Derived phase_status |
|----------------------|---------------------|
| (no record exists)   | `:setup`            |
| `:pending`           | `:processing`       |
| `:processing`        | `:processing`       |
| `:awaiting_input`    | `:awaiting_input`   |
| `:awaiting_confirmation` | `:advance_suggested` |
| `:completed`         | `nil`               |
| `:skipped`           | `nil`               |
| `:failed`            | `:processing`       |
| (session done?)      | `nil`               |

## Changes

### Step 1: Add `Executions.current_status/1`

**File:** `lib/destila/executions.ex`

Add a new public function that derives the phase status from the latest phase execution:

```elixir
def current_status(workflow_session_id) do
  case get_current_phase_execution(workflow_session_id) do
    nil -> :setup
    %{status: :processing} -> :processing
    %{status: :pending} -> :processing
    %{status: :awaiting_input} -> :awaiting_input
    %{status: :awaiting_confirmation} -> :advance_suggested
    %{status: :failed} -> :processing
    %{status: s} when s in [:completed, :skipped] -> nil
  end
end
```

**Why `nil` for completed/skipped:** A completed phase execution with no next phase means the workflow is done (handled by `Session.done?/1`). If the workflow isn't done, the Engine is about to create the next phase execution — the transient `nil` is fine because it falls through to the default `:processing` bucket in `classify/1`.

### Step 2: Add `Session.phase_status/1` virtual accessor

**File:** `lib/destila/workflows/session.ex`

1. Remove the `field(:phase_status, ...)` declaration (lines 14–16)
2. Remove `:phase_status` from the changeset cast list (line 44)
3. Add:

```elixir
def phase_status(%__MODULE__{} = ws) do
  if done?(ws), do: nil, else: Destila.Executions.current_status(ws.id)
end
```

**Important:** This function hits the database every call. Callers that need the status multiple times in one request should bind it to a variable. In practice, LiveView mounts/events call it once per render cycle, which is acceptable.

### Step 3: Remove Engine writes to `phase_status`

**File:** `lib/destila/executions/engine.ex`

**Decision: Broadcast approach.** Add explicit `Workflows.broadcast({:ok, ws}, :workflow_session_updated)` in each Engine function where the removed `update_workflow_session` call was the only source of PubSub broadcast. This is preferred over broadcasting from `StateMachine.transition/3` because the StateMachine is a low-level persistence concern — it shouldn't know about PubSub. The Engine is the orchestrator and the right place for broadcast decisions.

Add `alias Destila.Workflows.Session` to the alias line at the top.

**Updated docstring (lines 2–16):** Remove the sentence about writing to `workflow_sessions.phase_status`.

**`phase_retry/1` guard (line 84):** Change `if ws.phase_status == :processing` to `if Session.phase_status(ws) == :processing`.

Below is the complete resulting code for every modified function:

#### `start_session/1` — remove `update_workflow_session`, add broadcast

```elixir
def start_session(ws) do
  phase = ws.current_phase
  {:ok, pe} = Executions.ensure_phase_execution(ws, phase)
  AI.Conversation.phase_start(ws)

  # Reload to check if an inline worker already advanced past this phase.
  reloaded = Workflows.get_workflow_session!(ws.id)

  if reloaded.current_phase == phase do
    Executions.start_phase(pe)
    Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
  end
end
```

#### `phase_update/3` (setup branch) — remove both `update_workflow_session` calls

```elixir
def phase_update(workflow_session_id, _phase, %{setup_step_completed: _} = params) do
  ws = Workflows.get_workflow_session!(workflow_session_id)

  case Destila.Workflows.Setup.update(ws, params) do
    :setup_complete ->
      start_session(ws)

    :processing ->
      # Setup status is derived from no PE existing — no write needed.
      # Broadcast so the LiveView refreshes setup step progress.
      Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end
end
```

**Note:** Previously the `:setup_complete` branch did `update_workflow_session(ws, %{phase_status: nil})` then `start_session(ws)`. The `phase_status: nil` write is unnecessary — `start_session` creates a PE and transitions it to `:processing`, so `current_status/1` will return `:processing`. The `start_session` function now handles its own broadcast (see above).

#### `phase_update/3` (main branch) — remove `update_workflow_session` on `:processing`

```elixir
def phase_update(workflow_session_id, phase, params) do
  ws = Workflows.get_workflow_session!(workflow_session_id)

  case AI.Conversation.phase_update(%{ws | current_phase: phase}, params) do
    :processing ->
      if pe = Executions.get_current_phase_execution(ws.id) do
        Executions.process_phase(pe)
      end

      Workflows.broadcast({:ok, ws}, :workflow_session_updated)

    :awaiting_input ->
      handle_awaiting_input(ws)

    :phase_complete ->
      advance_to_next(ws)

    :suggest_phase_complete ->
      handle_suggest_advance(ws)
  end
end
```

#### `complete_workflow/1` — keep `update_workflow_session`, remove `phase_status: nil`

```elixir
defp complete_workflow(ws) do
  Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})
end
```

This still broadcasts via `update_workflow_session` → `broadcast(:workflow_session_updated)`.

#### `handle_suggest_advance/1` — remove `update_workflow_session`, add broadcast

```elixir
defp handle_suggest_advance(ws) do
  if pe = Executions.get_current_phase_execution(ws.id) do
    Executions.await_confirmation(pe, nil)
  end

  Workflows.broadcast({:ok, ws}, :workflow_session_updated)
end
```

#### `handle_awaiting_input/1` — remove `update_workflow_session`, add broadcast

```elixir
defp handle_awaiting_input(ws) do
  if pe = Executions.get_current_phase_execution(ws.id) do
    Executions.await_input(pe)
  end

  Workflows.broadcast({:ok, ws}, :workflow_session_updated)
end
```

#### `transition_to_phase/2` — remove trailing `update_workflow_session`, add broadcast

```elixir
defp transition_to_phase(ws, next_phase) do
  {:ok, pe} = Executions.ensure_phase_execution(ws, next_phase)
  {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next_phase})

  AI.Conversation.phase_start(ws)

  reloaded = Workflows.get_workflow_session!(ws.id)

  if reloaded.current_phase == next_phase do
    Executions.start_phase(pe)
    # The update_workflow_session above already broadcast for current_phase.
    # This additional broadcast ensures the UI picks up the PE status change.
    Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
  end
end
```

#### `handle_retry/1` — remove `update_workflow_session`, add broadcast

```elixir
defp handle_retry(ws) do
  phase = ws.current_phase

  AI.ClaudeSession.stop_for_workflow_session(ws.id)
  AI.Conversation.handle_session_strategy(ws, phase)

  ws = Workflows.get_workflow_session!(ws.id)
  AI.Conversation.phase_start(ws)

  case Executions.get_current_phase_execution(ws.id) do
    nil ->
      :ok

    pe when pe.status == :awaiting_confirmation ->
      {:ok, pe} = Executions.reject_completion(pe)
      Executions.process_phase(pe)

    pe ->
      Executions.process_phase(pe)
  end

  Workflows.broadcast({:ok, ws}, :workflow_session_updated)
end
```

### Step 4: Update `Workflows.classify/1`

**File:** `lib/destila/workflows.ex`

**Lines 159–165:** Replace `ws.phase_status` with `Session.phase_status(ws)`:

```elixir
def classify(%Session{} = ws) do
  cond do
    Session.done?(ws) -> :done
    Session.phase_status(ws) in [:awaiting_input, :advance_suggested] -> :waiting_for_user
    true -> :processing
  end
end
```

### Step 5: Update `Workflows.create_workflow_session/1`

**File:** `lib/destila/workflows.ex`, line 113

Remove `phase_status: :setup` from `session_attrs`. The initial status is derived from having no phase execution record (returns `:setup`).

### Step 6: Update `Workflows.unarchive_workflow_session/1`

**File:** `lib/destila/workflows.ex`, lines 212–222

Remove the `if ws.phase_status == :processing` conditional. After unarchiving, the status is derived from `phase_executions`. If the PE was `:processing` when archived, the `ClaudeSession` was stopped by `archive_workflow_session/1`, but the PE status remains `:processing`. We need to transition the PE to `:awaiting_input` when unarchiving a session whose PE is `:processing`:

```elixir
def unarchive_workflow_session(%Session{} = ws) do
  # If PE was processing when archived, transition to awaiting_input
  # since the ClaudeSession was killed during archival
  case Destila.Executions.get_current_phase_execution(ws.id) do
    %{status: :processing} = pe -> Destila.Executions.await_input(pe)
    _ -> :ok
  end

  ws
  |> Session.changeset(%{archived_at: nil})
  |> Repo.update()
  |> broadcast(:workflow_session_updated)
end
```

### Step 7: Update `WorkflowRunnerLive`

**File:** `lib/destila_web/live/workflow_runner_live.ex`

`alias Destila.Executions` is not currently imported — add it. `Session` is already aliased.

Every `ws.phase_status` reference must be replaced with `Session.phase_status(ws)`. Since this is a function call (not a field access), compute it once per event handler and bind to a variable where used multiple times.

Below are the complete rewritten functions for every affected handler:

#### `decline_advance` (line 137) — remove `update_workflow_session`, reload instead

The `reject_completion/1` call on line 141 already transitions the PE from `:awaiting_confirmation` to `:awaiting_input`. No need to write `phase_status` — just reload ws.

```elixir
def handle_event("decline_advance", _params, socket) do
  ws = socket.assigns.workflow_session

  case Destila.Executions.get_current_phase_execution(ws.id) do
    %{status: :awaiting_confirmation} = pe -> Destila.Executions.reject_completion(pe)
    _ -> :ok
  end

  ws = Workflows.get_workflow_session!(ws.id)
  {:noreply, assign(socket, :workflow_session, ws)}
end
```

#### `mark_done` (line 149) — remove `phase_status: nil`

```elixir
{:ok, ws} =
  Workflows.update_workflow_session(ws, %{done_at: DateTime.utc_now()})
```

#### `mark_undone` (line 173) — remove `phase_status: nil`

```elixir
{:ok, ws} =
  Workflows.update_workflow_session(ws, %{done_at: nil})
```

#### `send_text` (line 192) — replace field access with function call

```elixir
if Session.phase_status(ws) != :processing do
```

#### `retry_phase` (line 286) — replace field access

```elixir
if Session.phase_status(ws) != :processing do
```

#### `cancel_phase` (line 298) — replace field access and remove `update_workflow_session`

The PE is already transitioned by `Executions.await_input(pe)` on line 305. Remove the `update_workflow_session` call and reload instead.

```elixir
def handle_event("cancel_phase", _params, socket) do
  ws = socket.assigns.workflow_session

  if Session.phase_status(ws) == :processing do
    AI.ClaudeSession.stop_for_workflow_session(ws.id)

    if pe = Destila.Executions.get_current_phase_execution(ws.id) do
      Destila.Executions.await_input(pe)
    end

    ws = Workflows.get_workflow_session!(ws.id)
    {:noreply, assign(socket, :workflow_session, ws)}
  else
    {:noreply, socket}
  end
end
```

#### `handle_info({:workflow_session_updated, ...})` (line 316) — replace field access

```elixir
|> assign(
  :streaming_chunks,
  if(Session.phase_status(ws) == :processing,
    do: socket.assigns[:streaming_chunks],
    else: nil
  )
)
```

#### `compute_current_step/2` (line 394) — replace field accesses

```elixir
defp compute_current_step(ws, messages) do
  phase_status = Session.phase_status(ws)

  cond do
    Session.done?(ws) ->
      %{input_type: nil, options: nil, questions: [], question_title: nil, completed: true}

    phase_status == :advance_suggested ->
      %{input_type: nil, options: nil, questions: [], question_title: nil, completed: false}

    phase_status == :processing ->
      %{input_type: :text, options: nil, questions: [], question_title: nil, completed: false}

    true ->
      # ... existing last_system message parsing logic unchanged ...
  end
end
```

#### `render_phase/1` (line 733) — replace pattern match with derived assign

**Decision:** Use the derived-assign approach. This preserves multi-clause function dispatch (idiomatic Elixir) and avoids nested `if/else` in a function that returns HEEx.

```elixir
defp render_phase(assigns) do
  phase_status = Session.phase_status(assigns.workflow_session)
  assigns = assign(assigns, :phase_status, phase_status)
  do_render_phase(assigns)
end

defp do_render_phase(%{phase_status: :setup} = assigns) do
  ~H"""
  <DestilaWeb.SetupComponents.setup
    workflow_session={@workflow_session}
    metadata={@metadata}
  />
  """
end

defp do_render_phase(%{phases: phases, current_phase: current_phase} = assigns) do
  case Enum.at(phases, current_phase - 1) do
    %Destila.Workflows.Phase{} = phase ->
      assigns = assign(assigns, :phase_config, phase)

      ~H"""
      <.chat_phase
        workflow_session={@workflow_session}
        messages={@messages}
        phase_number={@current_phase}
        phase_config={@phase_config}
        streaming_chunks={@streaming_chunks}
        question_answers={@question_answers}
        metadata={@metadata}
        current_step={@current_step}
        phase_status={@phase_status}
      />
      """

    nil ->
      ~H"""
      <div class="text-base-content/50 text-center py-12">
        Phase {@current_phase}
      </div>
      """
  end
end
```

**Key:** The `phase_status` assign computed in `render_phase/1` is passed down to `<.chat_phase>` — this is the single DB query point. All downstream components receive it as an attr (see Step 8).

### Step 8: Update `ChatComponents`

**File:** `lib/destila_web/components/chat_components.ex`

The chat components receive `@workflow_session` as an assign and access `@workflow_session.phase_status` directly. Since `phase_status` is no longer a field, these must change.

**Approach:** Receive `phase_status` as an attr from the parent. This is the single DB query point established in Step 7's `render_phase/1`.

#### Changes to `chat_phase/1`

1. Add `attr :phase_status, :atom, default: nil` to the attr declarations (after line 36)
2. Replace all `@workflow_session.phase_status` references in the `chat_phase` template with `@phase_status`

Affected lines within `chat_phase/1` template:
- Line 71: `@workflow_session.phase_status == :processing` → `@phase_status == :processing`
- Line 124: `@workflow_session.phase_status == :processing` → `@phase_status == :processing`
- Line 132: `@workflow_session.phase_status == :awaiting_input` → `@phase_status == :awaiting_input`
- Line 147: `@workflow_session.phase_status not in [:advance_suggested]` → `@phase_status not in [:advance_suggested]`
- Line 152: `@workflow_session.phase_status == :processing` → `@phase_status == :processing`
- Line 153: `@workflow_session.phase_status == :processing` → `@phase_status == :processing`
- Line 154: `@workflow_session.phase_status == :awaiting_input` → `@phase_status == :awaiting_input`

#### Changes to `chat_message/1` and `render_chat_message/1`

Line 272 (`render_chat_message` for `:phase_advance`) accesses `@workflow_session.phase_status == :advance_suggested`. This is inside `render_chat_message/1`, which is called from `chat_message/1`.

The `chat_message` component receives `workflow_session` as an attr (line 241). To avoid adding a DB query per message, pass `phase_status` through:

1. Add `attr :phase_status, :atom, default: nil` to `chat_message/1` (after line 241)
2. In `chat_phase/1` template, pass it: `<.chat_message :for={msg <- group} message={msg} workflow_session={@workflow_session} phase_status={@phase_status} />`
3. In `render_chat_message` for `:phase_advance` (line 272): `@workflow_session.phase_status == :advance_suggested` → `@phase_status == :advance_suggested`

### Step 9: Update `BoardComponents`

**File:** `lib/destila_web/components/board_components.ex`

The board components also access `phase_status` as a struct field via pattern matching. Since `phase_status` is removed from the schema, the struct won't have this key.

**Approach:** Compute phase status externally and pass it or use `Session.phase_status/1`.

**`should_be_alive?/1` (line 61):** Change from pattern match to function call:

```elixir
def should_be_alive?(session) do
  Session.phase_status(session) == :processing
end
```

**`status_dot_style/1` (lines 152–163):** Change from pattern matching to conditional:

```elixir
defp status_dot_style(card) do
  phase_status = Session.phase_status(card)

  cond do
    Session.done?(card) -> {"bg-success", "Done"}
    phase_status in [:awaiting_input, :advance_suggested] -> {"bg-warning", "Waiting for you"}
    phase_status == :processing -> {"bg-info animate-pulse", "AI is responding"}
    true -> {"bg-primary/40", "In progress"}
  end
end
```

**Performance note:** `Session.phase_status/1` queries the DB. On the crafting board, `status_dot_style/1` and `should_be_alive?/1` are called per card, giving 2 queries per session. For ~20 sessions, that's ~40 queries per render. To avoid this, compute phase_status once per card in `crafting_card/1` and pass it down:

```elixir
def crafting_card(assigns) do
  phase_status = Session.phase_status(assigns.card)
  assigns = assign(assigns, :card_phase_status, phase_status)
  # ... use @card_phase_status in template and pass to status_dot/aliveness_dot
end
```

Then update `should_be_alive?/1` and `status_dot_style/1` to accept the pre-computed value:

```elixir
def should_be_alive?(phase_status), do: phase_status == :processing

defp status_dot_style(card, phase_status) do
  cond do
    Session.done?(card) -> {"bg-success", "Done"}
    phase_status in [:awaiting_input, :advance_suggested] -> {"bg-warning", "Waiting for you"}
    phase_status == :processing -> {"bg-info animate-pulse", "AI is responding"}
    true -> {"bg-primary/40", "In progress"}
  end
end
```

This reduces to 1 query per card (~20 queries total). Still O(N) but acceptable at current scale. Future optimization: join-load the latest PE per session in `list_workflow_sessions/0`.

**Note:** `should_be_alive?/1` is also called from `WorkflowRunnerLive` at line 447 via `<.aliveness_dot>`. In `WorkflowRunnerLive`, the `phase_status` is already computed once per render cycle, so pass it through: `<.aliveness_dot session={@workflow_session} alive?={@alive_session} phase_status={@phase_status} />`.

### Step 10: Update `SetupComponents`

**File:** `lib/destila_web/components/setup_components.ex`

Line 5 (docstring) references `phase_status` being `:setup`. Update to reflect that setup is now derived from the absence of phase executions.

### Step 11: Update `CraftingBoardLive`

**File:** `lib/destila_web/live/crafting_board_live.ex`

Line 139 calls `Workflows.classify/1` which is updated in Step 4. No direct `phase_status` references — no changes needed beyond what `classify/1` handles.

### Step 12: Create migration to remove `phase_status` column

**File:** `priv/repo/migrations/TIMESTAMP_remove_phase_status_from_workflow_sessions.exs`

```elixir
defmodule Destila.Repo.Migrations.RemovePhaseStatusFromWorkflowSessions do
  use Ecto.Migration

  def change do
    alter table(:workflow_sessions) do
      remove :phase_status, :string
    end
  end
end
```

### Step 13: Update tests

There are 7 test files with ~70 `phase_status` references. Changes fall into 3 categories:

#### Category A: Fixture helpers — remove `phase_status` from attrs, add PE creation

**Pattern:** Every `create_session/create_prompt/create_session_in_phase` helper that sets `phase_status` must instead create a phase execution with the corresponding PE status.

**Mapping for fixtures:**
| Old fixture `phase_status` | New PE setup |
|---------------------------|-------------|
| `:setup` | No PE needed — `current_status/1` returns `:setup` when no PE exists |
| `:awaiting_input` | `Executions.create_phase_execution(ws, phase, %{status: :awaiting_input})` |
| `:processing` | `Executions.create_phase_execution(ws, phase, %{status: :processing})` |
| `:advance_suggested` | `Executions.create_phase_execution(ws, phase, %{status: :awaiting_confirmation})` |
| `nil` | `Executions.create_phase_execution(ws, phase, %{status: :completed})` |

**Example — `workflows_classify_test.exs`:**

Before:
```elixir
defp create_session(attrs) do
  default = %{
    title: "Test Session",
    workflow_type: :brainstorm_idea,
    current_phase: 1,
    total_phases: 4,
    phase_status: :awaiting_input
  }

  {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))
  ws
end

test "returns :waiting_for_user when phase_status is awaiting_input" do
  ws = create_session(%{phase_status: :awaiting_input})
  assert Workflows.classify(ws) == :waiting_for_user
end
```

After:
```elixir
defp create_session(attrs) do
  {pe_status, attrs} = Map.pop(attrs, :pe_status)

  default = %{
    title: "Test Session",
    workflow_type: :brainstorm_idea,
    current_phase: 1,
    total_phases: 4
  }

  {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))

  if pe_status do
    {:ok, _pe} = Destila.Executions.create_phase_execution(ws, ws.current_phase, %{status: pe_status})
  end

  ws
end

test "returns :waiting_for_user when PE is awaiting_input" do
  ws = create_session(%{pe_status: :awaiting_input})
  assert Workflows.classify(ws) == :waiting_for_user
end

test "returns :processing for sessions with no PE (setup)" do
  ws = create_session(%{})
  assert Workflows.classify(ws) == :processing
end
```

**Example — `engine_test.exs`:**

Before:
```elixir
defp create_session(attrs) do
  default = %{..., phase_status: :awaiting_input}
  {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))
  ws
end

test "retries from awaiting_confirmation state" do
  ws = create_session_with_ai(%{phase_status: :advance_suggested})
  {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_confirmation})
  ...
  assert updated_ws.phase_status == :processing
end
```

After:
```elixir
defp create_session(attrs) do
  default = %{...,}  # no phase_status
  {:ok, ws} = Workflows.insert_workflow_session(Map.merge(default, attrs))
  ws
end

test "retries from awaiting_confirmation state" do
  ws = create_session_with_ai(%{})
  {:ok, pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_confirmation})
  # PE is already in :awaiting_confirmation → Session.phase_status returns :advance_suggested
  ...
  updated_pe = Executions.get_phase_execution!(pe.id)
  assert updated_pe.status == :processing
end
```

**Key insight for engine tests:** Prefer asserting on PE status directly (`updated_pe.status == :processing`) rather than `Session.phase_status(updated_ws) == :processing`. This tests the actual state change rather than the derived view.

#### Category B: Assertions — replace `ws.phase_status` with PE status assertions

**Pattern:** `assert updated_ws.phase_status == :X` → `assert updated_pe.status == :Y` or `assert Session.phase_status(updated_ws) == :X`

Affected files:
- `engine_test.exs`: 9 assertion sites — prefer PE status assertions
- `brainstorm_idea_workflow_live_test.exs`: assertions after `mark_done`/advance — check PE status
- `implement_general_prompt_workflow_live_test.exs`: similar pattern

#### Category C: LiveView test fixtures — `create_session_in_phase` helper

**File:** `brainstorm_idea_workflow_live_test.exs` (lines 39–81)

The `create_session_in_phase` helper accepts `phase_status:` as an option. Rewrite to accept `pe_status:` instead and create the corresponding PE:

Before:
```elixir
defp create_session_in_phase(phase, opts \\ []) do
  phase_status = Keyword.get(opts, :phase_status, :awaiting_input)
  ...
  {:ok, ws} = Workflows.insert_workflow_session(%{..., phase_status: phase_status})
  ...
end
```

After:
```elixir
defp create_session_in_phase(phase, opts \\ []) do
  pe_status = Keyword.get(opts, :pe_status, :awaiting_input)
  ...
  {:ok, ws} = Workflows.insert_workflow_session(%{..., current_phase: phase, ...})
  {:ok, _pe} = Executions.create_phase_execution(ws, phase, %{status: pe_status})
  ...
end
```

Call-site updates throughout the test file:
- `create_session_in_phase(1, phase_status: :advance_suggested)` → `create_session_in_phase(1, pe_status: :awaiting_confirmation)`
- `create_session_in_phase(1, phase_status: :processing)` → `create_session_in_phase(1, pe_status: :processing)`
- `create_session_in_phase(1, phase_status: :awaiting_input)` → `create_session_in_phase(1, pe_status: :awaiting_input)` (or just `create_session_in_phase(1)` since it's the default)
- Sessions with `phase_status: :setup` → don't create a PE at all

**File:** `crafting_board_live_test.exs`

The `create_prompt` helper sets `phase_status` directly. Same pattern — extract PE creation:

Before:
```elixir
create_prompt(%{title: "Waiting Prompt", phase_status: :awaiting_input, ...})
```

After:
```elixir
ws = create_prompt(%{title: "Waiting Prompt", ...})
Executions.create_phase_execution(ws, ws.current_phase, %{status: :awaiting_input})
```

Or modify `create_prompt` to accept `pe_status:` and create the PE internally.

**File:** `session_archiving_live_test.exs`

Line 31: Remove `phase_status: :awaiting_input` from default attrs, create PE in setup.

**File:** `generated_prompt_viewing_live_test.exs`

Remove `phase_status` from fixture, create PE as needed.

### Step 14: Update feature files

**File:** `features/crafting_board.feature`, lines 16–18

Update the Gherkin scenarios to reflect that classification is now derived from phase execution status, not `phase_status` field. The scenarios already use outdated enum values ("conversing", "generating") — update them to reflect the current architecture:

```gherkin
And sessions with no phase execution should appear under "Setup"
And sessions with awaiting_input or awaiting_confirmation phase execution should appear under "Waiting for You"
And sessions with processing phase execution should appear under "Processing"
```

### Step 15: Run `mix precommit`

Run `mix precommit` to verify compilation, tests, and formatting all pass.

## Risk assessment

| Risk | Mitigation |
|------|-----------|
| N+1 queries on crafting board | Acceptable at current scale (~20 sessions). Can optimize with preloaded PE join later. |
| Missing broadcasts after removing `update_workflow_session` calls | Explicitly broadcast from Engine after PE writes (Step 3). |
| Race condition: PE not yet created when status queried | `current_status/1` returns `:setup` for nil PE, which is the correct initial state. |
| Test fixtures rely on `phase_status` | All test helpers updated to create PEs instead (Step 13). |

## Done when

- The `phase_status` column is removed from the database
- The `phase_status` field is removed from the `Session` schema
- All status reads go through `Session.phase_status/1` → `Executions.current_status/1`
- The Engine only writes to `phase_executions` for status changes (no more `%{phase_status: ...}` in `update_workflow_session` calls)
- PubSub broadcasts still fire correctly after Engine status transitions
- `mix precommit` passes
