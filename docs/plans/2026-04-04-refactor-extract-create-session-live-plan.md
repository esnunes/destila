---
title: "refactor: Extract session creation into CreateSessionLive"
type: refactor
date: 2026-04-04
---

# refactor: Extract session creation into CreateSessionLive

## Overview

Extract the entire workflow session creation flow (type selection, wizard form, session creation) into a self-contained `CreateSessionLive` LiveView. This replaces the current split across type selection UI, per-workflow wizard components (`WizardPhase`, `PromptWizardPhase`), and session creation logic in `WorkflowRunnerLive`. Setup (title gen, repo sync, worktree) becomes a session status rendered inside `WorkflowRunnerLive` rather than a numbered phase.

After this change, adding a new workflow type only requires defining a `creation_config/0` callback — no per-workflow wizard component needed.

## Current state

- `WorkflowRunnerLive` has three mount paths: `/workflows` (type selection), `/workflows/:workflow_type` (wizard), `/sessions/:id` (running session).
- Each workflow defines phases 1-2 as wizard + setup. `BrainstormIdeaWorkflow` has 6 phases; `ImplementGeneralPromptWorkflow` has 9.
- `WizardPhase` collects project + idea. `PromptWizardPhase` collects prompt (from source sessions or manual) + project.
- Session creation is triggered by `{:phase_complete, 1, %{action: :session_create, ...}}` → handled in `WorkflowRunnerLive`.
- `SetupPhase` is phase 2 in both workflows, rendering progress for title gen, repo sync, worktree.
- `list_sessions_with_generated_prompts/0` is a hardcoded query looking for metadata key `"prompt_generated"`.

## Solution

### Architecture

1. **New `creation_config/0` callback** on `Destila.Workflow` behaviour — each workflow returns `{source_metadata_key | nil, label, dest_metadata_key}`.
2. **New `CreateSessionLive`** LiveView at `/workflows` and `/workflows/:workflow_type` — owns type selection, adaptive form, and session creation.
3. **Setup becomes a status** — `phase_status: :setup` at phase 1 on newly created sessions. `WorkflowRunnerLive` renders setup UI when status is `:setup`, then switches to phase component when done.
4. **Phase renumbering** — wizard (old phase 1) and setup (old phase 2) removed from `phases/0`. Old phase 3 → new phase 1, etc. `total_phases` shrinks by 2.
5. **Database migration** — existing sessions: decrement `current_phase` by 2 and `total_phases` by 2; reassign wizard/setup metadata `phase_name` to the last phase name.

### Key design decisions

1. **Callback-driven form** — `creation_config/0` returns a simple tuple that the LiveView interprets. No per-workflow branching in `CreateSessionLive`. When `source_metadata_key` is non-nil, the form queries `list_sessions_with_exported_metadata/1` to find source sessions. When nil, the source picker is hidden.

2. **Generic `list_sessions_with_exported_metadata/1`** — replaces `list_sessions_with_generated_prompts/0`. Accepts a metadata key string and returns `{session, text}` tuples from exported metadata with that key. This is the single query backing source session selection for any workflow.

3. **Setup as status, not phase** — the `phase_status` enum already includes `:setup`. After session creation, the session starts at phase 1 with `phase_status: :setup`. `WorkflowRunnerLive.mount_session/2` checks this status: when `:setup`, it renders the setup UI (reusing `SetupPhase` logic or a new function component). When setup completes, `Workflows.Setup.update/2` sets `phase_status` to whatever `phase_start_action` returns, and `WorkflowRunnerLive` switches to the phase component.

4. **Wizard metadata stored under `"creation"` phase_name** — the new `CreateSessionLive` stores the user's input as `upsert_metadata(ws.id, "creation", dest_metadata_key, %{"text" => input})`. The workflows' `phase_start_action` for phase 1 reads from this key. This replaces the current `"wizard"` phase_name with `"creation"`.

5. **Source session pre-fill** — when a source session is selected, its project is pre-filled (existing behavior). The source session's metadata text value pre-fills the text field. The metadata key for lookup comes from `creation_config/0`.

6. **CraftingBoardLive phase_columns** — the `phase_columns/0` function still works because it derives from the updated `phases/0`. The crafting board's column grouping continues to work with the new phase numbers.

