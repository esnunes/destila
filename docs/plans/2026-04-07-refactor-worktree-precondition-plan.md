---
title: "refactor: Worktree preparation as a re-runnable precondition"
type: refactor
date: 2026-04-07
---

# refactor: Worktree preparation as a re-runnable precondition

## Overview

Worktree preparation is currently a one-time setup step that writes `repo_sync` and `worktree` metadata entries and signals completion via `Engine.phase_update(setup: :completed)`. This refactoring makes worktree availability a precondition checked before each phase start, eliminating all infrastructure metadata (`repo_sync`, `worktree`) and reading the worktree path exclusively from `ai_sessions.worktree_path`.

After this change, the Engine checks worktree availability before starting any phase. If the worktree exists, the phase starts immediately. If not, `PrepareWorkflowSession` is enqueued and the Engine waits for a `worktree_ready` signal before starting the phase. Subsequent phases find the worktree instantly.

## Current state (post-W1a)

- `Workflows.Setup` has already been deleted (by prior refactoring)
- Title generation is already decoupled — it's fire-and-forget
- `PrepareWorkflowSession` still writes `repo_sync` and `worktree` metadata via `upsert_step/5`
- `PrepareWorkflowSession` signals via `Engine.phase_update(ws.id, phase, %{setup: :completed})`
- Engine has `phase_update/3` clauses for `%{setup: :completed}` and `%{setup: :processing}`
- Worktree path is read from metadata in 4 places: `AI.Conversation` (2x), `ImplementGeneralPromptWorkflow` (1x), `WorkflowRunnerLive` sidebar (1x)
- `ai_sessions.worktree_path` column already exists and is already populated by `AI.Conversation.ensure_ai_session/1` (copied from metadata)
- `AI.SessionConfig.session_opts_for_workflow/3` already reads `worktree_path` from the AI session record (not metadata)
- `Workflows.create_workflow_session/1` calls `prepare_workflow_session(ws)` which enqueues `PrepareWorkflowSession`
- Setup UI (`SetupComponents.setup/1`) renders when `Executions.current_status/1` returns `:setup` (no phase execution exists)

## Key design decisions

### 1. Engine owns the worktree precondition check

The Engine already owns phase transitions (`start_session/1`, `transition_to_phase/2`). Adding the worktree check here keeps the orchestration logic centralized. The check runs before every phase start, making worktree availability a re-runnable precondition.

### 2. No-project sessions skip the check entirely

Sessions without a `project_id` have no worktree. The check returns `:ready` immediately for these sessions — same as today.

### 3. `PrepareWorkflowSession` writes to `ai_sessions.worktree_path`, not metadata

The worker stores the worktree path on the AI session record and signals `%{worktree_ready: true}` to the Engine. No more `repo_sync`/`worktree` metadata entries.

### 4. Setup UI simplification

The setup UI currently shows per-step progress (repo_sync in_progress, worktree in_progress). With metadata entries removed, the UI shows a simple "Preparing workspace..." spinner when no phase execution exists and the session has a project. For no-project sessions, setup is instant — no UI shown.

### 5. `Workflows.create_workflow_session/1` calls `Engine.start_session/1` directly

Instead of enqueuing `PrepareWorkflowSession` on creation, the workflow context calls `Engine.start_session/1`. The Engine's `start_session/1` checks worktree availability and either starts the phase immediately or enqueues `PrepareWorkflowSession`.

## Critical timing analysis

### Phase start flow (after changes)

```
Workflows.create_workflow_session(params)
  → Engine.start_session(ws)
    → Executions.ensure_phase_execution(ws, 1)     # PE created → status is :processing
    → ensure_worktree_ready(ws)
      ├─ No project_id → :ready → AI.Conversation.phase_start(ws) → enqueues AiQueryWorker
      └─ Has project_id:
         ├─ AI session exists with worktree_path AND path exists on disk → :ready → phase_start
         └─ Otherwise → :preparing → enqueues PrepareWorkflowSession
           └─ Worker runs → sync repo → create worktree → store path on AI session
             → Engine.phase_update(ws.id, phase, %{worktree_ready: true})
               → AI.Conversation.phase_start(ws) → enqueues AiQueryWorker
```

