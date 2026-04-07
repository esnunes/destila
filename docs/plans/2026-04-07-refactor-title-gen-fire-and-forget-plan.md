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
- `Workflows.upsert_metadata(workflow_session_id, "setup", "title_gen", %{"status" => "in_progress"})` (line 16-18)
- `Workflows.upsert_metadata(workflow_session_id, "setup", "title_gen", %{"status" => "completed"})` (line 31-33)
- `Destila.Executions.Engine.phase_update(...)` with `setup_step_completed: "title_gen"` (lines 35-39)

### Step 2: Move title generation enqueue to `create_workflow_session/1`

**File:** `lib/destila/workflows.ex`

In `create_workflow_session/1` (line 87-128), enqueue the title generation worker directly after session insert, before calling `prepare_workflow_session/1`. The `input_text` is already available in the function params — no need to read it back from metadata like `Setup.start/1` does.

Change the `with` block (lines 117-127) to:

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

### Step 3: Remove title generation from `Setup.start/1`

**File:** `lib/destila/workflows/setup.ex`

1. Remove `"title_gen"` from `@setup_keys` (line 6):
   ```elixir
   # Before
   @setup_keys ~w(title_gen repo_sync worktree)
   # After
   @setup_keys ~w(repo_sync worktree)
   ```

2. Remove the title generation enqueue block from `start/1` (lines 13-21). The function becomes:
   ```elixir
   def start(ws) do
     if ws.project_id do
       %{"workflow_session_id" => ws.id}
       |> Destila.Workers.PrepareWorkflowSession.new()
       |> Oban.insert()
     end

     :processing
   end
   ```

   Note: The metadata fetch (`get_metadata(ws.id)`) on line 13 was only used to derive the `idea` for title generation. With that removed, the metadata fetch is no longer needed in `start/1`.

### Step 4: Remove title_gen from `SetupComponents`

**File:** `lib/destila_web/components/setup_components.ex`

Remove the title generation step from `build_steps/2` (lines 63-76). The function becomes:

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

This means sessions without a project will have no setup steps displayed. The setup phase will complete immediately when `Setup.update/2` finds no matching metadata keys (the `setup_keys != []` guard on line 44 returns `false`, so `:processing` is returned — but there will be no metadata keys to check against). **Important**: This changes the flow for no-project sessions. Since `Setup.start/1` will no longer enqueue any workers and `Setup.update/2` will never be called (no workers call `Engine.phase_update`), we need to handle this case.

**Wait — flow analysis for no-project sessions:**

Currently, when `title_generating == true` and `project_id == nil`:
- `Setup.start/1` enqueues title gen worker → worker completes → calls `Engine.phase_update(setup_step_completed)` → `Setup.update/2` checks all setup metadata → all complete → returns `:setup_complete` → `Engine.start_session/1` kicks off phase 1

After our change:
- Title gen is enqueued in `create_workflow_session/1` (fire-and-forget)
- `Setup.start/1` has nothing to enqueue (no project_id)
- No worker calls `Engine.phase_update(setup_step_completed)` → `Engine.start_session/1` is never called
- Session stays stuck in setup forever

**Fix:** When `Setup.start/1` has no workers to enqueue (no project_id), it should return `:setup_complete` instead of `:processing`. The caller (`prepare_workflow_session`) must then call `Engine.start_session/1`.

### Step 3 (revised): Update `Setup.start/1` to handle immediate completion

**File:** `lib/destila/workflows/setup.ex`

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

### Step 2 (revised): Update `prepare_workflow_session` to handle immediate setup completion

**File:** `lib/destila/workflows.ex`

Update `prepare_workflow_session/1` (line 143-145) to handle the `:setup_complete` case:

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

This ensures that sessions with no project (and thus no setup workers) immediately start phase 1.

### Step 5: Update `Setup.update/2` — remove `"title_gen"` from `@setup_keys`