## Implementation steps

### Step 1: Add `creation_config/0` callback to `Destila.Workflow`

**File: `lib/destila/workflow.ex`**

Add a new callback:

```elixir
@callback creation_config() ::
            {source_metadata_key :: String.t() | nil, label :: String.t(),
             dest_metadata_key :: String.t()}
```

No default implementation — every workflow must define it.

**File: `lib/destila/workflows/brainstorm_idea_workflow.ex`**

```elixir
def creation_config, do: {nil, "Idea", "idea"}
```

**File: `lib/destila/workflows/implement_general_prompt_workflow.ex`**

```elixir
def creation_config, do: {"prompt_generated", "Prompt", "prompt"}
```

**File: `lib/destila/workflows.ex`**

Add dispatcher:

```elixir
def creation_config(workflow_type), do: workflow_module(workflow_type).creation_config()
```

### Step 2: Add `list_sessions_with_exported_metadata/1` to `Destila.Workflows`

**File: `lib/destila/workflows.ex`**

```elixir
@doc """
Lists completed, non-archived sessions that have an exported metadata entry
with the given key. Returns `{session, text}` tuples, ordered by most recent.
"""
def list_sessions_with_exported_metadata(metadata_key) do
  from(ws in Session,
    join: m in SessionMetadata,
    on: m.workflow_session_id == ws.id and m.key == ^metadata_key and m.exported == true,
    where: not is_nil(ws.done_at) and is_nil(ws.archived_at),
    preload: [:project],
    order_by: [desc: ws.done_at],
    select: {ws, m.value}
  )
  |> Repo.all()
  |> Enum.map(fn {ws, value} -> {ws, value["text"]} end)
  |> Enum.reject(fn {_ws, text} -> is_nil(text) || text == "" end)
end
```

Keep `list_sessions_with_generated_prompts/0` as a deprecated alias during migration, or replace its single caller in `PromptWizardPhase` (which will be deleted).

### Step 3: Create `CreateSessionLive`

**File: `lib/destila_web/live/create_session_live.ex`**

New LiveView module that handles:

**Mount:**
- `/workflows` (no params) → assigns `view: :selecting_type`, loads `workflow_type_metadata()`
- `/workflows/:workflow_type` → assigns `view: :form`, calls `creation_config(workflow_type)` to get `{source_key, label, dest_key}`. If `source_key` is non-nil, queries `list_sessions_with_exported_metadata(source_key)`.

**Assigns (form view):**
- `workflow_type`, `source_metadata_key`, `input_label`, `dest_metadata_key`
- `source_sessions` — list of `{session, text}` (empty when source_key is nil)
- `selected_session_id`, `selected_text` — for source selection
- `input_text` — the user's text input (pre-filled from source or manual)
- `input_mode` — `:select` or `:manual` (only relevant when source sessions exist)
- `projects`, `project_id`, `project_step`, `project_form`, `errors` — same as current wizard phases

**Events:**
- `select_session` — selects a source session, pre-fills text and project
- `switch_to_manual` / `switch_to_select` — toggle input mode
- `update_text` — phx-change on text input
- `select_project`, `show_create_project`, `back_to_select`, `create_and_select_project` — project picker (same as today, targeting `self()` not `@myself`)
- `start_workflow` — validates, creates session, stores metadata, starts engine, navigates to `/sessions/:id`

**Session creation on submit (in `start_workflow`):**

```elixir
# Determine title
title =
  if selected_session_id do
    source = Workflows.get_workflow_session(selected_session_id)
    if source, do: source.title, else: Workflows.default_title(workflow_type)
  else
    Workflows.default_title(workflow_type)
  end

title_generating = is_nil(selected_session_id)

session_attrs = %{
  title: title,
  workflow_type: workflow_type,
  current_phase: 1,
  total_phases: Workflows.total_phases(workflow_type),
  phase_status: :setup,
  title_generating: title_generating
}
|> maybe_put(:project_id, project_id)

{:ok, ws} = Workflows.create_workflow_session(session_attrs)

# Store creation metadata
Workflows.upsert_metadata(ws.id, "creation", dest_key, %{"text" => input_text})

if selected_session_id do
  Workflows.upsert_metadata(ws.id, "creation", "source_session", %{
    "id" => selected_session_id
  })
end

# Start setup (title gen, repo sync, worktree)
Workflows.Setup.start(ws)

push_navigate(socket, to: ~p"/sessions/#{ws.id}")
```