**Key insight:** Because `ensure_phase_execution` runs BEFORE the worktree check, `current_status/1` returns `:processing` (not `:setup`) even while the worktree is being prepared. The setup UI (`do_render_phase(:setup)`) will NOT render during worktree preparation — the chat UI renders with a processing spinner instead. This is the correct UX.

### `get_or_create_ai_session` idempotency concern

`PrepareWorkflowSession` calls `AI.get_or_create_ai_session(ws.id, %{worktree_path: path})`. If an AI session already exists (created by a prior phase or retry), `get_or_create_ai_session` returns the existing one WITHOUT updating `worktree_path`. This is correct for the happy path (worktree_path is already set). But if the worktree was deleted and re-created at a different path, the existing AI session's `worktree_path` would be stale.

**Mitigation:** The worktree path is deterministic — `{local_folder}/.claude/worktrees/{ws_id}`. It never changes for a given session. So `get_or_create_ai_session` returning the existing session is always correct. If the worktree was deleted, it's re-created at the same path.

### `handle_session_strategy(:new)` ordering

For phases with `:new` strategy (e.g., "Work" phase 3), the flow is:
1. `transition_to_phase(ws, 3)` → `ensure_worktree_ready(ws)` → gets latest AI session → has `worktree_path` → path exists → `:ready`
2. `AI.Conversation.phase_start(ws)` → `handle_session_strategy(ws, 3)` → `:new` → reads `worktree_path` from current AI session → creates NEW AI session with same `worktree_path`
3. `ensure_ai_session(ws)` → AI session exists (just created in step 2) → no-op

This is correct because `ensure_worktree_ready` checks the worktree BEFORE `handle_session_strategy` creates the new AI session.

### No-project path in `PrepareWorkflowSession` is dead code

After this change, the worker is only enqueued by `ensure_worktree_ready` when `ws.project_id` is truthy. The `else` branch in `perform/1` (no project_id) is dead code. Remove it for clarity.

## Changes

### Step 1: Add `ensure_worktree_ready/1` to Engine

**File:** `lib/destila/executions/engine.ex`

Add a private function that checks worktree availability:

```elixir
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
```

### Step 2: Modify `start_session/1` and `transition_to_phase/2` in Engine

**File:** `lib/destila/executions/engine.ex`

Both functions currently call `AI.Conversation.phase_start(ws)` unconditionally. Modify them to check worktree readiness first:

**`start_session/1`:**
```elixir
def start_session(ws) do
  phase = ws.current_phase
  {:ok, _pe} = Executions.ensure_phase_execution(ws, phase)

  case ensure_worktree_ready(ws) do
    :ready ->
      AI.Conversation.phase_start(ws)

      reloaded = Workflows.get_workflow_session!(ws.id)

      if reloaded.current_phase == phase do
        Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
      end

    :preparing ->
      # Broadcast so the LiveView shows the preparing state
      Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end
end
```

**`transition_to_phase/2`:**
```elixir
defp transition_to_phase(ws, next_phase) do
  {:ok, _pe} = Executions.ensure_phase_execution(ws, next_phase)
  {:ok, ws} = Workflows.update_workflow_session(ws, %{current_phase: next_phase})

  case ensure_worktree_ready(ws) do
    :ready ->
      AI.Conversation.phase_start(ws)

      reloaded = Workflows.get_workflow_session!(ws.id)

      if reloaded.current_phase == next_phase do
        Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
      end

    :preparing ->
      Workflows.broadcast({:ok, ws}, :workflow_session_updated)
  end
end
```

### Step 3: Replace `%{setup: ...}` Engine clauses with `%{worktree_ready: true}`

**File:** `lib/destila/executions/engine.ex`

