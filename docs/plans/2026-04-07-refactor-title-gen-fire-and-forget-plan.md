---
title: "refactor: Title generation as fire-and-forget"
type: refactor
date: 2026-04-07
---

# refactor: Title generation as fire-and-forget

## Overview

Title generation is purely cosmetic but currently participates in setup coordination — it writes `title_gen` metadata, calls `Engine.phase_update` with `setup_step_completed`, and blocks the first phase until it completes. This refactoring decouples title generation from setup: enqueue it directly on session creation, remove all `title_gen` metadata writes, and remove the Engine callback. The `workflow_sessions.title_generating` boolean is sufficient to track status.

## Prerequisites

None — this is a simplification refactor with no schema changes.

## Key design decision: no-project sessions skip setup entirely

Currently, when `title_generating == true` and `project_id == nil`, the only setup worker is title generation. After decoupling title gen from setup, such sessions have **no setup workers at all**. No worker will call `Engine.phase_update(setup_step_completed)`, so `Engine.start_session/1` would never be called and the session would stay stuck in setup.

**Fix:** `Setup.start/1` returns `:setup_complete` when there are no workers to enqueue (no `project_id`). The caller (`prepare_workflow_session/1`) then calls `Engine.start_session/1` directly.

## Changes

### Step 1: Simplify `TitleGenerationWorker`

**File:** `lib/destila/workers/title_generation_worker.ex`

Remove the two `Workflows.upsert_metadata` calls (lines 16-18 and 31-33) and the `Engine.phase_update` call (lines 35-39). The worker should only generate the title, update the session, and return `:ok`.

```elixir
defmodule Destila.Workers.TitleGenerationWorker do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Destila.Workflows

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "workflow_session_id" => workflow_session_id,
          "idea" => idea
        }
      }) do
    workflow_session = Workflows.get_workflow_session!(workflow_session_id)
    workflow_type = workflow_session.workflow_type

    title =
      case Destila.AI.generate_title(workflow_type, idea) do
        {:ok, title} -> title
        {:error, _reason} -> Destila.Workflows.default_title(workflow_type)
      end

    Workflows.update_workflow_session(workflow_session_id, %{
      title: title,
      title_generating: false
    })

    :ok
  end
end
```

**Removals:**
- `Workflows.upsert_metadata(workflow_session_id, "setup", "title_gen", %{"status" => "in_progress"})` (lines 16-18)
- `Workflows.upsert_metadata(workflow_session_id, "setup", "title_gen", %{"status" => "completed"})` (lines 31-33)
- `Destila.Executions.Engine.phase_update(...)` with `setup_step_completed: "title_gen"` (lines 35-39)

### Step 2: Update `Setup` module

**File:** `lib/destila/workflows/setup.ex`

Two changes:

1. Remove `"title_gen"` from `@setup_keys` (line 6):
   ```elixir
   @setup_keys ~w(repo_sync worktree)
   ```

2. Replace `start/1` entirely (lines 12-30). Remove the title gen enqueue and the `get_metadata` call (only needed for the title gen idea text). Return `:setup_complete` when no workers are needed:

   ```elixir
   def start(ws) do
     if ws.project_id do
       %{"workflow_session_id" => ws.id}
       |> Destila.Workers.PrepareWorkflowSession.new()
       |> Oban.insert()

       :processing
     else
       :setup_complete
     end
   end
   ```

   `update/2` requires no code changes — removing `"title_gen"` from `@setup_keys` is sufficient. It will now only check `repo_sync` and `worktree` metadata status.

### Step 3: Move title gen enqueue to `create_workflow_session/1` and update `prepare_workflow_session/1`

**File:** `lib/destila/workflows.ex`

**3a.** In `create_workflow_session/1`, enqueue the title generation worker directly after session insert, before calling `prepare_workflow_session/1`. The `input_text` is already in scope — no need to read it back from metadata. Change the `with` block (lines 117-127):

```elixir
with {:ok, ws} <- insert_workflow_session(session_attrs) do
  upsert_metadata(ws.id, "creation", dest_key, %{"text" => input_text})

  if selected_session_id do
    upsert_metadata(ws.id, "creation", "source_session", %{"id" => selected_session_id})
  end

  if title_generating do
    %{"workflow_session_id" => ws.id, "idea" => input_text}
    |> Destila.Workers.TitleGenerationWorker.new()
    |> Oban.insert()
  end

  prepare_workflow_session(ws)

  {:ok, ws}
end
```

**3b.** Update `prepare_workflow_session/1` (lines 143-145) to handle the `:setup_complete` return from `Setup.start/1`:

```elixir
def prepare_workflow_session(%Session{} = ws) do
  case Destila.Workflows.Setup.start(ws) do
    :setup_complete ->
      Destila.Executions.Engine.start_session(ws)

    :processing ->
      :ok
  end
end
```

This ensures sessions with no project immediately start phase 1 without going through setup.