**Render (`:selecting_type`):**
Move the existing type selection template from `WorkflowRunnerLive.render(%{view: :selecting_type})` here verbatim.

**Render (`:form`):**
Adaptive form that:
- Shows source session picker when `source_sessions != []`, with tabs "Select existing" / "Write manually"
- Shows only a textarea when no source sessions
- Uses the `input_label` from `creation_config` as the section heading
- Uses `<.project_selector>` from `ProjectComponents`
- Shows a "Start" button

### Step 4: Update router

**File: `lib/destila_web/router.ex`**

Change:
```elixir
live "/workflows", WorkflowRunnerLive
live "/workflows/:workflow_type", WorkflowRunnerLive
```
To:
```elixir
live "/workflows", CreateSessionLive
live "/workflows/:workflow_type", CreateSessionLive
```

### Step 5: Remove wizard and setup from `phases/0`

**File: `lib/destila/workflows/brainstorm_idea_workflow.ex`**

Remove the first two entries from `phases/0`:

```elixir
def phases do
  [
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Task Description", system_prompt: &task_description_prompt/1},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Gherkin Review", system_prompt: &gherkin_review_prompt/1, skippable: true},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Technical Concerns", system_prompt: &technical_concerns_prompt/1},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Prompt Generation",
     system_prompt: &prompt_generation_prompt/1,
     final: true,
     message_type: :generated_prompt}
  ]
end
```

Total phases: 6 → 4.

Update `phase_start_action`:
- Remove the `SetupPhase` match clause.
- Remove the `WizardPhase` match clause (it was never reached post-session anyway).
- Phase numbers now start at 1 = Task Description.

Update `phase_update_action`:
- Remove the `setup_step_completed` clause — setup is no longer a phase.
- Phase number references are already relative via `Enum.at(phases(), phase_number - 1)`.

Update `save_phase_metadata` — no change needed, it already uses `Enum.at(phases(), ...)`.

Update system prompts that reference metadata keys:
- `task_description_prompt/1` reads `get_in(metadata, ["idea", "text"])`. Change to `get_in(metadata, ["idea", "text"])` — the key is the same, but the phase_name is now `"creation"` instead of `"wizard"`. Since `get_metadata/1` flattens to key→value, this still works.

**File: `lib/destila/workflows/implement_general_prompt_workflow.ex`**

Remove the first two entries from `phases/0`:

```elixir
def phases do
  [
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Generate Plan",
     system_prompt: &plan_prompt/1,
     non_interactive: true,
     allowed_tools: @implementation_tools},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Deepen Plan",
     system_prompt: &deepen_plan_prompt/1,
     non_interactive: true,
     skippable: true,
     allowed_tools: @implementation_tools},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Work",
     system_prompt: &work_prompt/1,
     non_interactive: true,
     allowed_tools: @implementation_tools},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Review",
     system_prompt: &review_prompt/1,
     non_interactive: true,
     allowed_tools: @implementation_tools},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Browser Tests",
     system_prompt: &browser_tests_prompt/1,
     non_interactive: true,
     skippable: true,
     allowed_tools: @implementation_tools},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Feature Video",
     system_prompt: &feature_video_prompt/1,
     non_interactive: true,
     skippable: true,
     allowed_tools: @implementation_tools},
    {DestilaWeb.Phases.AiConversationPhase,
     name: "Adjustments",
     system_prompt: &adjustments_prompt/1,
     allowed_tools: @implementation_tools,
     final: true}
  ]
end
```

Total phases: 9 → 7.

Update `session_strategy/1`:
- Old phase 5 (Work) = new phase 3. So `def session_strategy(3), do: :new`.

Update `phase_start_action`:
- Remove the `SetupPhase` match clause.
- Remove the `PromptWizardPhase` match clause.
- The remaining logic is the same (system_prompt dispatch).

Update `phase_update_action`:
- Remove the `setup_step_completed` clause.

System prompts: `plan_prompt/1` reads `get_in(metadata, ["prompt", "text"])`. This still works because `get_metadata/1` flattens by key.