Remove these two clauses (lines 95-104):
```elixir
# DELETE
def phase_update(workflow_session_id, _phase, %{setup: :completed}) do ...
def phase_update(workflow_session_id, _phase, %{setup: :processing}) do ...
```

Add a new clause for `worktree_ready`:
```elixir
def phase_update(workflow_session_id, _phase, %{worktree_ready: true}) do
  ws = Workflows.get_workflow_session!(workflow_session_id)

  # Worktree is ready — start the current phase
  AI.Conversation.phase_start(ws)

  reloaded = Workflows.get_workflow_session!(ws.id)

  if reloaded.current_phase == ws.current_phase do
    Workflows.broadcast({:ok, reloaded}, :workflow_session_updated)
  end
end
```

### Step 4: Simplify `PrepareWorkflowSession`

**File:** `lib/destila/workers/prepare_workflow_session.ex`

1. **Remove all `upsert_step/5` calls** — no more writing `repo_sync` or `worktree` metadata
2. **Remove the `upsert_step/5` private function** (lines 105-112)
3. **Remove the `notify_engine(ws, :processing)` call** — no intermediate status broadcast needed
4. **After creating the worktree, store the path on the AI session** via `AI.get_or_create_ai_session/2`
5. **Signal `%{worktree_ready: true}`** to the Engine instead of `%{setup: :completed}`

```elixir
defmodule Destila.Workers.PrepareWorkflowSession do
  use Oban.Worker, queue: :setup, max_attempts: 3

  alias Destila.{AI, Git, Workflows}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workflow_session_id" => workflow_session_id}}) do
    workflow_session = Workflows.get_workflow_session!(workflow_session_id)
    project = Destila.Projects.get_project(workflow_session.project_id)

    with :ok <- sync_repo(project),
         {:ok, worktree_path} <- create_worktree(workflow_session, project) do
      AI.get_or_create_ai_session(workflow_session.id, %{worktree_path: worktree_path})

      Destila.Executions.Engine.phase_update(
        workflow_session.id,
        workflow_session.current_phase,
        %{worktree_ready: true}
      )

      :ok
    end
  end

  defp sync_repo(nil), do: :ok

  defp sync_repo(project) do
    cond do
      project.local_folder && project.local_folder != "" ->
        case Git.pull(project.local_folder) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      project.git_repo_url && project.git_repo_url != "" ->
        with {:ok, path} <- Git.effective_local_folder(project),
             {:ok, _} <- Git.pull(path) do
          :ok
        end

      true ->
        :ok
    end
  end

  defp create_worktree(_workflow_session, nil), do: {:ok, nil}

  defp create_worktree(workflow_session, project) do
    case Git.effective_local_folder(project) do
      {:ok, local_folder} ->
        worktree_path = Path.join([local_folder, ".claude", "worktrees", workflow_session.id])

        if Git.worktree_exists?(worktree_path) do
          {:ok, worktree_path}
        else
          case Git.worktree_add(local_folder, worktree_path, workflow_session.id) do
            {:ok, _} -> {:ok, worktree_path}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Key changes from current code:
- **Removed:** `upsert_step/5`, `sanitize_error/1`, and all metadata writes
- **Removed:** `notify_engine/2` helper and the `%{setup: status}` signal pattern
- **Removed:** No-project `else` branch from `perform/1` (dead code — worker is only enqueued by `ensure_worktree_ready` when `project_id` is truthy)
- **Changed:** `sync_repo/1` no longer takes `workflow_session` as first arg since it doesn't write metadata
- **Added:** `AI.get_or_create_ai_session` call to store `worktree_path` on the AI session record
- **Changed:** Signals `%{worktree_ready: true}` to the Engine instead of `%{setup: :completed}`

### Step 5: Update `Workflows.create_workflow_session/1`

**File:** `lib/destila/workflows.ex`

Replace `prepare_workflow_session(ws)` with `Engine.start_session(ws)`:

```elixir
def create_workflow_session(params) do
  # ... existing code ...

  with {:ok, ws} <- insert_workflow_session(session_attrs) do
    # ... metadata and title generation ...

    Destila.Executions.Engine.start_session(ws)

    {:ok, ws}
  end