Already covered in Step 3. With `"title_gen"` removed from `@setup_keys`, the `update/2` function will only check `repo_sync` and `worktree` metadata. This is correct — only `PrepareWorkflowSession` writes these entries and calls `Engine.phase_update(setup_step_completed)`.

### Step 6: Update tests

#### Engine tests (`test/destila/executions/engine_test.exs`)

The three tests in `describe "phase_update/3 with setup_step_completed"` (lines 177-218) all set up `title_gen` metadata with `"status" => "completed"`. Remove those `upsert_metadata` calls for `title_gen`. The tests should now only use `repo_sync` and `worktree` metadata.

- **Line 181**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})`
- **Line 196**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})`
- **Line 208**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "completed"})`

#### LiveView tests — brainstorm workflow (`test/destila_web/live/brainstorm_idea_workflow_live_test.exs`)

- **Lines 185-212** ("shows setup progress steps"): This test creates a session with `title_generating: true` and `project_id`, sets `title_gen` metadata, and asserts `html =~ "Generating title..."`. Since we're removing title_gen from setup display, remove the `title_gen` metadata upsert (line 198-200) and the `assert html =~ "Generating title..."` assertion (line 210).
- **Lines 430-445** (setup failure test): Remove `title_gen` metadata upsert (line 438-440).
- **Line 740**: Remove `Workflows.upsert_metadata(ws.id, "creation", "title_gen", %{"status" => "done"})` — this was setting up non-exported metadata for the empty-state test and is now unnecessary.

#### LiveView tests — implement workflow (`test/destila_web/live/implement_general_prompt_workflow_live_test.exs`)

- **Lines 195-210** ("shows title generation for manual prompt"): Remove `title_gen` metadata upsert (lines 204-206) and remove the `assert html =~ "Generating title..."` assertion (line 209). The test can be removed entirely since title generation is no longer displayed in setup, or repurposed to verify title_generating sessions work.

#### Metadata tests (`test/destila/workflows_metadata_test.exs`)

Lines that use `"title_gen"` as a metadata key in tests are just using it as a convenient test key name — they're testing `upsert_metadata` mechanics, not title generation logic. These can be left as-is since they're testing generic metadata CRUD (the key name is arbitrary). However, review each to confirm none depend on `title_gen` being in `@setup_keys`.

### Step 7: Run `mix precommit`

Run `mix precommit` and fix any issues.

## Summary of files changed

| File | Change |
|------|--------|
| `lib/destila/workers/title_generation_worker.ex` | Remove metadata writes and Engine callback |
| `lib/destila/workflows.ex` | Enqueue title gen in `create_workflow_session/1`; update `prepare_workflow_session/1` to handle `:setup_complete` |
| `lib/destila/workflows/setup.ex` | Remove `"title_gen"` from `@setup_keys`; remove title gen enqueue from `start/1`; return `:setup_complete` when no workers needed |
| `lib/destila_web/components/setup_components.ex` | Remove title_gen step from `build_steps/2` |
| `test/destila/executions/engine_test.exs` | Remove `title_gen` metadata from setup tests |
| `test/destila_web/live/brainstorm_idea_workflow_live_test.exs` | Remove `title_gen` metadata and assertions |
| `test/destila_web/live/implement_general_prompt_workflow_live_test.exs` | Remove `title_gen` metadata and assertions |

## Risks and edge cases

1. **No-project sessions**: Without the revised `prepare_workflow_session` handling `:setup_complete`, sessions without a project would get stuck in setup. The plan addresses this by having `Setup.start/1` return `:setup_complete` when there are no workers to enqueue, and `prepare_workflow_session/1` calling `Engine.start_session/1` in that case.

2. **Title gen failure**: If the worker fails after max retries, `title_generating` stays `true` on the session. This is existing behavior — the boolean was already the source of truth. No change needed.

3. **Race condition**: Title gen worker could complete and call `update_workflow_session` while the session is still being set up. This is safe — it only writes `title` and `title_generating: false`, which don't conflict with setup/phase execution logic.