### Step 6: Setup as a session status in `WorkflowRunnerLive`

**File: `lib/destila_web/live/workflow_runner_live.ex`**

**Remove:**
- `mount_type_selection/1` function
- `mount_workflow/1` function
- The `cond` branches for these in `mount/3` — only `mount_session/2` remains
- The `render(%{view: :selecting_type})` clause
- The `handle_info({:phase_complete, _, %{action: :session_create}}, _)` handler

**Modify `mount/3`:**
```elixir
def mount(%{"id" => id}, session, socket) do
  socket = assign(socket, :current_user, session["current_user"])
  mount_session(id, socket)
end
```

**Add setup-aware rendering in `render_phase/1`:**

```elixir
defp render_phase(%{workflow_session: %{phase_status: :setup}} = assigns) do
  ~H"""
  <.live_component
    module={DestilaWeb.Phases.SetupPhase}
    id="setup"
    workflow_session={@workflow_session}
    metadata={@metadata}
    phase_number={0}
    opts={[]}
  />
  """
end

defp render_phase(%{phases: phases, current_phase: current_phase} = assigns) do
  # existing logic
end
```

This reuses `SetupPhase` as a component, but it's no longer a numbered phase. The `phase_number: 0` is just a placeholder since setup doesn't need it for anything.

**Modify `handle_info({:workflow_session_updated, ...})` and `handle_info({:metadata_updated, ...})`:**
These already re-fetch and reassign `workflow_session` and `metadata`, so setup completion will naturally cause a re-render when `phase_status` changes from `:setup` to `:processing` or `:awaiting_input`.

### Step 7: Update `Workflows.Setup` to transition out of setup status

**File: `lib/destila/workflows/setup.ex`**

Currently, `Setup.update/2` returns `:phase_complete` when all steps are done, which triggers `Engine.phase_update` → `advance_to_next`. Now setup is not a phase, so completion should return `:setup_complete` — a new status the Engine will handle.

Modify `update/2`:

```elixir
def update(workflow_session, _params) do
  metadata = Destila.Workflows.get_metadata(workflow_session.id)

  setup_keys =
    metadata
    |> Map.keys()
    |> Enum.filter(&(&1 in @setup_keys))

  if setup_keys != [] &&
       Enum.all?(setup_keys, &(get_in(metadata, [&1, "status"]) == "completed")) do
    :setup_complete
  else
    :processing
  end
end
```

**File: `lib/destila/executions/engine.ex`**

In `phase_update/3`, add a new clause to handle `:setup_complete`:

```elixir
:setup_complete ->
  # Setup is done — clear setup status and start the actual phase 1
  {:ok, ws} = Workflows.update_workflow_session(ws, %{phase_status: nil})
  start_session(ws)
```

This calls `start_session/1` which creates the phase execution record and calls `phase_start_action` on the workflow.

**Setup workers already use `ws.current_phase`** — both `SetupWorker` and `TitleGenerationWorker` already call `Engine.phase_update(workflow_session_id, workflow_session.current_phase, ...)` (not a hardcoded phase number). After this change the session's `current_phase` is 1 at setup time, and the workflow's `phase_update_action` at phase 1 matches `%{setup_step_completed: _}` first (before any AI-related clauses):

```elixir
def phase_update_action(ws, _phase_number, %{setup_step_completed: _} = params) do
  Destila.Workflows.Setup.update(ws, params)
end
```

The `_phase_number` is ignored, so this works regardless of which phase number the worker passes. **No changes needed to setup workers.**

### Step 8: Database migration

**File: `priv/repo/migrations/<timestamp>_extract_create_session_live.exs`**

The migration must update **four tables** that store phase numbers:

1. `workflow_sessions` — `current_phase` and `total_phases`
2. `workflow_session_metadata` — `phase_name` (rename `"wizard"` and `"Setup"` to `"creation"`)
3. `messages` — `phase` column (integer, stores the phase number when message was created)
4. `phase_executions` — `phase_number` and `phase_name`

**Why messages and phase_executions matter:**