end
```

Remove the `prepare_workflow_session/1` public function (lines 149-155). The LiveView's `retry_setup` event handler also calls it — this will be updated in Step 8.

### Step 6: Update worktree path reads — `AI.Conversation`

**File:** `lib/destila/ai/conversation.ex`

Two places read worktree path from metadata:

**`handle_session_strategy/2` (lines 121-137):**
```elixir
def handle_session_strategy(ws, phase_number) do
  case get_phase(ws, phase_number) do
    %{session_strategy: :new} ->
      AI.ClaudeSession.stop_for_workflow_session(ws.id)

      # Read worktree_path from the CURRENT AI session before creating a new one
      current_session = AI.get_ai_session_for_workflow(ws.id)
      worktree_path = current_session && current_session.worktree_path

      AI.create_ai_session(%{
        workflow_session_id: ws.id,
        worktree_path: worktree_path
      })

    _ ->
      :ok
  end
end
```

**`ensure_ai_session/1` (lines 145-150):**
```elixir
defp ensure_ai_session(ws) do
  {:ok, session} = AI.get_or_create_ai_session(ws.id, %{})
  session
end
```

The `worktree_path` is no longer passed here because:
- If an AI session already exists, `get_or_create_ai_session` returns it (with its existing `worktree_path`)
- If no AI session exists, `PrepareWorkflowSession` already created one with the `worktree_path` before the Engine starts the phase
- For no-project sessions, `worktree_path` is nil — which is correct

### Step 7: Update worktree path read — `ImplementGeneralPromptWorkflow`

**File:** `lib/destila/workflows/implement_general_prompt_workflow.ex`

In `adjustments_prompt/1` (line 219-248), replace metadata read with AI session read:

```elixir
defp adjustments_prompt(workflow_session) do
  ai_session = Destila.AI.get_ai_session_for_workflow(workflow_session.id)
  worktree_path = (ai_session && ai_session.worktree_path) || "unknown"

  """
  The implementation is complete. Before starting, do two things:
  ...
  """
end
```

### Step 8: Update worktree path read — `WorkflowRunnerLive` sidebar

**File:** `lib/destila_web/live/workflow_runner_live.ex`

Add a `@worktree_path` assign derived from the AI session instead of reading from `@metadata`:

In `assign_metadata/2` (line 778-784), add the worktree_path assign:

```elixir
defp assign_metadata(socket, ws_id) do
  all = Workflows.get_all_metadata(ws_id)

  ai_session = AI.get_ai_session_for_workflow(ws_id)
  worktree_path = ai_session && ai_session.worktree_path

  socket
  |> assign(:metadata, Enum.reduce(all, %{}, fn m, acc -> Map.put(acc, m.key, m.value) end))
  |> assign(:exported_metadata, Enum.filter(all, & &1.exported))
  |> assign(:worktree_path, worktree_path)
end
```

In the template sidebar (lines 607-623), replace `get_in(@metadata, ["worktree", "worktree_path"])` with `@worktree_path`:

```heex
<div :if={@worktree_path} class="p-4 border-b border-base-300/60">
  ...
  <code class="text-xs text-base-content/50 break-all leading-relaxed">
    {@worktree_path}
  </code>
</div>
```

Also update the `retry_setup` event handler (line 185-188). Since `prepare_workflow_session/1` is removed, the retry should call `Engine.start_session/1` which handles the worktree check:

```elixir
def handle_event("retry_setup", _params, socket) do
  ws = socket.assigns.workflow_session
  Destila.Executions.Engine.start_session(ws)
  {:noreply, socket}