### Step 4: Remove title_gen from `SetupComponents`

**File:** `lib/destila_web/components/setup_components.ex`

Remove the title generation step from `build_steps/2` (lines 62-76). The `title_steps` variable and `ws.title_generating` check are no longer needed:

```elixir
defp build_steps(ws, metadata) do
  if ws.project_id do
    [
      %{
        key: "repo_sync",
        label: "Syncing repository...",
        status: get_step_status(metadata, "repo_sync"),
        error: get_step_error(metadata, "repo_sync")
      },
      %{
        key: "worktree",
        label: "Creating worktree...",
        status: get_step_status(metadata, "worktree"),
        error: get_step_error(metadata, "worktree")
      }
    ]
  else
    []
  end
end
```

### Step 5: Update feature files

**File:** `features/implement_general_prompt_workflow.feature`

Remove the two title-generation-in-setup scenarios (lines 53-60):

```gherkin
# REMOVE these two scenarios:
Scenario: Setup skips title generation for source session
  Given I started an implementation from an existing session
  Then the setup should not show "Generating title..."
  And the session title should match the source session title

Scenario: Setup generates title for manual prompt
  Given I started an implementation with a manual prompt
  Then the setup should show "Generating title..."
```

Title generation still happens — it's just no longer visible in setup. The session title still updates once the worker completes.

**File:** `features/brainstorm_idea_workflow.feature`

No changes needed. The "Setup displays progress" scenario (line 35) refers to setup progress generically and still applies (repo sync/worktree steps remain).

### Step 6: Update tests

#### Engine tests (`test/destila/executions/engine_test.exs`)

In `describe "phase_update/3 with setup_step_completed"` (lines 177-218), remove the `title_gen` metadata upsert from all three tests. They should only use `repo_sync` and `worktree` metadata:

- **Line 181**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})`
- **Line 196**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})`
- **Line 208**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})`

#### LiveView tests — implement workflow (`test/destila_web/live/implement_general_prompt_workflow_live_test.exs`)

Remove the entire `describe "Setup"` block (lines 185-211), which contains two tests:
- "skips title generation when source session selected" (lines 188-193) — tests `refute html =~ "Generating title..."`, no longer applicable since title gen is never in setup
- "shows title generation for manual prompt" (lines 196-210) — tests `assert html =~ "Generating title..."`, no longer applicable

Both tests have `@tag` linking to the feature scenarios being removed in Step 5.

#### LiveView tests — brainstorm workflow (`test/destila_web/live/brainstorm_idea_workflow_live_test.exs`)

- **Lines 185-212** ("shows setup progress steps"): Remove the `title_gen` metadata upsert (lines 198-200) and the `assert html =~ "Generating title..."` assertion (line 210). Keep the test — it still validates that setup shows repo_sync/worktree steps.
- **Lines 430-445** (setup failure test): Remove the `title_gen` metadata upsert (lines 438-440). The test still validates that `repo_sync` failure is shown.
- **Line 740** (exported metadata empty state test): Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "done"})` — this was setting up non-exported metadata unrelated to the test's purpose.

#### Metadata tests (`test/destila/workflows_metadata_test.exs`)

No changes needed. These tests use `"title_gen"` as an arbitrary metadata key name to test generic `upsert_metadata` CRUD mechanics. None depend on `title_gen` being in `@setup_keys`.

### Step 7: Run `mix precommit`

Run `mix precommit` and fix any issues.

## Summary of files changed

| File | Change |
|------|--------|
| `lib/destila/workers/title_generation_worker.ex` | Remove metadata writes and Engine callback |
| `lib/destila/workflows.ex` | Enqueue title gen in `create_workflow_session/1`; update `prepare_workflow_session/1` to handle `:setup_complete` |
| `lib/destila/workflows/setup.ex` | Remove `"title_gen"` from `@setup_keys`; remove title gen enqueue from `start/1`; return `:setup_complete` when no workers needed |
| `lib/destila_web/components/setup_components.ex` | Remove title_gen step from `build_steps/2` |
| `features/implement_general_prompt_workflow.feature` | Remove two title-gen-in-setup scenarios |
| `test/destila/executions/engine_test.exs` | Remove `title_gen` metadata from setup tests |
| `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` | Remove `title_gen` metadata and assertions |
| `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` | Remove entire `describe "Setup"` block |

## Risks and edge cases

1. **No-project sessions**: Addressed by having `Setup.start/1` return `:setup_complete` and `prepare_workflow_session/1` call `Engine.start_session/1` directly.

2. **Title gen failure**: If the worker fails after max retries, `title_generating` stays `true` on the session. This is existing behavior — the boolean was already the source of truth. No change needed.

3. **Race condition**: Title gen worker could complete and call `update_workflow_session` while the session is still being set up. This is safe — it only writes `title` and `title_generating: false`, which don't conflict with setup/phase execution logic.