- **`messages.phase`**: Used by `AiConversationPhase` to group messages into phase sections with dividers (line 215 of `ai_conversation_phase.ex`: `for {phase, group} <- @phase_groups`). Each divider displays `Workflows.phase_name(workflow_type, phase)` which does `Enum.at(phases(), phase - 1)`. If messages have old phase 3 but `phases/0` now has 4 entries (not 6), phase 3 would resolve to "Technical Concerns" instead of the correct "Task Description".

- **`messages.phase`**: Used by `derive_message_type/3` in `lib/destila/ai.ex` (line 254) via `get_phase_opts/2` (line 278) which does `Enum.at(phases(), phase - 1)`. Old phase 6 messages would try to access index 5 in a 4-element list and get `nil`, breaking message type detection.

- **`phase_executions.phase_number`**: Used by `get_current_phase_execution/1` which orders by `phase_number DESC`. Used by `get_phase_execution_by_number/2` for exact lookups. Used by `ensure_phase_execution/2` which has a unique constraint on `(workflow_session_id, phase_number)`.

- **`build_conversation_context/1`** in `BrainstormIdeaWorkflow` (line 345) groups messages by `&1.phase` and calls `phase_name(phase)` — same lookup issue.

```elixir
defmodule Destila.Repo.Migrations.ExtractCreateSessionLive do
  use Ecto.Migration

  def up do
    # 1. Decrement current_phase and total_phases by 2 for all sessions
    execute """
    UPDATE workflow_sessions
    SET current_phase = MAX(current_phase - 2, 1),
        total_phases = total_phases - 2
    """

    # 2. Sessions that were on old phase 1 (wizard) or old phase 2 (setup)
    #    are now at phase 1 with setup status
    execute """
    UPDATE workflow_sessions
    SET phase_status = 'setup'
    WHERE current_phase = 1 AND phase_status IN ('processing', 'awaiting_input')
    AND id IN (
      SELECT DISTINCT workflow_session_id FROM workflow_session_metadata
      WHERE phase_name IN ('wizard', 'Setup') AND key IN ('title_gen', 'repo_sync', 'worktree')
      AND json_extract(value, '$.status') != 'completed'
    )
    """

    # 3. Reassign wizard/setup metadata phase_name to "creation"
    execute """
    UPDATE workflow_session_metadata
    SET phase_name = 'creation'
    WHERE phase_name IN ('wizard', 'Setup')
    """

    # 4. Decrement phase numbers on all messages by 2 (min 1)
    #    Messages at old phases 1-2 (wizard/setup) didn't exist in practice
    #    (wizards don't create AI messages), but guard with MAX just in case
    execute """
    UPDATE messages
    SET phase = MAX(phase - 2, 1)
    WHERE ai_session_id IN (
      SELECT id FROM ai_sessions
    )
    """

    # 5. Update phase_executions: decrement phase_number by 2
    #    and update phase_name to match new phase definitions.
    #    Delete wizard/setup phase executions (old phases 1-2).
    execute """
    DELETE FROM phase_executions
    WHERE phase_number <= 2
    """

    execute """
    UPDATE phase_executions
    SET phase_number = phase_number - 2
    """

    # 6. Update phase_name on remaining phase_executions.
    #    We update per-workflow-type since phase names differ.
    #    BrainstormIdea: old 3→1 "Task Description", 4→2 "Gherkin Review",
    #                    5→3 "Technical Concerns", 6→4 "Prompt Generation"
    #    ImplementGeneralPrompt: old 3→1 "Generate Plan", 4→2 "Deepen Plan",
    #                            5→3 "Work", 6→4 "Review", 7→5 "Browser Tests",
    #                            8→6 "Feature Video", 9→7 "Adjustments"
    #    Phase names are already correct because they were set from the workflow's
    #    phase_name() at creation time, and we've only shifted the numbers.
    #    The names stay the same — only phase_number changed.
    #    No phase_name update needed.
  end

  def down do
    # Reverse: increment phases back by 2
    execute """
    UPDATE workflow_sessions
    SET current_phase = current_phase + 2,
        total_phases = total_phases + 2
    """

    execute """
    UPDATE workflow_session_metadata
    SET phase_name = 'wizard'
    WHERE phase_name = 'creation'
    AND key IN ('idea', 'prompt', 'source_session')
    """

    execute """
    UPDATE workflow_session_metadata
    SET phase_name = 'Setup'
    WHERE phase_name = 'creation'
    AND key IN ('title_gen', 'repo_sync', 'worktree')
    """

    execute """
    UPDATE messages
    SET phase = phase + 2
    WHERE ai_session_id IN (
      SELECT id FROM ai_sessions
    )
    """

    execute """
    UPDATE phase_executions
    SET phase_number = phase_number + 2
    """
  end
end
```