end
```

### Step 9: Simplify `SetupComponents`

**File:** `lib/destila_web/components/setup_components.ex`

Replace the per-step progress display with a simple "Preparing workspace..." indicator. The component is rendered when `current_status/1` returns `:setup`, which means a phase execution exists but the worktree isn't ready yet, or no phase execution exists yet.

After the Engine changes, when a session has a project and the worktree is being prepared, a phase execution exists (created by `start_session/1` before the worktree check) but `AI.Conversation.phase_start` hasn't been called yet. The LiveView renders the chat phase (since a PE exists), but the phase is in `:processing` status — the user sees a spinner. This is actually simpler than the current setup UI.

However, there's a nuance: `current_status/1` returns `:setup` when no PE exists. After our changes, `start_session/1` creates the PE before checking the worktree. So `current_status/1` will return `:processing`, not `:setup`. The setup UI won't render at all — the chat UI will show with a "processing" spinner, which is the correct UX (the user sees the phase is starting).

**Simplification:** The `SetupComponents` module can be reduced to handle only the error/retry case. But since we no longer write metadata for failures, the setup retry flow needs rethinking:

- If `PrepareWorkflowSession` fails (Oban retries exhausted), the session is stuck with a PE in `:processing` but no AI conversation
- The user needs a way to retry
- We can keep the `retry_setup` event but it now calls `Engine.start_session/1`

For the initial implementation, simplify `SetupComponents` to show a single "Preparing workspace..." spinner. Remove the `build_steps/2`, `get_step_status/2`, `get_step_error/2` functions. Remove `repo_sync` and `worktree` metadata references. Remove the `metadata` attr since it's no longer needed.

```elixir
defmodule DestilaWeb.SetupComponents do
  @moduledoc """
  Function component for setup status — displays a simple preparing indicator.
  Rendered by WorkflowRunnerLive when no phase execution exists yet (defensive).
  """

  use DestilaWeb, :html

  attr :workflow_session, :map, required: true

  def setup(assigns) do
    ~H"""
    <div class="overflow-y-auto h-full px-6 py-6">
      <div class="max-w-2xl mx-auto">
        <div class="flex items-center gap-3 text-sm pl-2">
          <span class="loading loading-spinner loading-xs shrink-0" />
          <span class="text-base-content/80">Preparing workspace...</span>
        </div>
      </div>
    </div>
    """
  end
end
```

**Also update the caller in `WorkflowRunnerLive`** — remove the `metadata` attr from the `do_render_phase(:setup)` template (line 741-748):

```elixir
defp do_render_phase(%{phase_status: :setup} = assigns) do
  ~H"""
  <DestilaWeb.SetupComponents.setup workflow_session={@workflow_session} />
  """
end
```

**Note on `do_render_phase(:setup)` reachability:** After these changes, `current_status/1` returns `:setup` only when no PE exists. Since `start_session/1` creates the PE synchronously before checking the worktree, the `:setup` status is only briefly visible between session creation and `start_session/1` completing (both happen in the same `create_workflow_session` call). The `do_render_phase(:setup)` clause is effectively unreachable in normal operation but is kept as defensive code.

### Step 10: Update tests

#### `test/destila/executions/engine_test.exs`

**Replace** the entire `"phase_update/3 with setup status"` describe block (lines 177-206) with:

```elixir
describe "phase_update/3 with worktree_ready" do
  test "starts phase when worktree becomes ready" do
    ws = create_session_with_ai(%{})
    {:ok, _pe} = Executions.create_phase_execution(ws, 1)

    Engine.phase_update(ws.id, 1, %{worktree_ready: true})

    updated_ws = Workflows.get_workflow_session!(ws.id)
    assert updated_ws.current_phase == 1
    assert Session.phase_status(updated_ws) != :setup
  end

  test "creates phase execution if not present" do
    ws = create_session_with_ai(%{})
    # No PE created manually — worktree_ready handler should work
    # even if PE was already created by start_session

    Engine.phase_update(ws.id, 1, %{worktree_ready: true})

    updated_ws = Workflows.get_workflow_session!(ws.id)
    assert Session.phase_status(updated_ws) != :setup
  end