**Note on `MAX(current_phase - 2, 1)`**: Sessions on old phase 1 (wizard) or 2 (setup) go to 1. Sessions on old phase 3+ get correctly decremented.

**Note on phase_executions deletion**: Wizard and setup phase_executions (old phases 1-2) are deleted since these phases no longer exist. Their status data is not needed — the creation flow and setup status are handled differently now.

**Note on in-flight Oban jobs**: `AiQueryWorker` jobs carry a `"phase"` arg set at enqueue time. If a job was enqueued for old phase 3 and runs after migration, it will pass `phase=3` to `Engine.phase_update`. However, `Engine.phase_update` does `%{ws | current_phase: phase}` — the ws was already migrated to `current_phase=1`, but the phase override from the job args would make it 3, which won't match the workflow's `phases/0` (now only 4 entries for brainstorm). **Mitigation**: Cancel all pending Oban jobs before running the migration: `Oban.cancel_all_jobs(Destila.Workers.AiQueryWorker)`. Active sessions will need to be retried after deployment.

### Step 9: Delete old wizard phase files

Delete:
- `lib/destila_web/live/phases/wizard_phase.ex`
- `lib/destila_web/live/phases/prompt_wizard_phase.ex`

`SetupPhase` is kept — it's reused by `WorkflowRunnerLive` for the setup status rendering.

Remove `list_sessions_with_generated_prompts/0` from `lib/destila/workflows.ex` (no callers remain after `PromptWizardPhase` is deleted).

### Step 10: Update feature files

**File: `features/workflow_type_selection.feature`**

Update scenario "Select a workflow type to start" — navigating to a type now goes to the creation form in `CreateSessionLive`, not a wizard phase.

**File: `features/brainstorm_idea_workflow.feature`**

- Update phase numbers: Phase 2 → Setup status (not a numbered phase), Phase 3 → Phase 1, etc.
- Update "Phase 1 - Wizard collects project and idea" → now happens in `CreateSessionLive` at `/workflows/brainstorm_idea`
- Update "Phase 2 - Setup displays progress" → now shows as setup status within `/sessions/:id`, progress bar shows "Phase 1/4 — Task Description" with a setup overlay
- Phase references shift: old "Phase 3/6" → "Phase 1/4", old "Phase 6/6" → "Phase 4/4"

**File: `features/implement_general_prompt_workflow.feature`**

- Same phase renumbering: old 9 phases → 7 phases
- Phase 1 wizard scenarios move to `CreateSessionLive`
- Phase 2 setup scenarios become setup status scenarios
- Phase references shift: old "Phase 3" → "Phase 1", old "Phase 9" → "Phase 7"

### Step 11: Update tests

Update existing tests that reference:
- Phase numbers (decrement by 2)
- `WizardPhase` or `PromptWizardPhase` modules
- Routes `/workflows` and `/workflows/:workflow_type` (now point to `CreateSessionLive`)
- `list_sessions_with_generated_prompts/0` (replace with `list_sessions_with_exported_metadata/1`)
- `mount_type_selection` or `mount_workflow` (removed from `WorkflowRunnerLive`)

Add new tests for:
- `CreateSessionLive` — type selection, form rendering, source session selection, session creation, navigation
- `creation_config/0` callback on each workflow
- `list_sessions_with_exported_metadata/1` with various metadata keys
- Setup status rendering in `WorkflowRunnerLive`

## Files to modify

1. **`lib/destila/workflow.ex`** — Add `creation_config/0` callback
2. **`lib/destila/workflows.ex`** — Add `creation_config/1` dispatcher, `list_sessions_with_exported_metadata/1`, remove `list_sessions_with_generated_prompts/0`
3. **`lib/destila/workflows/brainstorm_idea_workflow.ex`** — Add `creation_config/0`, remove wizard/setup from `phases/0`, remove setup handler from `phase_update_action`
4. **`lib/destila/workflows/implement_general_prompt_workflow.ex`** — Same as above, plus update `session_strategy/1` (old 5 -> new 3)
5. **`lib/destila/workflows/setup.ex`** — Return `:setup_complete` instead of `:phase_complete`
6. **`lib/destila/executions/engine.ex`** — Handle `:setup_complete` in `phase_update/3`
7. **`lib/destila_web/live/create_session_live.ex`** — New file
8. **`lib/destila_web/live/workflow_runner_live.ex`** — Remove type selection/wizard mount paths, add setup status rendering
9. **`lib/destila_web/router.ex`** — Point `/workflows` routes to `CreateSessionLive`
10. **`priv/repo/migrations/<timestamp>_extract_create_session_live.exs`** — New migration (sessions, metadata, messages, phase_executions)
11. **`features/workflow_type_selection.feature`** — Update scenarios
12. **`features/brainstorm_idea_workflow.feature`** — Update phase numbers and descriptions
13. **`features/implement_general_prompt_workflow.feature`** — Update phase numbers and descriptions

## Files to delete

1. **`lib/destila_web/live/phases/wizard_phase.ex`**
2. **`lib/destila_web/live/phases/prompt_wizard_phase.ex`**

## Files confirmed unchanged

1. **`lib/destila/workers/setup_worker.ex`** — Already uses `ws.current_phase`, no changes needed
2. **`lib/destila/workers/title_generation_worker.ex`** — Already uses `ws.current_phase`, no changes needed
3. **`lib/destila/ai.ex`** — `get_phase_opts/2` (line 278) uses `Enum.at(phases(), phase - 1)` which works correctly after message phase numbers are migrated
4. **`lib/destila_web/live/phases/ai_conversation_phase.ex`** — Phase dividers (line 225) use `Workflows.phase_name(workflow_type, phase)` which resolves correctly after message phase migration

## Risks and mitigations

1. **In-flight Oban jobs with old phase numbers** — `AiQueryWorker` jobs carry a `"phase"` arg set at enqueue time. If a job was enqueued before migration with old phase 3 and executes after, `Engine.phase_update` does `%{ws | current_phase: phase}` (line 107 of `engine.ex`) with the stale number, causing `phase_update_action` to look up the wrong phase definition via `Enum.at(phases(), phase - 1)`. **Mitigation**: Cancel all pending `AiQueryWorker` jobs before running the migration. Active sessions will need retry after deployment.

2. **`build_conversation_context/1` on pre-migration messages** — This function in `BrainstormIdeaWorkflow` (line 345) groups messages by `&1.phase` and calls `phase_name(phase)`. After migration, stored message phase numbers are decremented, so `phase_name(1)` correctly resolves to "Task Description" from the new `phases/0`. **No issue if migration runs correctly.**

3. **`derive_message_type/3` in `ai.ex`** — Uses `get_phase_opts(workflow_type, phase)` (line 254) which does `Enum.at(phases(), phase - 1)` (line 279). After migration, message phase numbers are decremented, so lookups resolve correctly. E.g., old phase 6 messages (Prompt Generation) become phase 4, and `Enum.at(phases(), 3)` correctly returns the Prompt Generation opts with `message_type: :generated_prompt`. **No issue if migration runs correctly.**

4. **Phase execution unique constraint** — `phase_executions` has a unique constraint on `(workflow_session_id, phase_number)`. The migration deletes old phases 1-2 first, then decrements remaining numbers. If old phase 3 becomes 1, this is safe because old phase 1 was already deleted. **Order matters: delete first, then decrement.**

5. **CraftingBoardLive column grouping** — `phase_columns/0` derives from the updated `phases/0`, so it automatically adjusts. Sessions in the DB with updated `current_phase` values map correctly to the new columns.

6. **Setup workers during deployment** — If a setup worker fires after the code update but before migration, `ws.current_phase` is still old phase 2 (pre-migration). The `%{setup_step_completed: _}` clause matches regardless of phase number, so `Setup.update/2` runs correctly. The returned `:setup_complete` won't be handled by the old Engine code (which only knows `:phase_complete`), but this is a brief window. **Mitigation**: Run migration immediately after deploying code.