end
```

**Remove** these three tests from the old describe block:
- "transitions from setup to phase 1 when setup completes" (line 178)
- "stays in setup when setup is still processing" (line 188)
- "creates phase execution for phase 1 after setup completes" (line 197)

#### `test/destila_web/live/brainstorm_idea_workflow_live_test.exs`

**"shows setup progress steps" test (lines 183-207):**
- Remove the `repo_sync` metadata upsert (lines 198-200)
- The test creates a session with no PE → derived status is `:setup`
- Assert "Preparing workspace..." instead of "Syncing repository..."
- Keep the Phase 1/4 and Task Description assertions

```elixir
@tag feature: @feature, scenario: "Setup displays progress"
test "shows setup progress", %{conn: conn} do
  {:ok, ws} =
    Destila.Workflows.insert_workflow_session(%{
      title: "Test Session",
      workflow_type: :brainstorm_idea,
      current_phase: 1,
      total_phases: 4,
      title_generating: true,
      project_id: create_project().id
    })

  # No PE created — derived status is :setup

  {:ok, _view, html} = live(conn, ~p"/sessions/#{ws.id}")

  assert html =~ "Phase 1/4"
  assert html =~ "Task Description"
  assert html =~ "Preparing workspace..."
end
```

**Setup failure test (lines 420-445):** Remove entirely. Setup failures are no longer tracked in metadata. The retry mechanism works via `Engine.start_session/1` which re-checks worktree availability.

#### `test/destila/workflows_metadata_test.exs`

Tests at lines 37-70 use `repo_sync` as example metadata. These are testing the `upsert_metadata` function itself, not the setup flow. **Change the key from `"repo_sync"` to any other non-infrastructure key** (e.g., `"example_step"` or `"test_data"`). The test logic is unchanged — only the key name changes.

#### Feature file updates for `@tag` annotations

After removing the setup failure test, check that the `@tag feature:` / `scenario:` annotations still match the Gherkin scenarios. The "Retry a failed setup step" scenario will be removed from the feature file (Step 11), so no dangling tag references.

### Step 11: Update Gherkin feature files

**File:** `features/brainstorm_idea_workflow.feature`

**Update** "Setup displays progress" scenario (lines 35-38):
```gherkin
  Scenario: Setup displays progress
    Given I completed the creation form and am on the session detail page
    Then I should see "Preparing workspace..." while the worktree is being created
    And the session should show Phase 1 status
```

**Remove** "Retry a failed setup step" scenario (lines 100-106) entirely. Per-step failure tracking no longer exists. If the Oban worker fails, it retries automatically (max 3 attempts). A more general retry mechanism may be added later.

**File:** `features/implement_general_prompt_workflow.feature`

- Line 87 "And I should see the worktree path": Keep — worktree path still shown in sidebar (from `@worktree_path` assign)

### Step 12: Remove `prepare_workflow_session/1` from `Workflows`

**File:** `lib/destila/workflows.ex`

Delete `prepare_workflow_session/1` (lines 149-155).

### Step 13: Run `mix precommit`

Verify compilation, tests, and formatting pass.

## Execution order

Steps 1-3 (Engine changes) and Step 4 (PrepareWorkflowSession) are the core changes and should be done together since they reference each other's signals.

Steps 5-8 (wiring changes) update callers and can be done after the core.

Steps 9-11 (UI and tests) update the presentation layer.

Step 12 (cleanup) removes the now-unused function.

Step 13 validates everything.

## Done when

- All `repo_sync` and `worktree` metadata entries are gone from production code
- `prepare_workflow_session/1` is removed from `Workflows`
- Worktree path is read from `ai_sessions.worktree_path` everywhere
- The Engine checks worktree availability before each phase start via `ensure_worktree_ready/1`
- `PrepareWorkflowSession` writes worktree path to the AI session record, not metadata
- After the first phase prepares the worktree, subsequent phases find it instantly
- Setup UI shows simple "Preparing workspace..." (no per-step progress)
- `SetupComponents` no longer references `repo_sync` or `worktree` metadata
- Tests pass (`mix precommit`)
